package Classes::MSSQL::Component::DatabaseSubsystem;
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
  if ($self->mode =~ /server::database::(createuser|listdatabases|database.*free|transactions|datafile|size)$/) {
    my $columns = ['name', 'id', 'state', 'state_desc'];
    if ($self->version_is_minimum("9.x")) {
      $sql = q{
        SELECT
            name, database_id AS id, state, state_desc
        FROM
            master.sys.databases
        ORDER BY
            name
      };
    } else {
      $sql = q{
        SELECT
            name, dbid AS id, status, NULL
        FROM
            master.dbo.sysdatabases
        ORDER BY
            name
      };
    }
    if ($self->mode =~ /server::database::(databasefree|size)$/) {
      $self->filesystems();
    }
    $self->get_db_tables([
        ['databases', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub', $allfilter, $columns],
    ]);
@{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
    foreach (@{$self->{databases}}) {
      # extra Schritt, weil finish() aufwendig ist und bei --name sparsamer aufgerufen wird
      bless $_, 'Classes::MSSQL::Component::DatabaseSubsystem::Database';
      $_->finish();
    }   
  } elsif ($self->mode =~ /server::database::online/) {
    my $columns = ['name', 'state', 'state_desc', 'collation_name'];
    if ($self->version_is_minimum("9.x")) {
      $sql = q{
        SELECT name, state, state_desc, collation_name FROM master.sys.databases
      };
    }
    $self->get_db_tables([
        ['databases', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $columns],
    ]);
@{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
  } elsif ($self->mode =~ /server::database::(.*backupage)/) {
    my $columns = ['name', 'recovery_model', 'backup_age', 'backup_duration'];
    if ($self->mode =~ /server::database::backupage/) {
      if ($self->version_is_minimum("9.x")) {
        $sql = q{
          SELECT D.name AS [database_name], D.recovery_model, BS1.last_backup, BS1.last_duration
          FROM sys.databases D
          LEFT JOIN (
            SELECT BS.[database_name],
            DATEDIFF(HH,MAX(BS.[backup_finish_date]),GETDATE()) AS last_backup,
            DATEDIFF(MI,MAX(BS.[backup_start_date]),MAX(BS.[backup_finish_date])) AS last_duration
            FROM msdb.dbo.backupset BS
            WHERE BS.type IN ('D', 'I')
            GROUP BY BS.[database_name]
          ) BS1 ON D.name = BS1.[database_name] WHERE D.source_database_id IS NULL
          ORDER BY D.[name];
        };
      } else {
        $sql = q{
          SELECT
            a.name,
            CASE databasepropertyex(a.name, 'Recovery')
              WHEN 'FULL' THEN 1
              WHEN 'BULK_LOGGED' THEN 2
              WHEN 'SIMPLE' THEN 3
              ELSE 0
            END AS recovery_model,
            DATEDIFF(HH, MAX(b.backup_finish_date), GETDATE()),
            DATEDIFF(MI, MAX(b.backup_start_date), MAX(b.backup_finish_date))
          FROM master.dbo.sysdatabases a LEFT OUTER JOIN msdb.dbo.backupset b
          ON b.database_name = a.name
          GROUP BY a.name 
          ORDER BY a.name 
        };
      }
    } elsif ($self->mode =~ /server::database::logbackupage/) {
      if ($self->version_is_minimum("9.x")) {
        $sql = q{
          SELECT D.name AS [database_name], D.recovery_model, BS1.last_backup, BS1.last_duration
          FROM sys.databases D
          LEFT JOIN (
            SELECT BS.[database_name],
            DATEDIFF(HH,MAX(BS.[backup_finish_date]),GETDATE()) AS last_backup,
            DATEDIFF(MI,MAX(BS.[backup_start_date]),MAX(BS.[backup_finish_date])) AS last_duration
            FROM msdb.dbo.backupset BS
            WHERE BS.type = 'L'
            GROUP BY BS.[database_name]
          ) BS1 ON D.name = BS1.[database_name] WHERE D.source_database_id IS NULL
          ORDER BY D.[name];
        };
      } else {
        $self->no_such_mode();
      }
    }
    $self->get_db_tables([
        ['databases', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $columns],
    ]);
@{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
  } elsif ($self->mode =~ /server::database::auto(growths|shrinks)/) {
    if ($self->version_is_minimum("9.x")) {
      my $db_columns = ['name'];
      my $db_sql = q{
        SELECT name FROM master.sys.databases
      };
      $self->override_opt('lookback', 30) if ! $self->opts->lookback;
      my $evt_columns = ['name', 'count'];
      my $evt_sql = q{
          DECLARE @path NVARCHAR(1000)
          SELECT
              @path = Substring(PATH, 1, Len(PATH) - Charindex('\', Reverse(PATH))) + '\log.trc'
          FROM
              sys.traces
          WHERE
              id = 1
          SELECT
              databasename, COUNT(*)
          FROM 
              ::fn_trace_gettable(@path, 0)
          INNER JOIN
              sys.trace_events e
          ON
              eventclass = trace_event_id
          INNER JOIN
              sys.trace_categories AS cat
          ON
              e.category_id = cat.category_id
          WHERE
              e.name IN( EVENTNAME ) AND datediff(Minute, starttime, current_timestamp) < ?
          GROUP BY
              databasename
      };
      if ($self->mode =~ /server::database::autogrowths::file/) {
        $evt_sql =~ s/EVENTNAME/'Data File Auto Grow', 'Log File Auto Grow'/;
      } elsif ($self->mode =~ /server::database::autogrowths::logfile/) {
        $evt_sql =~ s/EVENTNAME/'Log File Auto Grow'/;
      } elsif ($self->mode =~ /server::database::autogrowths::datafile/) {
        $evt_sql =~ s/EVENTNAME/'Data File Auto Grow'/;
      }
      if ($self->mode =~ /server::database::autoshrinks::file/) {
        $evt_sql =~ s/EVENTNAME/'Data File Auto Shrink', 'Log File Auto Shrink'/;
      } elsif ($self->mode =~ /server::database::autoshrinks::logfile/) {
        $evt_sql =~ s/EVENTNAME/'Log File Auto Shrink'/;
      } elsif ($self->mode =~ /server::database::autoshrinks::datafile/) {
        $evt_sql =~ s/EVENTNAME/'Data File Auto Shrink'/;
      }
      $self->get_db_tables([
          ['databases', $db_sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $db_columns],
          ['events', $evt_sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $evt_columns, [$self->opts->lookback]],
      ]);
@{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
      foreach my $database (@{$self->{databases}}) {
        $database->{autogrowshrink} = eval {
            map { $_->{count} } grep { $_->{name} eq $database->{name} } @$self->{events}
        } || 0;
        $database->{growshrinkinterval} = $self->opts->lookback;
      }
    } else {
      $self->no_such_mode();
    }
  } elsif ($self->mode =~ /server::database::dbccshrinks/) {
    if ($self->version_is_minimum("9.x")) {
      my $db_columns = ['name'];
      my $db_sql = q{
        SELECT name FROM master.sys.databases
      };
      $self->override_opt('lookback', 30) if ! $self->opts->lookback;
      my $evt_columns = ['name', 'count'];
      # starttime = Oct 22 2012 01:51:41:373AM = DBD::Sybase datetype LONG
      my $evt_sql = q{
          DECLARE @path NVARCHAR(1000)
          SELECT
              @path = Substring(PATH, 1, Len(PATH) - Charindex('\', Reverse(PATH))) + '\log.trc'
          FROM
              sys.traces
          WHERE
              id = 1
          SELECT
              databasename, COUNT(*)
          FROM 
              ::fn_trace_gettable(@path, 0)
          INNER JOIN
              sys.trace_events e
          ON
              eventclass = trace_event_id
          INNER JOIN
              sys.trace_categories AS cat
          ON
              e.category_id = cat.category_id
          WHERE
              EventClass = 116 AND TEXTData LIKE '%SHRINK%' AND datediff(Minute, starttime, current_timestamp) < ?
          GROUP BY
              databasename
      };
      $self->get_db_tables([
          ['databases', $db_sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $db_columns],
          ['events', $evt_sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $evt_columns, [$self->opts->lookback]],
      ]);
@{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
      foreach my $database (@{$self->{databases}}) {
        $database->{autogrowshrink} = eval {
            map { $_->{count} } grep { $_->{name} eq $database->{name} } @$self->{events}
        } || 0;
        $database->{growshrinkinterval} = $self->opts->lookback;
      }
    } else {
      $self->no_such_mode();
    }
  }
}

sub check {
  my $self = shift;
  $self->add_info('checking databases');
  if ($self->mode =~ /server::database::(createuser)$/) {
    # --username admin --password ... --name <db> --name2 <monuser> --name3 <monpass>
    my $user = $self->opts->name2;
    #$user =~ s/\\/\\\\/g if $user =~ /\\/;
    $self->override_opt("name2", "[".$user."]");
    my $sql = sprintf "CREATE LOGIN %s %s DEFAULT_DATABASE=MASTER, DEFAULT_LANGUAGE=English", 
        $self->opts->name2,
        ($self->opts->name2 =~ /\\/) ?
            "FROM WINDOWS WITH" :
            sprintf("WITH PASSWORD='%s',", $self->opts->name3);
    $self->execute($sql);
    $self->execute(q{
      USE MASTER GRANT VIEW SERVER STATE TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE MASTER GRANT ALTER trace TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE MSDB CREATE USER
    }.$self->opts->name2.q{
      FOR LOGIN 
    }.$self->opts->name2);
    $self->execute(q{
      USE MSDB GRANT SELECT ON sysjobhistory TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE MSDB GRANT SELECT ON sysjobschedules TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE MSDB GRANT SELECT ON sysjobs TO 
    }.$self->opts->name2);
    if (my ($code, $message) = $self->check_messages(join_all => "\n")) {
      if (grep ! /(The server principal.*already exists)|(User.*group.*role.*already exists in the current database)/, split(/\n/, $message)) {
      } else {
        $self->clear_critical();
        foreach (@{$self->{databases}}) {
          $_->check();
        }
      } 
    }
    $self->add_ok("have fun");
  } elsif ($self->mode =~ /server::database::(listdatabases)$/) {
    $self->SUPER::check();
    $self->add_ok("have fun");
  } else {
    foreach (@{$self->{databases}}) {
      $_->check();
    }
  }
}

sub filesystems {
  my $self = shift;
  $self->get_db_tables([
      ['filesystems', 'exec master.dbo.xp_fixeddrives', 'Monitoring::GLPlugin::DB::TableItem', undef, ['drive', 'mb_free']],
  ]);
  $Classes::MSSQL::Component::DatabaseSubsystem::filesystems =
      { map { uc $_->{drive} => $_->{mb_free} } @{$self->{filesystems}} };
}

package Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub is_backup_node {
  my $self = shift;
  if ($self->version_is_minimum("11.x")) {
    if (exists $self->{preferred_replica} && $self->{preferred_replica} == 1) {
      return 1;
    } else {
      return 0;
    }
  } else {
    return 1;
  }
}

sub is_online {
  my $self = shift;
  return 0 if $self->{messages}->{critical} && grep /is offline/, @{$self->{messages}->{critical}};
  if ($self->version_is_minimum("9.x")) {
    return 1 if $self->{state_desc} && $self->{state_desc} eq "online";
    # ehem. offline = $self->{state} == 6 ? 1 : 0;
  } else {
    # bit 512 is offline
    return $self->{state} & 0x0200 ? 0 : 1;
  }
  return 0;
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

package Classes::MSSQL::Component::DatabaseSubsystem::Database;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub);
use strict;

sub finish {
  my $self = shift;
  $self->override_opt("units", "%") if ! $self->opts->units;
  $self->{state_desc} = lc $self->{state_desc} if $self->{state_desc};
  if ($self->mode =~ /server::database::(data(base.*|file)free|size)$/) {
    # privte copy for this database
    %{$self->{filesystems}} = %{$Classes::MSSQL::Component::DatabaseSubsystem::filesystems};
    my $sql;
    my $columns = ['filegroup_name', 'name', 'is_media_read_only', 'is_read_only',
        'is_sparse', 'size', 'max_size', 'growth', 'is_percent_growth',
        'used_size', 'type', 'state', 'drive', 'path'];
    if ($self->version_is_minimum("9.x")) {
      $sql = q{
        USE 
      [}.$self->{name}.q{]
        SELECT
          ISNULL(fg.name, 'TLOGS'),
          dbf.name,
          dbf.is_media_read_only,
          dbf.is_read_only,
          dbf.is_sparse, -- erstmal wurscht, evt. sys.dm_io_virtual_file_stats fragen
          -- dbf.size * 8.0 * 1024, 
          -- dbf.max_size * 8.0 * 1024 AS max_size, 
          -- dbf.growth,
          -- FILEPROPERTY(dbf.NAME,'SpaceUsed') * 8.0 * 1024 AS used_size,
          dbf.size, 
          dbf.max_size,
          dbf.growth,
          dbf.is_percent_growth,
          FILEPROPERTY(dbf.NAME,'SpaceUsed') AS used_size,
          dbf.type_desc,
          dbf.state_desc,
          UPPER(SUBSTRING(dbf.physical_name, 1, 1)) AS filesystem_drive_letter,         
          dbf.physical_name AS filesystem_path
        FROM
          sys.database_files AS dbf --use sys.master_files if the database is read only (more recent data)
        LEFT OUTER JOIN
          -- leider muss man mit AS arbeiten statt database_files.data_space_id.
          -- das kracht bei 2005-compatibility-dbs wegen irgendeines ansi-92/outer-join syntaxmischmaschs
          sys.filegroups AS fg
        ON
          dbf.data_space_id = fg.data_space_id 
      };
    }
    if ($self->is_online) {
      $self->localize_errors();
      $self->get_db_tables([
        ['datafiles', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafile', undef, $columns],
      ]);
      $self->globalize_errors();
      foreach my $filetype (qw(rows log)) {
        $self->{$filetype.'_size'} = 0;
        $self->{$filetype.'_max_size'} = 0;
        $self->{$filetype.'_used_size'} = 0;
        $self->{$filetype.'_allocated_size'} = 0;
        foreach my $datafile (grep {lc $_->{type} eq $filetype } @{$self->{datafiles}}) {
          $self->{$filetype.'_size'} += $datafile->{size};
          $self->{$filetype.'_allocated_size'} += $datafile->{size};
          $self->{$filetype.'_used_size'} += $datafile->{used_size};
          if ($datafile->{growth} == 0) {
            # waechst nicht, size ist bereits die max. groesse
            $self->{$filetype.'_max_size'} += $datafile->{size};
          } else {
            # limit oder nicht?
            if ($datafile->{max_size} == -1) {
              if (exists $self->{filesystems}->{$datafile->{drive}}) {
                # so gross wie das ding jetzt schon ist plus was vom filesystem noch weggefressen werden kann
                $self->{$filetype.'_max_size'} += $datafile->{size} + $self->{filesystems}->{$datafile->{drive}};
                delete $self->{filesystems}->{$datafile->{drive}};
              } else {
                # so gross wie es momentan ist. potentieller platz im fs wurde schon der db gutgeschrieben
                $self->{$filetype.'_max_size'} += $datafile->{size};
              }
            } else {
              # so gross wie das ding jemals werden kann
              $self->{$filetype.'_max_size'} += $datafile->{max_size};
            }
          }
        }
      }
    }
  } elsif ($self->mode =~ /server::database::(.*backupage)$/) {
    if ($self->version_is_minimum("11.x")) {
      my @replicated_databases = $self->fetchall_array(q{
        SELECT 
          DISTINCT CS.database_name AS [DatabaseName]
        FROM
          master.sys.availability_groups AS AG
        INNER JOIN
          master.sys.availability_replicas AS AR ON AG.group_id = AR.group_id
        INNER JOIN 
          master.sys.dm_hadr_database_replica_cluster_states AS CS
        ON
          AR.replica_id = CS.replica_id
        WHERE
          CS.is_database_joined = 1 -- DB muss aktuell auch in AG aktiv sein
      });
      if (grep { $self->{name} eq $_->[0] } @replicated_databases) {
        # this database is part of an availability group
        # find out if we are the preferred node, where the backup takes place
        $self->{preferred_replica} = $self->fetchrow_array(q{
          SELECT sys.fn_hadr_backup_is_preferred_replica(?)
        }, $self->{name});
      } else {
        # -> every node hat to be backupped, the db is local on every node
        $self->{preferred_replica} = 1;
      }
    }
  } elsif ($self->mode =~ /server::database::(transactions)$/) {
    # Transactions/sec ist irrefuehrend, das ist in Wirklichkeit ein Hochzaehldings
    $self->get_perf_counters([
        ['transactions', 'SQLServer:Databases', 'Transactions/sec', $self->{name}],
    ]);
    return if $self->check_messages();
    my $label = $self->{name}.'_transactions_per_sec';
    my $autoclosed = 0; 
    if ($self->{name} ne '_Total' && $self->version_is_minimum("9.x")) {
      my $sql = q{
          SELECT is_cleanly_shutdown, CAST(DATABASEPROPERTYEX('?', 'isautoclose') AS VARCHAR)
          FROM master.sys.databases WHERE name = '?'};
      $sql =~ s/\?/$self->{name}/g;
      my @autoclose = $self->fetchrow_array($sql);
      if ($autoclose[0] == 1 && $autoclose[1] == 1) {
        $autoclosed = 1;
      }      
    }      
    if ($autoclosed) {
      $self->{transactions_per_sec} = 0;
    }
    $self->set_thresholds(
        metric => $label,
        warning => 10000, critical => 50000 
    );  
    $self->add_message($self->check_thresholds(
        metric => $label,
        value => $self->{transactions_per_sec},
    ), sprintf "%s has %.4f transactions / sec",
        $self->{name}, $self->{transactions_per_sec}
    );  
    $self->add_perfdata(
        label => $label,
        value => $self->{transactions_per_sec},
    );  
  }
}

sub check {
  my $self = shift;
  if ($self->mode =~ /server::database::(listdatabases)$/) {
    printf "%s\n", $self->{name};
  } elsif ($self->mode =~ /server::database::(createuser)$/) {
    $self->execute(q{
      USE 
    }.$self->{name}.q{
      CREATE ROLE CHECKMSSQLHEALTH
    });
    $self->execute(q{
      USE
    }.$self->{name}.q{
      GRANT EXECUTE TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE
    }.$self->{name}.q{
      GRANT VIEW DATABASE STATE TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE
    }.$self->{name}.q{
      GRANT VIEW DEFINITION TO 
    }.$self->opts->name2);
    $self->execute(q{
      USE
    }.$self->{name}.q{
      CREATE USER 
    }.$self->opts->name2.q{
      FOR LOGIN 
    }.$self->opts->name2);
    $self->execute(q{
      USE
    }.$self->{name}.q{
      EXEC sp_addrolemember CHECKMSSQLHEALTH, 
    }.$self->opts->name2);
    if (my ($code, $message) = $self->check_messages(join_all => "\n")) {
      if (! grep ! /User.*group.*role.*already exists in the current database/, split(/\n/, $message)) {
        $self->clear_critical();
      } 
    }
  } elsif ($self->mode =~ /server::database::(database.*free)$/) {
    my @filetypes = qw(rows log);
    if ($self->mode =~ /server::database::(databasedatafree)$/) {
      @filetypes = qw(rows);
    } elsif ($self->mode =~ /server::database::(databaselogfree)$/) {
      @filetypes = qw(log);
    }
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
        next if ! exists $self->{$type."_size"}; # not every db has a separate log
        my $metric_pct = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_free_pct' : 'db_'.lc $self->{name}.'_log_free_pct';
        my $metric_units = ($type eq "rows") ? 
            'db_'.lc $self->{name}.'_free' : 'db_'.lc $self->{name}.'_log_free';
        my $metric_allocated = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_allocated_pct' : 'db_'.lc $self->{name}.'_log_allocated_pct';
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
        my $allocated_percent = 100 * $self->{$type."_allocated_size"} / $self->{$type."_max_size"};
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
  
        $self->add_perfdata(
            label => $metric_allocated,
            value => $allocated_percent,
            places => 2,
            uom => '%',
        );
      }
    }
    if ($self->mode =~ /server::database::(databaselogfree)$/ && ! exists $self->{log_size}) {
      $self->add_ok(sprintf "database %s has no logs", $self->{name});
    }
  } elsif ($self->mode =~ /server::database::datafilefree$/) {
    foreach (@{$self->{datafiles}}) {
      # filter name2 $_->{path}
      $_->check();
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
  } elsif ($self->mode =~ /server::database::size/) {
    $self->override_opt("units", "MB") if (! $self->opts->units || $self->opts->units eq "%");
    my $factor = 1;
    if (uc $self->opts->units eq "GB") {
      $factor = 1024 * 1024 * 1024;
    } elsif (uc $self->opts->units eq "MB") {
      $factor = 1024 * 1024;
    } elsif (uc $self->opts->units eq "KB") {
      $factor = 1024;
    }
    $self->add_ok(sprintf "db %s allocated %.4f%s",
        $self->{name}, $self->{rows_allocated_size} / $factor,
        $self->opts->units);
    $self->add_perfdata(
        label => 'db_'.$self->{name}.'_alloc_size',
        value => $self->{rows_allocated_size} / $factor,
        uom => $self->opts->units,
    );
    if ($self->{log_allocated_size}) {
      $self->add_ok(sprintf "db %s allocated %.4f%s",
          $self->{name}, $self->{log_allocated_size} / $factor,
          $self->opts->units);
      $self->add_perfdata(
          label => 'db_'.$self->{name}.'_alloc_log_size',
          value => $self->{log_allocated_size} / $factor,
          uom => $self->opts->units,
      );
    }
  } elsif ($self->mode =~ /server::database::(.*backupage)$/) {
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
  } elsif ($self->mode =~ /server::database::auto(growths|shrinks)/) {
    my $type = "";
    if ($self->mode =~ /::datafile/) {
      $type = "data ";
    } elsif ($self->mode =~ /::logfile/) {
      $type = "log ";
    }
    my $label = sprintf "%s_auto_%ss",
        $type, ($self->mode =~ /server::database::autogrowths/) ? "grow" : "shrink";
    $self->set_thresholds(
        metric => $label,
        warning => 1, critical => 5 
    );  
    $self->add_message(
        $self->check_thresholds(metric => $label, value => $self->{autogrowshrink}),
        sprintf "%s had %d %sfile auto %s events in the last %d minutes", $self->{name},
            $self->{autogrowshrink}, $type,
            ($self->mode =~ /server::database::autogrowths/) ? "grow" : "shrink",
            $self->{growshrinkinterval}
    );
  } elsif ($self->mode =~ /server::database::dbccshrinks/) {
    # nur relevant fuer master
    my $label = "dbcc_shrinks";
    $self->set_thresholds(
        metric => $label,
        warning => 1, critical => 5 
    );  
    $self->add_message(
        $self->check_thresholds(metric => $label, value => $self->{autogrowshrink}),
        sprintf "%s had %d DBCC Shrink events in the last %d minutes", $self->{name}, $self->{autogrowshrink}, $self->{growshrinkinterval});
  }
}

package Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafile;
our @ISA = qw(Classes::MSSQL::Component::DatabaseSubsystem::Database);
use strict;

sub finish {
  my $self = shift;
  # 8k-pages, umrechnen in bytes
  $self->{size} *= 8*1024;
  $self->{max_size} *= 8*1024 if $self->{max_size} != -1;
  $self->{used_size} *= 8*1024;
}

sub check {
  my $self = shift;
  if ($self->mode =~ /server::database::datafilefree$/) {
  }
}

