package Classes::MSSQL;
our @ISA = qw(Classes::Sybase);

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;
our $AUTOLOAD;


sub init {
  my $self = shift;
  $self->set_variable("dbuser", $self->fetchrow_array(
      q{ SELECT SYSTEM_USER }
  ));
  $self->set_variable("servicename", $self->fetchrow_array(
      q{ SELECT @@SERVICENAME }
  ));
  if (lc $self->get_variable("servicename") ne 'mssqlserver') {
    # braucht man fuer abfragen von dm_os_performance_counters
    # object_name ist entweder "SQLServer:Buffer Node" oder z.b. "MSSQL$OASH:Buffer Node"
    $self->set_variable("servicename", 'MSSQL$'.$self->get_variable("servicename"));
  } else {
    $self->set_variable("servicename", 'SQLServer');
  }
  $self->set_variable("ishadrenabled", $self->fetchrow_array(
      q{ SELECT CAST(COALESCE(SERVERPROPERTY('IsHadrEnabled'), 0) as int) }
  ));
  if ($self->mode =~ /^server::connectedsessions/) {
    my $connectedsessions;
    if ($self->get_variable("product") eq "ASE") {
      $connectedsessions = $self->fetchrow_array(q{
        SELECT
          COUNT(*)
        FROM
          master..sysprocesses
        WHERE
          hostprocess IS NOT NULL AND program_name != 'JS Agent'
      });
    } else {
      # http://www.sqlservercentral.com/articles/System+Tables/66335/
      # user processes start at 51
      $connectedsessions = $self->fetchrow_array(q{
        SELECT
          COUNT(*)
        FROM
          master..sysprocesses
        WHERE
          spid >= 51
      });
    }
    if (! defined $connectedsessions) {
      $self->add_unknown("unable to count connected sessions");
    } else {
      $self->set_thresholds(warning => 50, critical => 80);
      $self->add_message($self->check_thresholds($connectedsessions),
          sprintf "%d connected sessions", $connectedsessions);
      $self->add_perfdata(
          label => "connected_sessions",
          value => $connectedsessions
      );
    }
  } elsif ($self->mode =~ /^server::connectedusers/) {
    my $connectedusers;
    if ($self->get_variable("product") eq "ASE") {
      $connectedusers = $self->fetchrow_array(q{
        SELECT
          COUNT(DISTINCT loginame)
        FROM
          master..sysprocesses
        WHERE
          hostprocess IS NOT NULL AND program_name != 'JS Agent'
      });
    } else {
      # http://www.sqlservercentral.com/articles/System+Tables/66335/
      # user processes start at 51
      $connectedusers = $self->fetchrow_array(q{
        SELECT
          COUNT(DISTINCT loginame)
        FROM
          master..sysprocesses
        WHERE
          spid >= 51
      });
    }
  } elsif ($self->mode =~ /^server::cpubusy/) {
    if ($self->version_is_minimum("9.x")) {
      if (! defined ($self->{secs_busy} = $self->fetchrow_array(q{
          SELECT ((@@CPU_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
              (SELECT CAST(CPU_COUNT AS FLOAT) FROM sys.dm_os_sys_info) /
              1000000)
      }))) {
        $self->add_unknown("got no cputime from dm_os_sys_info");
      } else {
        $self->valdiff({ name => 'secs_busy' }, qw(secs_busy));
        $self->{cpu_busy} = 100 *
            $self->{delta_secs_busy} / $self->{delta_timestamp};
        $self->protect_value('cpu_busy', 'cpu_busy', 'percent');
      }
    } else {
      my @monitor = $self->exec_sp_1hash(q{exec sp_monitor});
      foreach (@monitor) {
        if ($_->[0] eq 'cpu_busy') {
          if ($_->[1] =~ /(\d+)%/) {
            $self->{cpu_busy} = $1;
          }
        }
      }
      self->requires_version('9') unless defined $self->{cpu_busy};
    }
    if (! $self->check_messages()) {
      $self->set_thresholds(warning => 80, critical => 90);
      $self->add_message($self->check_thresholds($self->{cpu_busy}),
          sprintf "CPU busy %.2f%%", $self->{cpu_busy});
      $self->add_perfdata(
          label => 'cpu_busy',
          value => $self->{cpu_busy},
          uom => '%',
      );
    }
  } elsif ($self->mode =~ /^server::iobusy/) {
    if ($self->version_is_minimum("9.x")) {
      if (! defined ($self->{secs_busy} = $self->fetchrow_array(q{
          SELECT ((@@IO_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
              (SELECT CAST(CPU_COUNT AS FLOAT) FROM sys.dm_os_sys_info) /
              1000000)
      }))) {
        $self->add_unknown("got no iotime from dm_os_sys_info");
      } else {
        $self->valdiff({ name => 'secs_busy' }, qw(secs_busy));
        $self->{io_busy} = 100 *
            $self->{delta_secs_busy} / $self->{delta_timestamp};
        $self->protect_value('io_busy', 'io_busy', 'percent');
      }
    } else {
      my @monitor = $self->exec_sp_1hash(q{exec sp_monitor});
      foreach (@monitor) {
        if ($_->[0] eq 'io_busy') {
          if ($_->[1] =~ /(\d+)%/) {
            $self->{io_busy} = $1;
          }
        }
      }
      self->requires_version('9') unless defined $self->{io_busy};
    }
    if (! $self->check_messages()) {
      $self->set_thresholds(warning => 80, critical => 90);
      $self->add_message($self->check_thresholds($self->{io_busy}),
          sprintf "IO busy %.2f%%", $self->{io_busy});
      $self->add_perfdata(
          label => 'io_busy',
          value => $self->{io_busy},
          uom => '%',
      );
    }
  } elsif ($self->mode =~ /^server::fullscans/) {
    $self->get_perf_counters([
        ['full_scans', 'SQLServer:Access Methods', 'Full Scans/sec'],
    ]);
    return if $self->check_messages();
    $self->set_thresholds(
        metric => 'full_scans_per_sec',
        warning => 100, critical => 500);
    $self->add_message(
        $self->check_thresholds(
            metric => 'full_scans_per_sec',
            value => $self->{full_scans_per_sec}),
        sprintf "%.2f full table scans / sec", $self->{full_scans_per_sec});
    $self->add_perfdata(
        label => 'full_scans_per_sec',
        value => $self->{full_scans_per_sec},
    );
  } elsif ($self->mode =~ /^server::latch::waittime/) {
    $self->get_perf_counters([
        ['latch_avg_wait_time', 'SQLServer:Latches', 'Average Latch Wait Time (ms)'],
        ['latch_wait_time_base', 'SQLServer:Latches', 'Average Latch Wait Time Base'],
    ]);
    return if $self->check_messages();
    $self->{latch_avg_wait_time} = $self->{latch_avg_wait_time} / $self->{latch_wait_time_base};
    $self->set_thresholds(
        metric => 'latch_avg_wait_time',
        warning => 1, critical => 5);
    $self->add_message(
        $self->check_thresholds(
            metric => 'latch_avg_wait_time',
            value => $self->{latch_avg_wait_time}),
        sprintf "latches have to wait %.2f ms avg", $self->{latch_avg_wait_time});
    $self->add_perfdata(
        label => 'latch_avg_wait_time',
        value => $self->{latch_avg_wait_time},
        uom => 'ms',
    );
  } elsif ($self->mode =~ /^server::latch::waits/) {
    $self->get_perf_counters([
        ['latch_waits', 'SQLServer:Latches', 'Latch Waits/sec'],
    ]);
    return if $self->check_messages();
    $self->set_thresholds(
        metric => 'latch_waits_per_sec',
        warning => 10, critical => 50);
    $self->add_message(
        $self->check_thresholds(
            metric => 'latch_waits_per_sec',
            value => $self->{latch_waits_per_sec}),
        sprintf "%.2f latches / sec have to wait", $self->{latch_waits_per_sec});
    $self->add_perfdata(
        label => 'latch_waits_per_sec',
        value => $self->{latch_waits_per_sec},
    );
  } elsif ($self->mode =~ /^server::sql.*compilations/) {
    $self->get_perf_counters([
        ['sql_recompilations', 'SQLServer:SQL Statistics', 'SQL Re-Compilations/sec'],
        ['sql_compilations', 'SQLServer:SQL Statistics', 'SQL Compilations/sec'],
    ]);
    return if $self->check_messages();
    # http://www.sqlmag.com/Articles/ArticleID/40925/pg/3/3.html
    # http://www.grumpyolddba.co.uk/monitoring/Performance%20Counter%20Guidance%20-%20SQL%20Server.htm
    if ($self->mode =~ /^server::sql::recompilations/) {
      $self->set_thresholds(
          metric => 'sql_recompilations_per_sec',
          warning => 1, critical => 10);
      $self->add_message(
          $self->check_thresholds(
              metric => 'sql_recompilations_per_sec',
              value => $self->{sql_recompilations_per_sec}),
          sprintf "%.2f SQL recompilations / sec", $self->{sql_recompilations_per_sec});
      $self->add_perfdata(
          label => 'sql_recompilations_per_sec',
          value => $self->{sql_recompilations_per_sec},
      );
    } else { # server::sql::initcompilations
      # ginge auch (weiter oben, mit sql_initcompilations im valdiff), birgt aber gefahren. warum? denksport
      # $self->{sql_initcompilations} = $self->{sql_compilations} - $self->{sql_recompilations};
      # $self->protect_value("sql_initcompilations", "sql_initcompilations", "positive");
      $self->{delta_sql_initcompilations} = $self->{delta_sql_compilations} - $self->{delta_sql_recompilations};
      $self->{sql_initcompilations_per_sec} = $self->{delta_sql_initcompilations} / $self->{delta_timestamp};
      $self->set_thresholds(
          metric => 'sql_initcompilations_per_sec',
          warning => 100, critical => 200);
      $self->add_message(
          $self->check_thresholds(
              metric => 'sql_initcompilations_per_sec',
              value => $self->{sql_initcompilations_per_sec}),
          sprintf "%.2f initial compilations / sec", $self->{sql_initcompilations_per_sec});
      $self->add_perfdata(
          label => 'sql_initcompilations_per_sec',
          value => $self->{sql_initcompilations_per_sec},
      );
    }
  } elsif ($self->mode =~ /^server::batchrequests/) {
    $self->get_perf_counters([
        ['batch_requests', 'SQLServer:SQL Statistics', 'Batch Requests/sec'],
    ]);
    return if $self->check_messages();
    $self->set_thresholds(
        metric => 'batch_requests_per_sec',
        warning => 100, critical => 200);
    $self->add_message(
        $self->check_thresholds(
            metric => 'batch_requests_per_sec',
            value => $self->{batch_requests_per_sec}),
        sprintf "%.2f batch requests / sec", $self->{batch_requests_per_sec});
    $self->add_perfdata(
        label => 'batch_requests_per_sec',
        value => $self->{batch_requests_per_sec},
    );
  } elsif ($self->mode =~ /^server::totalmemory/) {
    $self->get_perf_counters([
        ['total_server_memory', 'SQLServer:Memory Manager', 'Total Server Memory (KB)'],
    ]);
    return if $self->check_messages();
    my $warn = 1024*1024;
    my $crit = 1024*1024*5;
    my $factor = 1;
    if ($self->opts->units && lc $self->opts->units eq "mb") {
      $warn = 1024;
      $crit = 1024*5;
      $factor = 1024;
    } elsif ($self->opts->units && lc $self->opts->units eq "gb") {
      $warn = 1;
      $crit = 1*5;
      $factor = 1024*1024;
    } else {
      $self->override_opt("units", "kb");
    }
    $self->{total_server_memory} /= $factor;
    $self->set_thresholds(
        metric => 'total_server_memory',
        warning => $warn, critical => $crit);
    $self->add_message(
        $self->check_thresholds(
            metric => 'total_server_memory',
            value => $self->{total_server_memory}),
        sprintf "total server memory %.2f%s", $self->{total_server_memory}, $self->opts->units);
    $self->add_perfdata(
        label => 'total_server_memory',
        value => $self->{total_server_memory},
        uom => $self->opts->units,
    );
  } elsif ($self->mode =~ /^server::memorypool/) {
    $self->analyze_and_check_memorypool_subsystem("Classes::MSSQL::Component::MemorypoolSubsystem");
    $self->reduce_messages_short();
  } elsif ($self->mode =~ /^server::database/) {
    $self->analyze_and_check_database_subsystem("Classes::MSSQL::Component::DatabaseSubsystem");
    $self->reduce_messages_short();
  } elsif ($self->mode =~ /^server::availabilitygroup/) {
    $self->analyze_and_check_avgroup_subsystem("Classes::MSSQL::Component::AvailabilitygroupSubsystem");
    $self->reduce_messages_short();
  } elsif ($self->mode =~ /^server::jobs/) {
    $self->analyze_and_check_job_subsystem("Classes::MSSQL::Component::JobSubsystem");
    $self->reduce_messages_short();
  } elsif ($self->mode =~ /^server::uptime/) {
    ($self->{starttime}, $self->{uptime}) = $self->fetchrow_array(q{
        SELECT
          CONVERT(VARCHAR, sqlserver_start_time, 127) AS STARTUP_TIME_ISO8601,
          ROUND(DATEDIFF(SECOND, sqlserver_start_time, GETDATE()), 0) AS UPTIME_SECONDS
        FROM
            sys.dm_os_sys_info
    });
    $self->set_thresholds(
        metric => 'uptime',
        warning => "900:", critical => "300:");
    $self->add_message(
        $self->check_thresholds(
            metric => 'uptime',
            value => $self->{uptime}),
        sprintf "instance started at %s", $self->{starttime});
    $self->add_perfdata(
        label => 'uptime',
        value => $self->{uptime},
    );
  } else {
    $self->no_such_mode();
  }
}

sub get_perf_counters {
  my $self = shift;
  my $counters = shift;
  my @vars = ();
  foreach (@{$counters}) {
    my $var = $_->[0];
    push(@vars, $_->[3] ? $var.'_'.$_->[3] : $var);
    my $object_name = $_->[1];
    my $counter_name = $_->[2];
    my $instance_name = $_->[3];
    $self->{$var} = $self->get_perf_counter(
        $object_name, $counter_name, $instance_name
    );
    $self->add_unknown(sprintf "unable to aquire counter data %s %s%s",
        $object_name, $counter_name,
        $instance_name ? " (".$instance_name.")" : ""
    ) if ! defined $self->{$var};
    $self->valdiff({ name => $instance_name ? $var.'_'.$instance_name : $var }, $var) if $var;
  }
}

sub get_perf_counter {
  my $self = shift;
  my $object_name = shift;
  my $counter_name = shift;
  my $instance_name = shift;
  my $sql;
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $self->get_variable("servicename").':'.$1;
  }
  if ($self->version_is_minimum("9.x")) {
    $sql = q{
        SELECT
            cntr_value
        FROM
            sys.dm_os_performance_counters
        WHERE
            counter_name = ? AND
            object_name = ?
    };
  } else {
    $sql = q{
        SELECT
            cntr_value
        FROM
            master.dbo.sysperfinfo
        WHERE
            counter_name = ? AND
            object_name = ?
    };
  }
  if ($instance_name) {
    $sql .= " AND instance_name = ?";
    return $self->fetchrow_array($sql, $counter_name, $object_name, $instance_name);
  } else {
    return $self->fetchrow_array($sql, $counter_name, $object_name);
  }
}

sub get_perf_counter_instance {
  my $self = shift;
  my $object_name = shift;
  my $counter_name = shift;
  my $instance_name = shift;
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $self->get_variable("servicename").':'.$1;
  }
  if ($self->version_is_minimum("9.x")) {
    return $self->fetchrow_array(q{
        SELECT
            cntr_value
        FROM
            sys.dm_os_performance_counters
        WHERE
            counter_name = ? AND
            object_name = ? AND
            instance_name = ?
    }, $counter_name, $object_name, $instance_name);
  } else {
    return $self->fetchrow_array(q{
        SELECT
            cntr_value
        FROM
            master.dbo.sysperfinfo
        WHERE
            counter_name = ? AND
            object_name = ? AND
            instance_name = ?
    }, $counter_name, $object_name, $instance_name);
  }
}

