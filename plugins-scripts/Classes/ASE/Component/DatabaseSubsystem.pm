package Classes::ASE::Component::DatabaseSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub filter_all {
  my $self = shift;
}

sub init {
  my $self = shift;
  my $sql = undef;
  my $allfilter = sub {
    my $o = shift;
    $self->filter_name($o->{name}) && 
        ! (($self->opts->notemp && $o->is_temp) || ($self->opts->nooffline && ! $o->is_online));
  };
  if ($self->mode =~ /server::database::(createuser|listdatabases|databasefree)$/) {
    my $columns = ['name', 'state', 'rows_max_size', 'rows_used_size', 'log_max_size', 'log_used_size'];
    my $sql = q{
      SELECT
          db_name(d.dbid) AS name,
          d.status2 AS state,
          SUM(
              CASE WHEN u.segmap != 4
              THEN u.size/1048576.*@@maxpagesize
              END
          ) AS data_size,
          SUM(
              CASE WHEN u.segmap != 4
              THEN size - curunreservedpgs(u.dbid, u.lstart, u.unreservedpgs)
              END
          ) / 1048576. * @@maxpagesize AS data_used,
          SUM(
              CASE WHEN u.segmap = 4
              THEN u.size/1048576.*@@maxpagesize
              END
          ) AS log_size,
          SUM(
              CASE WHEN u.segmap = 4
              THEN u.size/1048576.*@@maxpagesize
              END
          ) - 
          lct_admin("logsegment_freepages", d.dbid) / 1048576. * @@maxpagesize AS log_used
      FROM
          master..sysdatabases d, master..sysusages u
      WHERE
          u.dbid = d.dbid AND d.status != 256
      GROUP BY
          d.dbid
      ORDER BY
          db_name(d.dbid)
    };
    $self->get_db_tables([
        ['databases', $sql, 'Classes::ASE::Component::DatabaseSubsystem::Database', $allfilter, $columns],
    ]);
    @{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
  } elsif ($self->mode =~ /server::database::online/) {
    my $columns = ['name', 'state', 'state_desc', 'collation_name'];
    $sql = q{
      SELECT name, state, state_desc, collation_name FROM master.sys.databases
    };
    $self->get_db_tables([
        ['databases', $sql, 'Classes::ASE::Component::DatabaseSubsystem::Database', $allfilter, $columns],
    ]);
    @{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
  } elsif ($self->mode =~ /server::database::.*backupage/) {
    my $columns = ['name', 'id'];
    $sql = q{
      SELECT name, dbid FROM master..sysdatabases
    };
    $self->get_db_tables([
        ['databases', $sql, 'Classes::ASE::Component::DatabaseSubsystem::DatabaseStub', $allfilter, $columns],
    ]);
    foreach (@{$self->{databases}}) {
      bless $_, 'Classes::ASE::Component::DatabaseSubsystem::Database';
      $_->finish();
    }
  } else {
    $self->no_such_mode();
  }
}


package Classes::ASE::Component::DatabaseSubsystem::DatabaseStub;
our @ISA = qw(Classes::ASE::Component::DatabaseSubsystem::Database);
use strict;

sub finish {
  my $self = shift;
  my $sql = sprintf q{
      DBCC TRACEON(3604)
      DBCC DBTABLE("%s")
  }, $self->{name};
  my @dbccresult = $self->fetchall_array($sql);
  foreach (@dbccresult) {
    #dbt_backup_start: 0x1686303d8 (dtdays=40599, dttime=7316475)    Feb 27 2011  6:46:28:250AM
    if (/dbt_backup_start: \w+\s+\(dtdays=0, dttime=0\) \(uninitialized\)/) {
      # never backed up
      last;
    } elsif (/dbt_backup_start: \w+\s+\(dtdays=\d+, dttime=\d+\)\s+(\w+)\s+(\d+)\s+(\d+)\s+(\d+):(\d+):(\d+):\d+([AP])/) {
      require Time::Local;
      my %months = ("Jan" => 0, "Feb" => 1, "Mar" => 2, "Apr" => 3, "May" => 4, "Jun" => 5, "Jul" => 6, "Aug" => 7, "Sep" => 8, "Oct" => 9, "Nov" => 10, "Dec" => 11);
      $self->{backup_age} = (time - Time::Local::timelocal($6, $5, $4 + ($7 eq "A" ? 0 : 12), $2, $months{$1}, $3 - 1900)) / 3600;
      $self->{backup_duration} = 0;
      last;
    }
  }
  # to keep compatibility with mssql. recovery_model=3=simple will be skipped later
  $self->{recovery_model} = 0;
}

package Classes::ASE::Component::DatabaseSubsystem::Database;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub finish {
  my $self = shift;
return;
  if ($self->mode =~ /server::database::databasefree$/) {
    $self->{log_size} = 0 if ! defined $self->{log_size};
    $self->{log_used} = 0 if ! defined $self->{log_used};
    $self->{data_used_pct} = 100 * $self->{data_used} / $self->{data_size};
    $self->{log_used_pct} = $self->{log_size} ? 100 * $self->{log_used} / $self->{log_size} : 0;
    $self->{data_free} = $self->{data_size} - $self->{data_used};
    $self->{log_free} = $self->{log_size} - $self->{log_used};
  }
}

sub is_backup_node {
  my $self = shift;
  # to be done
  return 0;
}

sub is_online {
  my $self = shift;
  return 0 if $self->{messages}->{critical} && grep /is offline/, @{$self->{messages}->{critical}};
  # 0x0010 offline
  # 0x0020 offline until recovery completes
  return $self->{state} & 0x0030 ? 0 : 1;
}

sub is_problematic {
  my $self = shift;
  if ($self->{messages}->{critical}) {
    my $error = join(", ", @{$self->{messages}->{critical}});
    if ($error =~ /Message String: ([\w ]+)/) {
      return $1;
    } else {
      return $error;
    }
  } else {
    return 0;
  }
}

sub is_readable {
  my $self = shift;
  return ($self->{messages}->{critical} && grep /is not able to access the database/i, @{$self->{messages}->{critical}}) ? 0 : 1;
}

sub is_temp {
  my $self = shift;
  return $self->{name} eq "tempdb" ? 1 : 0;
}


sub check {
  my $self = shift;
  if ($self->mode =~ /server::database::(listdatabases)$/) {
    printf "%s\n", $self->{name};
  } elsif ($self->mode =~ /server::database::(databasefree)$/) {
    $self->override_opt("units", "%") if ! $self->opts->units;
    if (! $self->is_online) {
      # offlineok hat vorrang
      $self->override_opt("mitigation", $self->opts->offlineok ? 0 : $self->opts->mitigation ? $self->opts->mitigation : 1);
      $self->add_message($self->opts->mitigation,
          sprintf("database %s is not online", $self->{name})
      );
    } elsif (! $self->is_readable) {
      $self->add_message($self->opts->mitigation ? $self->opts->mitigation : 1,
          sprintf("insufficient privileges to access %s", $self->{name})
      );
    } elsif ($self->is_problematic) {
      $self->add_message($self->opts->mitigation ? $self->opts->mitigation : 1,
          sprintf("error accessing %s: %s", $self->{name}, $self->is_problematic)
      );
    } else {
      foreach my $type (qw(rows log)) {
        next if ! defined $self->{$type."_max_size"}; # not every db has a separate log
        my $metric_pct = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_free_pct' : 'db_'.lc $self->{name}.'_log_free_pct';
        my $metric_units = ($type eq "rows") ? 
            'db_'.lc $self->{name}.'_free' : 'db_'.lc $self->{name}.'_log_free';
        my $factor = 1048576; # MB
        my $warning_units;
        my $critical_units;
        my $warning_pct;
        my $critical_pct;
        if ($self->opts->units ne "%") {
          if (uc $self->opts->units eq "GB") {
            $factor = 1024 * 1024 * 1024;
          } elsif (uc $self->opts->units eq "MB") {
            $factor = 1024 * 1024;
          } elsif (uc $self->opts->units eq "KB") {
            $factor = 1024;
          }
        }
        my $free_percent = 100 - 100 * $self->{$type."_used_size"} / $self->{$type."_max_size"};
        my $free_size = $self->{$type."_max_size"} - $self->{$type."_used_size"};
        my $free_units = $free_size / $factor;
        if ($self->opts->units eq "%") {
          $self->set_thresholds(metric => $metric_pct, warning => "10:", critical => "5:");
          ($warning_pct, $critical_pct) = ($self->get_thresholds(metric => $metric_pct));
          ($warning_units, $critical_units) = map { 
              $_ =~ s/://g; (($_ * $self->{$type."_max_size"} / 100) / $factor).":";
          } map { my $tmp = $_; $tmp; } ($warning_pct, $critical_pct); # sonst schnippelt der von den originalen den : weg
          $self->set_thresholds(metric => $metric_units, warning => $warning_units, critical => $critical_units);
          $self->add_message($self->check_thresholds(metric => $metric_pct, value => $free_percent),
              sprintf("database %s has %.2f%s free %sspace left", $self->{name}, $free_percent, $self->opts->units, ($type eq "log" ? "log " : "")));
        } else {
          $self->set_thresholds(metric => $metric_units, warning => "5:", critical => "10:");
          ($warning_units, $critical_units) = ($self->get_thresholds(metric => $metric_units));
          ($warning_pct, $critical_pct) = map { 
              $_ =~ s/://g; (100 * ($_ * $factor) / $self->{$type."_max_size"}).":";
          } map { my $tmp = $_; $tmp; } ($warning_units, $critical_units);
          $self->set_thresholds(metric => $metric_pct, warning => $warning_pct, critical => $critical_pct);
          $self->add_message($self->check_thresholds(metric => $metric_units, value => $free_units),
              sprintf("database %s has %.2f%s free %sspace left", $self->{name}, $free_units, $self->opts->units, ($type eq "log" ? "log " : "")));
        }
        $self->add_perfdata(
            label => $metric_pct,
            value => $free_percent,
            places => 2,
            uom => '%',
            warning => $warning_pct,
            critical => $critical_pct,
        );
        $self->add_perfdata(
            label => $metric_units,
            value => $free_size / $factor,
            uom => $self->opts->units eq "%" ? "MB" : $self->opts->units,
            places => 2,
            warning => $warning_units,
            critical => $critical_units,
            min => 0,
            max => $self->{$type."_max_size"} / $factor,
        );
      }
    }
  } elsif ($self->mode =~ /server::database::online/) {
    if ($self->is_online) {
      if ($self->{collation_name}) {
        $self->add_ok(
          sprintf "%s is %s and accepting connections", $self->{name}, $self->{state_desc});
      } else {
        $self->add_warning(sprintf "%s is %s but not accepting connections",
            $self->{name}, $self->{state_desc});
      }
    } elsif ($self->{state_desc} =~ /^recover/i) {
      $self->add_warning(sprintf "%s is %s", $self->{name}, $self->{state_desc});
    } else {
      $self->add_critical(sprintf "%s is %s", $self->{name}, $self->{state_desc});
    }
  } elsif ($self->mode =~ /server::database::.*backupage/) {
    if (! $self->is_backup_node) {
      $self->add_ok(sprintf "this is not the preferred replica for backups of %s", $self->{name});
      return;
    }
    my $log = "";
    if ($self->mode =~ /server::database::logbackupage/) {
      $log = "log of ";
    }
    if ($self->mode =~ /server::database::logbackupage/ && $self->{recovery_model} == 3) {
      $self->add_ok(sprintf "%s has no logs", $self->{name});
    } else {
      $self->set_thresholds(metric => $self->{name}.'_bck_age', warning => 48, critical => 72);
      if (! defined $self->{backup_age}) {
        $self->add_message(defined $self->opts->mitigation() ? $self->opts->mitigation() : 2,
            sprintf "%s%s was never backed up", $log, $self->{name});
        $self->{backup_age} = 0;
        $self->{backup_duration} = 0;
      } else {
        $self->add_message(
            $self->check_thresholds(metric => $self->{name}.'_bck_age', value => $self->{backup_age}),
            sprintf "%s%s was backed up %dh ago", $log, $self->{name}, $self->{backup_age});
      }
      $self->add_perfdata(
          label => $self->{name}.'_bck_age',
          value => $self->{backup_age},
      );
      $self->add_perfdata(
          label => $self->{name}.'_bck_time',
          value => $self->{backup_duration},
      );
    }
  }
}