sub get_instance_names {
  my $self = shift;
  my $object_name = shift;
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $self->get_variable("servicename").':'.$1;
  }
  if ($self->version_is_minimum("9.x")) {
    return $self->fetchall_array(q{
        SELECT
            DISTINCT instance_name
        FROM
            sys.dm_os_performance_counters
        WHERE
            object_name = ?
    }, $object_name);
  } else {
    return $self->fetchall_array(q{
        SELECT
            DISTINCT instance_name
        FROM
            master.dbo.sysperfinfo
        WHERE
            object_name = ?
    }, $object_name);
  }
}

sub has_threshold_table {
  my $self = shift;
  if (! exists $self->{has_threshold_table}) {
    my $find_sql;
    if ($self->version_is_minimum("9.x")) {
      $find_sql = q{
          SELECT name FROM sys.objects
          WHERE name = 'check_mssql_health_thresholds'
      };
    } else {
      $find_sql = q{
          SELECT name FROM sysobjects
          WHERE name = 'check_mssql_health_thresholds'
      };
    }
    if ($self->{handle}->fetchrow_array($find_sql)) {
      $self->{has_threshold_table} = 'check_mssql_health_thresholds';
    } else {
      $self->{has_threshold_table} = undef;
    }
  }
  return $self->{has_threshold_table};
}

sub add_dbi_funcs {
  my $self = shift;
  $self->SUPER::add_dbi_funcs() if $self->SUPER::can('add_dbi_funcs');
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::get_instance_names'} = \&{"Classes::MSSQL::get_instance_names"};
    *{'Monitoring::GLPlugin::DB::get_perf_counters'} = \&{"Classes::MSSQL::get_perf_counters"};
    *{'Monitoring::GLPlugin::DB::get_perf_counter'} = \&{"Classes::MSSQL::get_perf_counter"};
    *{'Monitoring::GLPlugin::DB::get_perf_counter_instance'} = \&{"Classes::MSSQL::get_perf_counter_instance"};
  }
}

sub compatibility_class {
  my $self = shift;
  # old extension packages inherit from DBD::MSSQL::Server
  # let DBD::MSSQL::Server inherit myself, so we can reach compatibility_methods
  {
    no strict 'refs';
    *{'DBD::MSSQL::Server::new'} = sub {};
    push(@DBD::MSSQL::Server::ISA, ref($self));
  }
}

sub compatibility_methods {
  my $self = shift;
  if ($self->isa("DBD::MSSQL::Server")) {
    # a old-style extension was loaded
    $self->SUPER::compatibility_methods() if $self->SUPER::can('compatibility_methods');
  }
}

__END__

                              RTM (no SP)     SP1            SP2            SP3            SP4
SQL Server 2014               12.00.2000.8
  (Hekaton, later SQL14)

SQL Server 2012               11.00.2100.60   11.00.3000.0   11.00.5058.0
  (Denali)

SQL Server 2008 R2            10.50.1600.1    10.50.2500.0   10.50.4000.0
  (Kilimanjaro)                               10.51.2500.0   10.52.4000.0

SQL Server 2008               10.00.1600.22   10.00.2531.0   10.00.4000.0   10.00.5500.0
  (Katmai)

SQL Server 2005               9.00.1399.06    9.00.2047      9.00.3042      9.00.4035      9.00.5000
  (Yukon)

SQL Server 2000               8.00.194        8.00.384       8.00.532       8.00.760       8.00.2039
  (Shiloh)

SQL Server 7.0                7.00.623        7.00.699       7.00.842       7.00.961       7.00.1063
  (Shpinx)





