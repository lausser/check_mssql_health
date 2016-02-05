package DBD::MSSQL::Server;

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  our $verbose = 0;
  our $scream = 0; # scream if something is not implemented
  our $my_modules_dyn_dir = ""; # where we look for self-written extensions

  my @servers = ();
  my $initerrors = undef;

  sub add_server {
    push(@servers, shift);
  }

  sub return_servers {
    return @servers;
  }
  
  sub return_first_server() {
    return $servers[0];
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    method => $params{method} || "dbi",
    hostname => $params{hostname},
    username => $params{username},
    password => $params{password},
    kerberos => $params{kerberos},
    port => $params{port} || 1433,
    server => $params{server},
    timeout => $params{timeout},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    verbose => $params{verbose},
    report => $params{report},
    commit => $params{commit},
    negate => $params{negate},
    selectedperfdata => $params{selectedperfdata},
    labelformat => $params{labelformat},
    version => 'unknown',
    os => 'unknown',
    servicename => 'unknown',
    instance => undef,
    memorypool => undef,
    databases => [],
    handle => undef,
  };
  bless $self, $class;
  $self->init_nagios();
  if ($self->dbconnect(%params)) {
    #$self->{version} = $self->{handle}->fetchrow_array(
    #    q{ SELECT SERVERPROPERTY('productversion') });
    # @@VERSION:
    # Variant1:
    # Adaptive Server Enterprise/15.5/EBF 18164 SMP ESD#2/P/x86_64/Enterprise Linux/asear155/2514/64-bit/FBO/Wed Aug 25 11:17:26 2010
    # Variant2: 
    # Microsoft SQL Server 2005 - 9.00.1399.06 (Intel X86)
    #    Oct 14 2005 00:33:37
    #    Copyright (c) 1988-2005 Microsoft Corporation
    #    Enterprise Edition on Windows NT 5.2 (Build 3790: Service Pack 2)

    map {
        $self->{os} = "Linux" if /Linux/;
        $self->{version} = $1 if /Adaptive Server Enterprise\/([\d\.]+)/;
        $self->{os} = $1 if /Windows (.*)/;
        $self->{version} = $1 if /SQL Server.*\-\s*([\d\.]+)/;
        $self->{product} = "ASE" if /Adaptive Server/;
        $self->{product} = "MSSQL" if /SQL Server/;
    } $self->{handle}->fetchrow_array(
        q{ SELECT @@VERSION });
    # params wird tiefer weitergereicht, z.b. zu databasefree
    $params{product} = $self->{product};
    if ($self->{product} eq "MSSQL") {
        $self->{dbuser} = $self->{handle}->fetchrow_array(
            q{ SELECT SYSTEM_USER });  # maybe SELECT SUSER_SNAME()
      $self->{servicename} = $self->{handle}->fetchrow_array(
          q{ SELECT @@SERVICENAME });
      if (lc $self->{servicename} ne 'mssqlserver') {
        # braucht man fuer abfragen von dm_os_performance_counters
        # object_name ist entweder "SQLServer:Buffer Node" oder z.b. "MSSQL$OASH:Buffer Node"
        $self->{servicename} = 'MSSQL$'.$self->{servicename};
      } else {
        $self->{servicename} = 'SQLServer';
      }
    } else {
        $self->{dbuser} = $self->{handle}->fetchrow_array(
            q{ SELECT SUSER_NAME() });
        $self->{maxpagesize} = $self->{handle}->fetchrow_array(
            q{ SELECT @@MAXPAGESIZE });
    }
    DBD::MSSQL::Server::add_server($self);
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $params{handle} = $self->{handle};
  $self->set_global_db_thresholds(\%params);
  if ($params{mode} =~ /^server::memorypool/) {
    $self->{memorypool} = DBD::MSSQL::Server::Memorypool->new(%params);
  } elsif ($params{mode} =~ /^server::database/) {
    DBD::MSSQL::Server::Database::init_databases(%params);
    if (my @databases =
        DBD::MSSQL::Server::Database::return_databases()) {
      $self->{databases} = \@databases;
    } else {
      $self->add_nagios_critical("unable to aquire database info");
    }
  } elsif ($params{mode} =~ /^server::jobs/) {
    DBD::MSSQL::Server::Job::init_jobs(%params);
    if (my @jobs =
        DBD::MSSQL::Server::Job::return_jobs()) {
      $self->{jobs} = \@jobs;
    } else {
      $self->add_nagios(
          defined $params{mitigation} ? $params{mitigation} : 2,
          sprintf "no jobs ran within the last %d minutes", $params{lookback}
      );
    }
  } elsif ($params{mode} =~ /^server::connectiontime/) {
    $self->{connection_time} = $self->{tac} - $self->{tic};
  } elsif ($params{mode} =~ /^server::cpubusy/) {
    if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
      #($self->{secs_busy}) = $self->{handle}->fetchrow_array(q{
      #    SELECT ((@@CPU_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
      #        (SELECT (CAST(CPU_COUNT AS FLOAT) / CAST(HYPERTHREAD_RATIO AS FLOAT)) FROM sys.dm_os_sys_info) /
      #        1000000)
      #});
      # new: people were complaining about percentages > 100%
      # http://sqlblog.com/blogs/kalen_delaney/archive/2007/12/08/hyperthreaded-or-not.aspx
      # count only cpus, virtual or not, cores or threads
      # this is some debugging code to see the single values with -v
      my $cpu_busy = $self->{handle}->fetchrow_array(q{
          SELECT @@CPU_BUSY FROM sys.dm_os_sys_info
      });
      my $timeticks = $self->{handle}->fetchrow_array(q{
          SELECT CAST(@@TIMETICKS AS FLOAT) FROM sys.dm_os_sys_info
      });
      my $cpu_count = $self->{handle}->fetchrow_array(q{
          SELECT CAST(CPU_COUNT AS FLOAT) FROM sys.dm_os_sys_info
      });
      my $hyperthread_ratio = $self->{handle}->fetchrow_array(q{
          SELECT CAST(HYPERTHREAD_RATIO AS FLOAT) FROM sys.dm_os_sys_info
      });
      ($self->{secs_busy}) = $self->{handle}->fetchrow_array(q{
          SELECT ((@@CPU_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
              (SELECT (CAST(CPU_COUNT AS FLOAT)) FROM sys.dm_os_sys_info) /
              1000000)
      });
      $self->valdiff(\%params, qw(secs_busy));
      if (defined $self->{secs_busy}) {
        $self->{cpu_busy} = 100 *
            $self->{delta_secs_busy} / $self->{delta_timestamp};
        $self->protect_value(\%params, 'cpu_busy', 'cpu_busy', 'percent');
      } else {
        $self->add_nagios_critical("got no cputime from dm_os_sys_info");
      }
    } else {
      #$self->requires_version('9');
      my @monitor = $params{handle}->exec_sp_1hash(q{exec sp_monitor});
      foreach (@monitor) {
        if ($_->[0] eq 'cpu_busy') {
          if ($_->[1] =~ /(\d+)%/) {
            $self->{cpu_busy} = $1;
          }
        }
      }
      self->requires_version('9') unless defined $self->{cpu_busy};
    }
  } elsif ($params{mode} =~ /^server::iobusy/) {
    if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
      #($self->{secs_busy}) = $self->{handle}->fetchrow_array(q{
      #    SELECT ((@@IO_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
      #        (SELECT (CAST(CPU_COUNT AS FLOAT) / CAST(HYPERTHREAD_RATIO AS FLOAT)) FROM sys.dm_os_sys_info) /
      #        1000000)
      #});
      ($self->{secs_busy}) = $self->{handle}->fetchrow_array(q{
          SELECT ((@@IO_BUSY * CAST(@@TIMETICKS AS FLOAT)) /
              (SELECT CAST(CPU_COUNT AS FLOAT) FROM sys.dm_os_sys_info) /
              1000000)
      });
#      ($self->{secs_busy2}) = $self->{handle}->fetchrow_array(q{
#          SELECT
#              SUM(WAIT_TIME_MS) / 1000.0
#          FROM
#              sys.dm_os_wait_stats
#          WHERE
#              wait_type IN ('ASYNC_IO_COMPLETION', 'IO_COMPLETION', 
#                  'WRITELOG', 'BACKUPIO')
#              OR wait_type like 'PAGEIOLATCH%'
#      });
#      ($self->{secs_busy}) = $self->{handle}->fetchrow_array(q{
#        -- if pct signal wait > 10%, means that more cpu are required 
#          SELECT 
#              CAST(100.0 * SUM(signal_wait_time_ms) / SUM(wait_time_ms)) 
#                  AS [%signal (cpu) waits],
#              CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM(wait_time_ms))
#                  AS [%resource waits]
#          FROM sys.dm_os_wait_stats
#      });
 
      $self->valdiff(\%params, qw(secs_busy));
      if (defined $self->{secs_busy}) {
        $self->{io_busy} = 100 *
            $self->{delta_secs_busy} / $self->{delta_timestamp};
        $self->protect_value(\%params, 'io_busy', 'io_busy', 'percent');
      } else {
        $self->add_nagios_critical("got no iotime from dm_os_sys_info");
      }
    } else {
      #$self->requires_version('9');
      my @monitor = $params{handle}->exec_sp_1hash(q{exec sp_monitor});
      foreach (@monitor) {
        if ($_->[0] eq 'io_busy') {
          if ($_->[1] =~ /(\d+)%/) {
            $self->{io_busy} = $1;
          }
        }
      }
      self->requires_version('9') unless defined $self->{io_busy};
    }
  } elsif ($params{mode} =~ /^server::fullscans/) {
    $self->{cnt_full_scans_s} = $self->{handle}->get_perf_counter(
        'SQLServer:Access Methods', 'Full Scans/sec');
    if (! defined $self->{cnt_full_scans_s}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    } else {
      $self->valdiff(\%params, qw(cnt_full_scans_s));
      $self->{full_scans_per_sec} = $self->{delta_cnt_full_scans_s} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /^server::latch::waittime/) {
    $self->{latch_wait_time} = $self->{handle}->get_perf_counter(
        "SQLServer:Latches", "Average Latch Wait Time (ms)");
    $self->{latch_wait_time_base} = $self->{handle}->get_perf_counter(
        "SQLServer:Latches", "Average Latch Wait Time Base");
    if (! defined $self->{latch_wait_time}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    }
    $self->{latch_wait_time} = $self->{latch_wait_time} / $self->{latch_wait_time_base};
  } elsif ($params{mode} =~ /^server::latch::waits/) {
    $self->{latch_waits_s} = $self->{handle}->get_perf_counter(
        "SQLServer:Latches", "Latch Waits/sec");
    if (! defined $self->{latch_waits_s}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    } else {
      $self->valdiff(\%params, qw(latch_waits_s));
      $self->{latch_waits_per_sec} = $self->{delta_latch_waits_s} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /^server::sql::.*compilations/) {
    $self->{recompilations_s} = $self->{handle}->get_perf_counter(
        "SQLServer:SQL Statistics", "SQL Re-Compilations/sec");
    $self->{compilations_s} = $self->{handle}->get_perf_counter(
        "SQLServer:SQL Statistics", "SQL Compilations/sec");
    if (! defined $self->{recompilations_s}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    } else {
      $self->valdiff(\%params, qw(recompilations_s compilations_s));
      # http://www.sqlmag.com/Articles/ArticleID/40925/pg/3/3.html
      # http://www.grumpyolddba.co.uk/monitoring/Performance%20Counter%20Guidance%20-%20SQL%20Server.htm
      $self->{delta_initial_compilations_s} = $self->{delta_compilations_s} - 
          $self->{delta_recompilations_s};
      $self->{initial_compilations_per_sec} = 
          $self->{delta_initial_compilations_s} / $self->{delta_timestamp};
      $self->{recompilations_per_sec} = 
          $self->{delta_recompilations_s} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /^server::batchrequests/) {
    $self->{batch_requests_s} = $self->{handle}->get_perf_counter(
        "SQLServer:SQL Statistics", "Batch Requests/sec");
    if (! defined $self->{batch_requests_s}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    } else {
      $self->valdiff(\%params, qw(batch_requests_s));
      $self->{batch_requests_per_sec} = $self->{delta_batch_requests_s} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /^server::totalmemory/) {
    $self->{total_memory} = $self->{handle}->get_perf_counter(
        "SQLServer:Memory Manager", "Total Server Memory (KB)");
    if (! defined $self->{total_memory}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    }
  } elsif ($params{mode} =~ /^server::connectedusers/) {
    if ($self->{product} eq "ASE") {
      $self->{connectedusers} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM master..sysprocesses WHERE hostprocess IS NOT NULL AND program_name != 'JS Agent'
      });
    } else {
      # http://www.sqlservercentral.com/articles/System+Tables/66335/
      # user processes start at 51
      $self->{connectedusers} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM master..sysprocesses WHERE spid >= 51
      });
    }
    if (! defined $self->{connectedusers}) {
      $self->add_nagios_unknown("unable to count connected users");
    }
  } elsif ($params{mode} =~ /^server::sqlruntime/) {
    $self->set_local_db_thresholds(%params);
    my $tic = Time::HiRes::time();
      @{$self->{genericsql}} =
          $self->{handle}->fetchrow_array($params{selectname});
    $self->{runtime} = Time::HiRes::time() - $tic;
  } elsif ($params{mode} =~ /^server::sql/) {
    $self->set_local_db_thresholds(%params);
    if ($params{regexp}) {
      # sql output is treated as text
      if ($params{name2} eq $params{name}) {
        $self->add_nagios_unknown(sprintf "where's the regexp????");
      } else {
        $self->{genericsql} =
            $self->{handle}->fetchrow_array($params{selectname});
        if (! defined $self->{genericsql}) {
          $self->add_nagios_unknown(sprintf "got no valid response for %s",
              $params{selectname});
        }
      }
    } else {
      # sql output must be a number (or array of numbers)
      @{$self->{genericsql}} =
          $self->{handle}->fetchrow_array($params{selectname});
      if (! (defined $self->{genericsql} &&
          (scalar(grep { /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/ } @{$self->{genericsql}})) == 
          scalar(@{$self->{genericsql}}))) {
        $self->add_nagios_unknown(sprintf "got no valid response for %s",
            $params{selectname});
      } else {
        # name2 in array
        # units in array
      }
    }
  } elsif ($params{mode} =~ /^my::([^:.]+)/) {
    my $class = $1;
    my $loaderror = undef;
    substr($class, 0, 1) = uc substr($class, 0, 1);
    foreach my $libpath (split(":", $DBD::MSSQL::Server::my_modules_dyn_dir)) {
      foreach my $extmod (glob $libpath."/CheckMSSQLHealth*.pm") {
        eval {
          $self->trace(sprintf "loading module %s", $extmod);
          require $extmod;
        };
        if ($@) {
          $loaderror = $extmod;
          $self->trace(sprintf "failed loading module %s: %s", $extmod, $@);
        }
      }
    }
    my $obj = {
        handle => $params{handle},
        warningrange => $params{warningrange},
        criticalrange => $params{criticalrange},
    };
    bless $obj, "My$class";
    $self->{my} = $obj;
    if ($self->{my}->isa("DBD::MSSQL::Server")) {
      my $dos_init = $self->can("init");
      my $dos_nagios = $self->can("nagios");
      my $my_init = $self->{my}->can("init");
      my $my_nagios = $self->{my}->can("nagios");
      if ($my_init == $dos_init) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs an init() method", ref($self->{my}));
      } elsif ($my_nagios == $dos_nagios) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs a nagios() method", ref($self->{my}));
      } else {
        $self->{my}->init_nagios(%params);
        $self->{my}->init(%params);
      }
    } else {
      $self->add_nagios_unknown(
          sprintf "Class %s is not a subclass of DBD::MSSQL::Server%s", 
              ref($self->{my}),
              $loaderror ? sprintf " (syntax error in %s?)", $loaderror : "" );
    }
  } else {
    printf "broken mode %s\n", $params{mode};
  }
}

sub dump {
  my $self = shift;
  my $message = shift || "";
  printf "%s %s\n", $message, Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /^server::instance/) {
      $self->{instance}->nagios(%params);
      $self->merge_nagios($self->{instance});
    } elsif ($params{mode} =~ /server::database::listdatabases/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{databases}}) {
        printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /^server::database/) {
      foreach (@{$self->{databases}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /^server::database/) {
    } elsif ($params{mode} =~ /^server::jobs/) {
      foreach (@{$self->{jobs}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /^server::lock/) {
      foreach (@{$self->{locks}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /^server::memorypool/) {
      $self->{memorypool}->nagios(%params);
      $self->merge_nagios($self->{memorypool});
    } elsif ($params{mode} =~ /^server::connectiontime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connection_time}, 1, 5),
          sprintf "%.2f seconds to connect as %s",
              $self->{connection_time}, $self->{dbuser});
      $self->add_perfdata(sprintf "connection_time=%.2f;%d;%d",
          $self->{connection_time},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::cpubusy/) {
      $self->add_nagios(
          $self->check_thresholds($self->{cpu_busy}, 80, 90),
          sprintf "CPU busy %.2f%%", $self->{cpu_busy});
      $self->add_perfdata(sprintf "cpu_busy=%.2f;%s;%s",
          $self->{cpu_busy},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::iobusy/) {
      $self->add_nagios(
          $self->check_thresholds($self->{io_busy}, 80, 90),
          sprintf "IO busy %.2f%%", $self->{io_busy});
      $self->add_perfdata(sprintf "io_busy=%.2f;%s;%s",
          $self->{io_busy},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::fullscans/) {
      $self->add_nagios(
          $self->check_thresholds($self->{full_scans_per_sec}, 100, 500),
          sprintf "%.2f full table scans / sec", $self->{full_scans_per_sec});
      $self->add_perfdata(sprintf "full_scans_per_sec=%.2f;%s;%s",
          $self->{full_scans_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::latch::waits/) {
      $self->add_nagios(
          $self->check_thresholds($self->{latch_waits_per_sec}, 10, 50),
          sprintf "%.2f latches / sec have to wait", $self->{latch_waits_per_sec});
      $self->add_perfdata(sprintf "latch_waits_per_sec=%.2f;%s;%s",
          $self->{latch_waits_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::latch::waittime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{latch_wait_time}, 1, 5),
          sprintf "latches have to wait %.2f ms avg", $self->{latch_wait_time});
      $self->add_perfdata(sprintf "latch_avg_wait_time=%.2fms;%s;%s",
          $self->{latch_wait_time},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sql::recompilations/) {
      $self->add_nagios(
          $self->check_thresholds($self->{recompilations_per_sec}, 1, 10),
          sprintf "%.2f SQL recompilations / sec", $self->{recompilations_per_sec});
      $self->add_perfdata(sprintf "sql_recompilations_per_sec=%.2f;%s;%s",
          $self->{recompilations_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sql::initcompilations/) {
      $self->add_nagios(
          $self->check_thresholds($self->{initial_compilations_per_sec}, 100, 200),
          sprintf "%.2f initial compilations / sec", $self->{initial_compilations_per_sec});
      $self->add_perfdata(sprintf "sql_initcompilations_per_sec=%.2f;%s;%s",
          $self->{initial_compilations_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::batchrequests/) {
      $self->add_nagios(
          $self->check_thresholds($self->{batch_requests_per_sec}, 100, 200),
          sprintf "%.2f batch requests / sec", $self->{batch_requests_per_sec});
      $self->add_perfdata(sprintf "batch_requests_per_sec=%.2f;%s;%s",
          $self->{batch_requests_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::totalmemory/) {
      $self->add_nagios(
          $self->check_thresholds($self->{total_memory}, 1000, 5000),
          sprintf "total server memory %ld", $self->{total_memory});
      $self->add_perfdata(sprintf "total_server_memory=%ld;%s;%s",
          $self->{total_memory},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::connectedusers/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connectedusers}, 50, 80),
          sprintf "%d connected users", $self->{connectedusers});
      $self->add_perfdata(sprintf "connected_users=%d;%s;%s",
          $self->{connectedusers},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sqlruntime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{runtime}, 1, 5),
          sprintf "%.2f seconds to execute %s",
              $self->{runtime},
              $params{name2} ? $params{name2} : $params{selectname});
      $self->add_perfdata(sprintf "sql_runtime=%.4f;%d;%d",
          $self->{runtime},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_nagios_unknown($self->{handle}->{errstr}) if 
          $self->{handle}->{errstr} && 
              ! (defined $params{mitigation} && $params{mitigation} == 0);
    } elsif ($params{mode} =~ /^server::sql/) {
      if ($self->{handle}->{errstr} && 
          ! (defined $params{mitigation} && $params{mitigation} == 0)) {
        $self->add_nagios_unknown($self->{handle}->{errstr}) 
      } elsif ($params{regexp}) {
        if (substr($params{name2}, 0, 1) eq '!') {
          $params{name2} =~ s/^!//;
          if ($self->{genericsql} !~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2}); 
          } else {
            $self->add_nagios_critical(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        } else {
          if ($self->{genericsql} =~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          } else {
            $self->add_nagios_critical(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        }
      } else {
        $self->add_nagios(
            # the first item in the list will trigger the threshold values
            $self->check_thresholds($self->{genericsql}[0], 1, 5),
                sprintf "%s: %s%s",
                $params{name2} ? lc $params{name2} : lc $params{selectname},
                # float as float, integers as integers
                join(" ", map {
                    (sprintf("%d", $_) eq $_) ? $_ : sprintf("%f", $_)
                } @{$self->{genericsql}}),
                $params{units} ? $params{units} : "");
        my $i = 0;
        # workaround... getting the column names from the database would be nicer
        my @names2_arr = split(/\s+/, $params{name2});
        foreach my $t (@{$self->{genericsql}}) {
          $self->add_perfdata(sprintf "\'%s\'=%s%s;%s;%s",
              $names2_arr[$i] ? lc $names2_arr[$i] : lc $params{selectname},
              # float as float, integers as integers
              (sprintf("%d", $t) eq $t) ? $t : sprintf("%f", $t),
              $params{units} ? $params{units} : "",
            ($i == 0) ? $self->{warningrange} : "",
              ($i == 0) ? $self->{criticalrange} : ""
          );  
          $i++;
        }
      }
    } elsif ($params{mode} =~ /^my::([^:.]+)/) {
      $self->{my}->nagios(%params);
      $self->merge_nagios($self->{my});
    }
  }
}


sub init_nagios {
  my $self = shift;
  no strict 'refs';
  if (! ref($self)) {
    my $nagiosvar = $self."::nagios";
    my $nagioslevelvar = $self."::nagios_level";
    $$nagiosvar = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $$nagioslevelvar = $ERRORS{OK},
  } else {
    $self->{nagios} = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $self->{nagios_level} = $ERRORS{OK},
  }
}

sub check_thresholds {
  my $self = shift;
  my $value = shift;
  my $defaultwarningrange = shift;
  my $defaultcriticalrange = shift;
  my $level = $ERRORS{OK};
  $self->{warningrange} = defined $self->{warningrange} ?
      $self->{warningrange} : $defaultwarningrange;
  $self->{criticalrange} = defined $self->{criticalrange} ?
      $self->{criticalrange} : $defaultcriticalrange;

  if ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = 10, warn if > 10 or < 0
    $level = $ERRORS{WARNING}
        if ($value > $1 || $value < 0);
  } elsif ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+):$/) {
    # warning = 10:, warn if < 10
    $level = $ERRORS{WARNING}
        if ($value < $1);
  } elsif ($self->{warningrange} =~ /^~:([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = ~:10, warn if > 10
    $level = $ERRORS{WARNING}
        if ($value > $1);
  } elsif ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = 10:20, warn if < 10 or > 20
    $level = $ERRORS{WARNING}
        if ($value < $1 || $value > $2);
  } elsif ($self->{warningrange} =~ /^@([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = @10:20, warn if >= 10 and <= 20
    $level = $ERRORS{WARNING}
        if ($value >= $1 && $value <= $2);
  }
  if ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = 10, crit if > 10 or < 0
    $level = $ERRORS{CRITICAL}
        if ($value > $1 || $value < 0);
  } elsif ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+):$/) {
    # critical = 10:, crit if < 10
    $level = $ERRORS{CRITICAL}
        if ($value < $1);
  } elsif ($self->{criticalrange} =~ /^~:([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = ~:10, crit if > 10
    $level = $ERRORS{CRITICAL}
        if ($value > $1);
  } elsif ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = 10:20, crit if < 10 or > 20
    $level = $ERRORS{CRITICAL}
        if ($value < $1 || $value > $2);
  } elsif ($self->{criticalrange} =~ /^@([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = @10:20, crit if >= 10 and <= 20
    $level = $ERRORS{CRITICAL}
        if ($value >= $1 && $value <= $2);
  }
  return $level;
  #
  # syntax error must be reported with returncode -1
  #
}

sub add_nagios {
  my $self = shift;
  my $level = shift;
  my $message = shift;
  push(@{$self->{nagios}->{messages}->{$level}}, $message);
  # recalc current level
  foreach my $llevel (qw(CRITICAL WARNING UNKNOWN OK)) {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$llevel}}})) {
      $self->{nagios_level} = $ERRORS{$llevel};
    }
  }
}

sub add_nagios_ok {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{OK}, $message);
}

sub add_nagios_warning {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{WARNING}, $message);
}

sub add_nagios_critical {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{CRITICAL}, $message);
}

sub add_nagios_unknown {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{UNKNOWN}, $message);
}

sub add_perfdata {
  my $self = shift;
  my $data = shift;
  push(@{$self->{nagios}->{perfdata}}, $data);
}

sub merge_nagios {
  my $self = shift;
  my $child = shift;
  foreach my $level (0..3) {
    foreach (@{$child->{nagios}->{messages}->{$level}}) {
      $self->add_nagios($level, $_);
    }
    #push(@{$self->{nagios}->{messages}->{$level}},
    #    @{$child->{nagios}->{messages}->{$level}});
  }
  push(@{$self->{nagios}->{perfdata}}, @{$child->{nagios}->{perfdata}});
}

sub calculate_result {
  my $self = shift;
  my $labels = shift || {};
  my $multiline = 0;
  map {
    $self->{nagios_level} = $ERRORS{$_} if
        (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}}));
  } ("OK", "UNKNOWN", "WARNING", "CRITICAL");
  if ($ENV{NRPE_MULTILINESUPPORT} &&
      length join(" ", @{$self->{nagios}->{perfdata}}) > 200) {
    $multiline = 1;
  }
  my $all_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN", "OK"));
  my $bad_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN"));
  my $good_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("OK"));
  my $all_messages_short = $bad_messages ? $bad_messages : 'no problems';
  # if mode = my-....
  # and there are some ok-messages
  # output them instead of "no problems"
  if ($self->{mode} =~ /^my\:\:/ && $good_messages) {
    $all_messages_short = $bad_messages ? $bad_messages : $good_messages;
  }
  my $all_messages_html = "<table style=\"border-collapse: collapse;\">".
      join("", map {
          my $level = $_;
          join("", map {
              sprintf "<tr valign=\"top\"><td class=\"service%s\">%s</td></tr>",
              $level, $_;
          } @{$self->{nagios}->{messages}->{$ERRORS{$_}}});
      } grep {
          scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
      } ("CRITICAL", "WARNING", "UNKNOWN", "OK")).
  "</table>";
  if (exists $self->{identstring}) {
    $self->{nagios_message} .= $self->{identstring};
  }
  if ($self->{report} eq "long") {
    $self->{nagios_message} .= $all_messages;
  } elsif ($self->{report} eq "short") {
    $self->{nagios_message} .= $all_messages_short;
  } elsif ($self->{report} eq "html") {
    $self->{nagios_message} .= $all_messages_short."\n".$all_messages_html;
  }
  foreach my $from (keys %{$self->{negate}}) {
    if ((uc $from) =~ /^(OK|WARNING|CRITICAL|UNKNOWN)$/ &&
        (uc $self->{negate}->{$from}) =~ /^(OK|WARNING|CRITICAL|UNKNOWN)$/) {
      if ($self->{nagios_level} == $ERRORS{uc $from}) {
        $self->{nagios_level} = $ERRORS{uc $self->{negate}->{$from}};
      }
    }
  }
  if ($self->{labelformat} eq "pnp4nagios") {
    $self->{perfdata} = join(" ", grep {
        if ($self->{selectedperfdata}) {
          /^(.*?)=/;
          my $label = $1;
          if ($label =~ /$self->{selectedperfdata}/) {
            1;
          } else {
            0;
          }
        } else {
          1;
        }
    } @{$self->{nagios}->{perfdata}});
  } else {
    $self->{perfdata} = join(" ", map {
        my $perfdata = $_;
        if ($perfdata =~ /^(.*?)=(.*)/) {
          my $label = $1;
          my $data = $2;
          if (exists $labels->{$label} &&
              exists $labels->{$label}->{$self->{labelformat}}) {
            $labels->{$label}->{$self->{labelformat}}."=".$data;
          } else {
            $perfdata;
          }
        } else {
          $perfdata;
        }
    } @{$self->{nagios}->{perfdata}});
  }
}

sub set_global_db_thresholds {
  my $self = shift;
  my $params = shift;
  my $warning = undef;
  my $critical = undef;
  return unless defined $params->{dbthresholds};
  $params->{name0} = $params->{dbthresholds};
  # :pluginmode   :name     :warning    :critical
  # mode          empty
  #
  eval {
    my $find_sql = undef;
    if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
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
      my @dbthresholds = $self->{handle}->fetchall_array(q{
          SELECT * FROM check_mssql_health_thresholds
      });
      $params->{dbthresholds} = \@dbthresholds;
      foreach (@dbthresholds) {
        if (($_->[0] eq $params->{cmdlinemode}) &&
            (! defined $_->[1] || ! $_->[1])) {
          ($warning, $critical) = ($_->[2], $_->[3]);
        }
      }
    }
  };
  if (! $@) {
    if ($warning) {
      $params->{warningrange} = $warning;
      $self->trace("read warningthreshold %s from database", $warning);
    }
    if ($critical) {
      $params->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s from database", $critical);
    }
  }
}

sub set_local_db_thresholds {
  my $self = shift;
  my %params = @_;
  my $warning = undef;
  my $critical = undef;
  # :pluginmode   :name     :warning    :critical
  # mode          name0
  # mode          name2
  # mode          name
  #
  # first: argument of --dbthresholds, it it exists
  # second: --name2
  # third: --name
  if (ref($params{dbthresholds}) eq 'ARRAY') {
    my $marker;
    foreach (@{$params{dbthresholds}}) {
      if ($_->[0] eq $params{cmdlinemode}) {
        if (defined $_->[1] && $params{name0} && $_->[1] eq $params{name0}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name0};
          last;
        } elsif (defined $_->[1] && $params{name2} && $_->[1] eq $params{name2}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name2};
          last;
        } elsif (defined $_->[1] && $params{name} && $_->[1] eq $params{name}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name};
          last;
        }
      }
    }
    if ($warning) {
      $self->{warningrange} = $warning;
      $self->trace("read warningthreshold %s for %s from database",
         $marker, $warning);
    }
    if ($critical) {
      $self->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s for %s from database",
          $marker, $critical);
    }
  }
}

sub debug {
  my $self = shift;
  my $msg = shift;
  if ($DBD::MSSQL::Server::verbose) {
    printf "%s %s\n", $msg, ref($self);
  }
}

sub dbconnect {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{tic} = Time::HiRes::time();
  $self->{handle} = DBD::MSSQL::Server::Connection->new(%params);
  if ($self->{handle}->{errstr}) {
    if ($self->{handle}->{errstr} eq "alarm\n") {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "connection could not be established within %d seconds",
              $self->{timeout});
    } else {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "cannot connect to %s. %s",
          ($self->{server} ? $self->{server} :
          ($self->{hostname} ? $self->{hostname} : "unknown host")),
          $self->{handle}->{errstr});
      $retval = undef;
    }
  } else {
    $retval = $self->{handle};
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub trace {
  my $self = shift;
  my $format = shift;
  if (! @_) {
    # falls im sql-statement % vorkommen. sonst krachts im printf
    $format =~ s/%/%%/g;
  }
  $self->{trace} = -f "/tmp/check_mssql_health.trace" ? 1 : 0;
  if ($DBD::MSSQL::Server::verbose) {
    printf("%s: ", scalar localtime);
    printf($format, @_);
  }
  if ($self->{trace}) {
    my $logfh = new IO::File;
    $logfh->autoflush(1);
    if ($logfh->open("/tmp/check_mssql_health.trace", "a")) {
      $logfh->printf("%s: ", scalar localtime);
      $logfh->printf($format, @_);
      $logfh->printf("\n");
      $logfh->close();
    }
  }
}

sub DESTROY {
  my $self = shift;
  my $handle1 = "null";
  my $handle2 = "null";
  if (defined $self->{handle}) {
    $handle1 = ref($self->{handle});
    if (defined $self->{handle}->{handle}) {
      $handle2 = ref($self->{handle}->{handle});
    }
  }
  #$self->trace(sprintf "DESTROY %s with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MSSQL::Server") {
  }
  #$self->trace(sprintf "DESTROY %s exit with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MSSQL::Server") {
    #printf "humpftata\n";
  }
}

# $self->protect_value(\%params, 'cpu_busy', 'cpu_busy', 'percent');
sub protect_value {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my $ident = shift;
  my $key = shift;
  my $validfunc = shift;
  if (ref($validfunc) ne "CODE" && $validfunc eq "percent") {
    $validfunc = sub {
      my $value = shift;
      return ($value < 0 || $value > 100) ? 0 : 1;
    }
  }
  if (&$validfunc($self->{$key})) {
    $self->save_state(%params, (name => 'protect_'.$ident.'_'.$key, save => {
        $key => $self->{$key},
        exception => 0,
    }));
  } else {
    # if the device gives us an clearly wrong value, simply use the last value.
    my $laststate = $self->load_state(%params, (name => 'protect_'.$ident.'_'.$key));
    $self->debug(sprintf "self->{%s} is %s and invalid for the %dth time",
        $key, $self->{$key}, $laststate->{exception} + 1);
    if ($laststate->{exception} < 4) {
      # but only 5 times. 
      # if the error persists, somebody has to check the device.
      $self->{$key} = $laststate->{$key};
    }
    $laststate->{exception}++;
    $self->save_state(%params, (name => 'protect_'.$ident.'_'.$key, save => {
        $key => $self->{$key},
        exception => $laststate->{exception},
    }));
  }
}

sub save_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  }
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  if (! -d $params{statefilesdir}) {
    eval {
      use File::Path;
      mkpath $params{statefilesdir};
    };
  }
  if ($@ || ! -w $params{statefilesdir}) {
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefilesdir %s does not exist or is not writable\n",
        $params{statefilesdir});
    return;
  }
  my $statefile = sprintf "%s_%s", ($params{hostname} || $params{server}), $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if (open(STATE, ">$statefile")) {
    if ((ref($params{save}) eq "HASH") && exists $params{save}->{timestamp}) {
      $params{save}->{localtime} = scalar localtime $params{save}->{timestamp};
    }
    printf STATE Data::Dumper::Dumper($params{save});
    close STATE;
  } else {
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefile %s is not writable", $statefile);
  }
  $self->debug(sprintf "saved %s to %s",
      Data::Dumper::Dumper($params{save}), $statefile);
}

sub load_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  }
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  my $statefile = sprintf "%s_%s", ($params{hostname} || $params{server}), $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if ( -f $statefile) {
    our $VAR1;
    eval {
      require $statefile;
    };
    if($@) {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "statefile %s is corrupt", $statefile);
    }
    $self->debug(sprintf "load %s", Data::Dumper::Dumper($VAR1));
    return $VAR1;
  } else {
    return undef;
  }
}

sub valdiff {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my @keys = @_;
  my $last_values = $self->load_state(%params) || eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = 0;
    }
    $empty_events->{timestamp} = 0;
    $empty_events;
  };
  foreach (@keys) {
    $last_values->{$_} = 0 if ! exists $last_values->{$_};
    if ($self->{$_} >= $last_values->{$_}) {
      $self->{'delta_'.$_} = $self->{$_} - $last_values->{$_};
    } else {
      # vermutlich db restart und zaehler alle auf null
      # und sowas hier gibt's auch noch: beide werte sind 349525.330729167
      # perl ist der meinung, dass $self->{$_} < $last_values->{$_}
      # liegt wohl an rundungsfehlern beim schreiben durch data::dumper etc.
      # heraus kommen dann irrsinnigste werte CRITICAL - CPU busy 582542.22%
      if (sprintf("%s", $self->{$_}) eq sprintf("%s", $last_values->{$_})) {
        $self->{'delta_'.$_} = 0;
      } else {
        $self->{'delta_'.$_} = $self->{$_};
      }
    }
    $self->debug(sprintf "delta_%s %f", $_, $self->{'delta_'.$_});
  }
  $self->{'delta_timestamp'} = time - $last_values->{timestamp};
  $params{save} = eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = $self->{$_};
    }
    $empty_events->{timestamp} = time;
    $empty_events;
  };
  $self->save_state(%params);
}

sub requires_version {
  my $self = shift;
  my $version = shift;
  my @instances = DBD::MSSQL::Server::return_servers();
  my $instversion = $instances[0]->{version};
  if (! $self->version_is_minimum($version)) {
    $self->add_nagios($ERRORS{UNKNOWN}, 
        sprintf "not implemented/possible for MSSQL release %s", $instversion);
  }
}

sub version_is_minimum {
  # the current version is newer or equal
  my $self = shift;
  my $version = shift;
  my $newer = 1;
  my @instances = DBD::MSSQL::Server::return_servers();
  my @v1 = map { $_ eq "x" ? 0 : $_ } split(/\./, $version);
  my @v2 = split(/\./, $instances[0]->{version});
  if (scalar(@v1) > scalar(@v2)) {
    push(@v2, (0) x (scalar(@v1) - scalar(@v2)));
  } elsif (scalar(@v2) > scalar(@v1)) {
    push(@v1, (0) x (scalar(@v2) - scalar(@v1)));
  }
  foreach my $pos (0..$#v1) {
    if ($v2[$pos] > $v1[$pos]) {
      $newer = 1;
      last;
    } elsif ($v2[$pos] < $v1[$pos]) {
      $newer = 0;
      last;
    }
  }
  #printf STDERR "check if %s os minimum %s\n", join(".", @v2), join(".", @v1);
  return $newer;
}

sub instance_rac {
  my $self = shift;
  my @instances = DBD::MSSQL::Server::return_servers();
  return (lc $instances[0]->{parallel} eq "yes") ? 1 : 0;
}

sub instance_thread {
  my $self = shift;
  my @instances = DBD::MSSQL::Server::return_servers();
  return $instances[0]->{thread};
}

sub windows_server {
  my $self = shift;
  my @instances = DBD::MSSQL::Server::return_servers();
  if ($instances[0]->{os} =~ /Win/i) {
    return 1;
  } else {
    return 0;
  }
}

sub system_vartmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $self->system_tmpdir();
  } else {
    return "/var/tmp/check_mssql_health";
  }
}

sub system_oldvartmpdir {
  my $self = shift;
  return "/tmp";
}

sub system_tmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $ENV{TEMP} if defined $ENV{TEMP};
    return $ENV{TMP} if defined $ENV{TMP};
    return File::Spec->catfile($ENV{windir}, 'Temp')
        if defined $ENV{windir};
    return 'C:\Temp';
  } else {
    return "/tmp";
  }
}

sub decode_password {
  my $self = shift;
  my $password = shift;
  if ($password && $password =~ /^rfc3986:\/\/(.*)/) {
    $password = $1;
    $password =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
  }
  return $password;
}


package DBD::MSSQL::Server::Connection;

use strict;

our @ISA = qw(DBD::MSSQL::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    timeout => $params{timeout},
    method => $params{method} || "dbi",
    hostname => $params{hostname},
    username => $params{username},
    password => $params{password},
    verbose => $params{verbose},
    commit => $params{commit},
    port => $params{port} || 1433,
    server => $params{server},
    currentdb => $params{currentdb},
    handle => undef,
  };
  bless $self, $class;
  if ($params{method} eq "dbi") {
    bless $self, "DBD::MSSQL::Server::Connection::Dbi";
  } elsif ($params{method} eq "sqsh") {
    bless $self, "DBD::MSSQL::Server::Connection::Sqsh";
  } elsif ($params{method} eq "sqlrelay") {
    bless $self, "DBD::MSSQL::Server::Connection::Sqlrelay";
  } elsif ($params{method} eq "sqlcmd") {
    bless $self, "DBD::MSSQL::Server::Connection::Sqlcmd";
  }
  $self->init(%params);
  return $self;
}

sub get_instance_names {
  my $self = shift;
  my $object_name = shift;
  my $servicename = DBD::MSSQL::Server::return_first_server()->{servicename};
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $servicename.':'.$1;
  }
  if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
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

sub get_perf_counter {
  my $self = shift;
  my $object_name = shift;
  my $counter_name = shift;
  my $servicename = DBD::MSSQL::Server::return_first_server()->{servicename};
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $servicename.':'.$1;
  }
  if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
    return $self->fetchrow_array(q{
        SELECT
            cntr_value
        FROM
            sys.dm_os_performance_counters
        WHERE
            counter_name = ? AND
            object_name = ?
    }, $counter_name, $object_name);
  } else {
    return $self->fetchrow_array(q{
        SELECT
            cntr_value
        FROM
            master.dbo.sysperfinfo
        WHERE
            counter_name = ? AND
            object_name = ?
    }, $counter_name, $object_name);
  }
}

sub get_perf_counter_instance {
  my $self = shift;
  my $object_name = shift;
  my $counter_name = shift;
  my $instance_name = shift;
  my $servicename = DBD::MSSQL::Server::return_first_server()->{servicename};
  if ($object_name =~ /SQLServer:(.*)/) {
    $object_name = $servicename.':'.$1;
  }
  if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
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

package DBD::MSSQL::Server::Connection::Dbi;

use strict;
use Net::Ping;
use File::Basename;

our @ISA = qw(DBD::MSSQL::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  my $driver = "Sybase:";
  if ($self->{mode} =~ /^server::tnsping/) {
    # erstmal reserviert fuer irgendeinen tcp-connect
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{username} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    if ((! $self->{hostname} && ! $self->{server}) ||
        ! $self->{username} || ! $self->{password}) {
      $self->{errstr} = "Please specify hostname or server, username and password";
      return undef;
    }
    $self->{dbi_options} = { RaiseError => 1, AutoCommit => $self->{commit}, PrintError => 1 };
    if ($params{kerberos}) {
      # Kerberos only supported by the SQL native client
      $driver = "ODBC:driver=SQL Server Native Client 11.0";
    }
    $self->{dsn} = "DBI:$driver";
    if ($self->{hostname}) {
      $self->{dsn} .= sprintf ";host=%s", $self->{hostname};
      $self->{dsn} .= sprintf ";port=%s", $self->{port};
    } else {
      $self->{dsn} .= sprintf ";server=%s", $self->{server};
    }
    if ($params{kerberos}) {
      $self->{dsn} .= ";Trusted_Connection=yes";
    }
    if ($params{currentdb}) {
      if (index($params{currentdb},"-") != -1) {
        $self->{dsn} .= sprintf ";database=\"%s\"", $params{currentdb};
      } else {
        $self->{dsn} .= sprintf ";database=%s", $params{currentdb};
      }
    }
    if (basename($0) =~ /_sybase_/) {
      $self->{dbi_options}->{syb_chained_txn} = 1;
      $self->{dsn} .= sprintf ";tdsLevel=CS_TDS_42";
    }
  }
  if (! exists $self->{errstr}) {
    my $stderrvar;
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      *SAVEERR = *STDERR;
      open OUT ,'>',\$stderrvar;
      *STDERR = *OUT;
      if ($self->{handle} = DBI->connect(
          $self->{dsn},
          $self->{username},
          $self->decode_password($self->{password}),
          $self->{dbi_options})) {
        $retval = $self;
      } else {
        # doesnt seem to work $self->{errstr} = DBI::errstr();
        $self->{errstr} = "connect failed";
        return undef;
      }
      *STDERR = *SAVEERR;
    };
    if ($@) {
      $self->{errstr} = $@;
      $retval = undef;
    } elsif ($stderrvar && $stderrvar =~ /can't change context to database/) {
      $self->{errstr} = $stderrvar;
    } else {
      $self->{errstr} = "";
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  my $stderrvar;
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    if ($self->{dsn} =~ /tdsLevel/) {
      # better install a handler here. otherwise the plugin output is
      # unreadable when errors occur
      $self->{handle}->{syb_err_handler} = sub {
        my($err, $sev, $state, $line, $server,
            $proc, $msg, $sql, $err_type) = @_;
        #push(@errrow, $msg);
        $self->{errstr} = join("\n", (split(/\n/, $self->{errstr}), $msg));
        return 0;
      };
    }
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments) || die DBI::errstr();
    } else {
      $sth->execute() || die DBI::errstr();
    }
    if (lc $sql =~ /^\s*declare.*(exec |sp_)/ ||
        $sql =~ /^\s*declare.*exec sp/im) {
      @row = $sth->syb_output_params();
    } elsif (lc $sql =~ /^\s*(exec |sp_)/ ||
        $sql =~ /^\s*exec sp/im) {
      # flatten the result sets
      do {
        while (my $aref = $sth->fetchrow_arrayref()) {
          push(@row, @{$aref});
        }
      } while ($sth->{syb_more_results});
    } else {
      @row = $sth->fetchrow_array();
    }
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }; 
  *STDERR = *SAVEERR;
  $self->{errstr} = join("\n", (split(/\n/, $self->{errstr}), $stderrvar)) if $stderrvar;
  if ($@) {
    $self->trace(sprintf "bumm %s", $@);
    $self->{errstr} = "timeout during sql statement" if $@ =~ "alarm";
  }
  if ($stderrvar) {
    $self->trace(sprintf "stderr %s", $self->{errstr}) ;
  }
  if (-f "/tmp/check_mssql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_mssql_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  my $stderrvar;
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    if ($sql =~ /^\s*dbcc /im) {
      # dbcc schreibt auf stdout. Die Ausgabe muss daher
      # mit einem eigenen Handler aufgefangen werden.
      $self->{handle}->{syb_err_handler} = sub {
        my($err, $sev, $state, $line, $server,
            $proc, $msg, $sql, $err_type) = @_;
        push(@{$rows}, $msg);
        return 0;
      };
    }
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    if ($sql !~ /^\s*dbcc /im) {
      $rows = $sth->fetchall_arrayref();
    }
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }; 
  *STDERR = *SAVEERR;
  $self->{errstr} = join("\n", (split(/\n/, $self->{errstr}), $stderrvar)) if $stderrvar;
  if ($@) {
    $self->trace(sprintf "bumm %s", $@);
    $self->{errstr} = "timeout during sql statement" if $@ =~ "alarm";
    $rows = [];
  }
  if ($stderrvar) {
    $self->trace(sprintf "stderr %s", $self->{errstr}) ;
  }
  if (-f "/tmp/check_mssql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_mssql_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub exec_sp_1hash {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  eval {
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    do {
      while (my $href = $sth->fetchrow_hashref()) {
        foreach (keys %{$href}) {
          push(@{$rows}, [ $_, $href->{$_} ]);
        }
      }
    } while ($sth->{syb_more_results});
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  return @{$rows};
}


sub execute {
  my $self = shift;
  my $sql = shift;
  my $stderrvar;
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  *STDERR = *SAVEERR;
  $self->{errstr} = join("\n", (split(/\n/, $self->{errstr}), $stderrvar)) if $stderrvar;
  if ($@) {
    $self->trace(sprintf "bumm %s", $@);
  }
  if ($stderrvar) {
    $self->trace(sprintf "stderr %s", $self->{errstr}) ;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace(sprintf "disconnecting DBD %s",
      $self->{handle} ? "with handle" : "without handle");
  $self->{handle}->disconnect() if $self->{handle};
}

package DBD::MSSQL::Server::Connection::Sqlcmd;

use strict;
use File::Temp qw/tempfile/;

our @ISA = qw(DBD::MSSQL::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{loginstring} = "hostport";
  my $template = $self->{mode}.'XXXXX';
  if ($^O =~ /MSWin/) {
    $template =~ s/::/_/g;
  }
  ($self->{sql_commandfile_handle}, $self->{sql_commandfile}) =
      tempfile($template, SUFFIX => ".sql",
      DIR => $self->system_tmpdir() );
  close $self->{sql_commandfile_handle};
  ($self->{sql_resultfile_handle}, $self->{sql_resultfile}) =
      tempfile($template, SUFFIX => ".out",
      DIR => $self->system_tmpdir() );
  close $self->{sql_resultfile_handle};
  ($self->{sql_outfile_handle}, $self->{sql_outfile}) =
      tempfile($template, SUFFIX => ".out",
      DIR => $self->system_tmpdir() );
  close $self->{sql_outfile_handle};

  if ($self->{mode} =~ /^server::tnsping/) {
    die "oracle leftover";
  } else {
    # --server xy --username xy --password xy
    # --hostname xy --username xy --password xy
    # --hostname xy --port --username xy --password xy
    if ($self->{server} && $self->{username} && $self->{password}) {
      # --server bba --user nagios --password oradbmon
      $self->{loginstring} = "server";
    } elsif ($self->{hostname} && $self->{username} && $self->{password}) {
      # --hostname bba --user nagios --password oradbmon
      $self->{loginstring} = "server";
      $self->{server} = sprintf 'tcp:%s,%s', $self->{hostname}, $self->{port};
    } else {
      $self->{errstr} = "Please specify servername, username and password";
      return undef;
    }
  }
  if (! exists $self->{errstr}) {
    #$self->{password} = $self->decode_password($self->{password});
    eval {
      if (! exists $ENV{SQL_HOME}) {
        foreach my $path (split(';', $ENV{PATH})) {
          $self->trace(sprintf "try to find sqlcmd.exe in %s", $path);
          if (-x $path.'/sqlcmd.exe') {
            $ENV{SQL_HOME} = $path;
            last;
          }
        }
        $ENV{SQL_HOME} |= '';
      } else {
        $ENV{PATH} = $ENV{SQL_HOME}.
            (defined $ENV{PATH} ? ";".$ENV{PATH} : "");
      }
      my $sqlcmd = undef;
      if (-x $ENV{SQL_HOME}.'/'.'sqlcmd.exe') {
        $sqlcmd = $ENV{SQL_HOME}.'/'.'sqlcmd.exe';
      }
      if (! $sqlcmd) {
        die "nosqlcmd\n";
      } else {
        $self->trace(sprintf "found %s", $sqlcmd);
      }
      if ($self->{mode} =~ /^server::tnsping/) {
        die "oracle leftover";
      } else {
        if ($self->{loginstring} eq "server") {
          $self->{sqlcmd} = sprintf '"%s" -S %s -U "%s" -P "%s" %s -i "%s" -o "%s"',
              $sqlcmd, $self->{server}, $self->{username}, $self->{password},
              ($self->{currentdb} ? "-d ".$self->{currentdb} : ""),
              $self->{sql_commandfile}, $self->{sql_resultfile};
          $self->{sqlcmd} .= ' -h-1 -s"|" -W';
        }
      }
  
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout

      my $answer = $self->fetchrow_array(
          q{ SELECT 'schnorch' });
      die unless defined $answer and $answer eq 'schnorch';
      $retval = $self;
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at $0 .*//g;
      chomp $self->{errstr};
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}


sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlcmd}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm \n";
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    @row = map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\|/, (split(/\n/, $output))[0]);
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlcmd}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm %s\n", $exit_output;
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @rows = map { [ 
        map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\|/
    ] } grep { ! /^\(\d+ rows affected\)/ } 
        grep { ! /^\s*$/ }
        grep { ! /^Database name .* ignored, referencing object in/ } split(/\n/, $output);
    $rows = \@rows;
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return @{$rows};
}

sub func {
  my $self = shift;
  my $function = shift;
  $self->{handle}->func(@_);
}

sub convert {
  my $n = shift;
  # mostly used to convert numbers in scientific notation
  if ($n =~ /^\s*\d+\s*$/) {
    return $n;
  } elsif ($n =~ /^\s*([-+]?)(\d*[\.,]*\d*)[eE]{1}([-+]?)(\d+)\s*$/) {
    my ($vor, $num, $sign, $exp) = ($1, $2, $3, $4);
    $n =~ s/E/e/g;
    $n =~ s/,/\./g;
    $num =~ s/,/\./g;
    my $sig = $sign eq '-' ? "." . ($exp - 1 + length $num) : '';
    my $dec = sprintf "%${sig}f", $n;
    $dec =~ s/\.[0]+$//g;
    return $dec;
  } elsif ($n =~ /^\s*([-+]?)(\d+)[\.,]*(\d*)\s*$/) {
    return $1.$2.".".$3;
  } elsif ($n =~ /^\s*(.*?)\s*$/) {
    return $1;
  } else {
    return $n;
  }
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace("try to clean up command and result files");
  unlink $self->{sql_commandfile} if -f $self->{sql_commandfile};
  unlink $self->{sql_resultfile} if -f $self->{sql_resultfile};
}

sub create_commandfile {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $self->{sql_commandfile}";
  printf CMDCMD "%s\n", $sql;
  printf CMDCMD "go\n";
  close CMDCMD;
}

sub decode_password {
  my $self = shift;
  my $password = shift;
  $password = $self->SUPER::decode_password($password);
  # we call '...%s/%s@...' inside backticks where the second %s is the password
  # abc'xcv -> ''abc'\''xcv''
  # abc'`xcv -> ''abc'\''\`xcv''
  if ($password && $password =~ /'/) {
    $password = "'".join("\\'", map { "'".$_."'"; } split("'", $password))."'";
  }
  return $password;
}


package DBD::MSSQL::Server::Connection::Sqsh;

use strict;
use File::Temp qw/tempfile/;

our @ISA = qw(DBD::MSSQL::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{loginstring} = "hostport";
  my $template = $self->{mode}.'XXXXX';
  if ($^O =~ /MSWin/) {
    $template =~ s/::/_/g;
  }
  ($self->{sql_commandfile_handle}, $self->{sql_commandfile}) =
      tempfile($template, SUFFIX => ".sql",
      DIR => $self->system_tmpdir() );
  close $self->{sql_commandfile_handle};
  ($self->{sql_resultfile_handle}, $self->{sql_resultfile}) =
      tempfile($template, SUFFIX => ".out",
      DIR => $self->system_tmpdir() );
  close $self->{sql_resultfile_handle};
  ($self->{sql_outfile_handle}, $self->{sql_outfile}) =
      tempfile($template, SUFFIX => ".out",
      DIR => $self->system_tmpdir() );
  close $self->{sql_outfile_handle};

  if ($self->{mode} =~ /^server::tnsping/) {
    die "oracle leftover";
  } else {
    # --server xy --username xy --password xy
    # --hostname xy --username xy --password xy
    # --hostname xy --port --username xy --password xy
    if ($self->{server} && $self->{username} && $self->{password}) {
      # --server bba --user nagios --password oradbmon
      $self->{loginstring} = "server";
    } elsif ($self->{hostname} && $self->{username} && $self->{password}) {
      # --hostname bba --user nagios --password oradbmon
      $self->{loginstring} = "server";
      $self->{server} = sprintf 'tcp:%s,%s', $self->{hostname}, $self->{port};
    } else {
      $self->{errstr} = "Please specify servername, username and password";
      return undef;
    }
  }
  if (! exists $self->{errstr}) {
    $self->{password} = $self->decode_password($self->{password});
    eval {
      if (! exists $ENV{SQL_HOME}) {
        if ($^O =~ /MSWin/) {
          foreach my $path (split(';', $ENV{PATH})) {
            if (-x $path.'/sqsh.exe') {
              $ENV{SQL_HOME} = $path;
              last;
            }
          }
        } else {
          foreach my $path (split(':', $ENV{PATH})) {
            if (-x $path.'/bin/sqsh') {
              $ENV{SQL_HOME} = $path;
              last;
            }
          }
        }
        $ENV{SQL_HOME} |= '';
      } else {
        if ($^O =~ /MSWin/) {
          $ENV{PATH} = $ENV{SQL_HOME}.
              (defined $ENV{PATH} ? ";".$ENV{PATH} : "");
        } else {
          $ENV{PATH} = $ENV{SQL_HOME}."/bin".
              (defined $ENV{PATH} ? ":".$ENV{PATH} : "");
          $ENV{LD_LIBRARY_PATH} = $ENV{SQL_HOME}."/lib".
              (defined $ENV{LD_LIBRARY_PATH} ? ":".$ENV{LD_LIBRARY_PATH} : "");
        }
      }
      my $sqsh = undef;
      my $tnsping = undef;
      if (-x $ENV{SQL_HOME}.'/'.'bin'.'/'.'sqsh') {
        $sqsh = $ENV{SQL_HOME}.'/'.'bin'.'/'.'sqsh';
      } elsif (-x $ENV{SQL_HOME}.'/'.'sqsh') {
        $sqsh = $ENV{SQL_HOME}.'/'.'sqsh';
      } elsif (-x $ENV{SQL_HOME}.'/'.'sqsh.exe') {
        $sqsh = $ENV{SQL_HOME}.'/'.'sqsh.exe';
      } elsif (-x '/usr/bin/sqsh') {
        $sqsh = '/usr/bin/sqsh';
      }
      if (! $sqsh) {
        die "nosqsh\n";
      }
      if ($self->{mode} =~ /^server::tnsping/) {
        die "oracle leftover";
      } else {
        if ($self->{loginstring} eq "server") {
          $self->{sqsh} = sprintf '"%s" -S %s -U "%s" -P "%s" -i "%s" -o "%s"',
              $sqsh, $self->{server}, $self->{username}, $self->{password},
              $self->{sql_commandfile}, $self->{sql_resultfile};
          $self->{sqsh} .= ' -h -s"|"';
        }
      }
  
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout

      my $answer = $self->fetchrow_array(
          q{ SELECT 'schnorch' });
      die unless defined $answer and $answer eq 'schnorch';
      $retval = $self;
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at $0 .*//g;
      chomp $self->{errstr};
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}


sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqsh}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm \n";
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    @row = map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\|/, (split(/\n/, $output))[0]);
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqsh}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm %s\n", $exit_output;
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @rows = map { [ 
        map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\|/
    ] } grep { ! /^\(\d+ rows affected\)/ } 
        grep { ! /^\s*$/ }
        grep { ! /^Database name .* ignored, referencing object in/ } split(/\n/, $output);
    $rows = \@rows;
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return @{$rows};
}

sub func {
  my $self = shift;
  my $function = shift;
  $self->{handle}->func(@_);
}

sub convert {
  my $n = shift;
  # mostly used to convert numbers in scientific notation
  if ($n =~ /^\s*\d+\s*$/) {
    return $n;
  } elsif ($n =~ /^\s*([-+]?)(\d*[\.,]*\d*)[eE]{1}([-+]?)(\d+)\s*$/) {
    my ($vor, $num, $sign, $exp) = ($1, $2, $3, $4);
    $n =~ s/E/e/g;
    $n =~ s/,/\./g;
    $num =~ s/,/\./g;
    my $sig = $sign eq '-' ? "." . ($exp - 1 + length $num) : '';
    my $dec = sprintf "%${sig}f", $n;
    $dec =~ s/\.[0]+$//g;
    return $dec;
  } elsif ($n =~ /^\s*([-+]?)(\d+)[\.,]*(\d*)\s*$/) {
    return $1.$2.".".$3;
  } elsif ($n =~ /^\s*(.*?)\s*$/) {
    return $1;
  } else {
    return $n;
  }
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace("try to clean up command and result files");
  unlink $self->{sql_commandfile} if -f $self->{sql_commandfile};
  unlink $self->{sql_resultfile} if -f $self->{sql_resultfile};
}

sub create_commandfile {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $self->{sql_commandfile}";
  printf CMDCMD "%s\n", $sql;
  printf CMDCMD "go\n";
  close CMDCMD;
}

sub decode_password {
  my $self = shift;
  my $password = shift;
  $password = $self->SUPER::decode_password($password);
  # we call '...%s/%s@...' inside backticks where the second %s is the password
  # abc'xcv -> ''abc'\''xcv''
  # abc'`xcv -> ''abc'\''\`xcv''
  if ($password && $password =~ /'/) {
    $password = "'".join("\\'", map { "'".$_."'"; } split("'", $password))."'";
  }
  return $password;
}


package DBD::MSSQL::Server::Connection::Sqlrelay;

use strict;
use Net::Ping;

our @ISA = qw(DBD::MSSQL::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
  } else {
    if (! $self->{hostname} || ! $self->{username} || ! $self->{password} || ! $self->{port}) {
      $self->{errstr} = "Please specify database, username and password";
      return undef;
    }
  }
  if (! exists $self->{errstr}) {
    my $stderrvar;
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      *SAVEERR = *STDERR;
      open OUT ,'>',\$stderrvar;
      *STDERR = *OUT;
      if ($self->{handle} = DBI->connect(
          #sprintf("DBI:SQLRelay:host=%s;port=%d;socket=%s", 
          sprintf("DBI:SQLRelay:host=%s;port=%d;",
          $self->{hostname}, $self->{port}),
          $self->{username},
          $self->decode_password($self->{password}),
          { RaiseError => 1, AutoCommit => $self->{commit}, PrintError => 1 })) {
        $retval = $self;
      } else {
        $self->{errstr} = DBI::errstr();
      }
      my $answer = $self->fetchrow_array(
          q{ SELECT 42 });
      die $self->{errstr} unless defined $answer and $answer == 42;
      *STDERR = *SAVEERR;
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at [\w\/\.]+ line \d+.*//g;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  my $new_dbh = $self->{handle}->clone();
  $self->trace(sprintf "fetchrow_array: %s", $sql);
  #
  # does not work with bind variables
  #
  while ($sql =~ /\?/) {
    my $param = shift @arguments;
    if ($param !~ /^\d+$/) {
      $param = $self->{handle}->quote($param);
    }
    $sql =~ s/\?/$param/;
  }
  $sql =~ s/^\s*//g;
  $sql =~ s/\s*$//g;
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
    $sth->finish();
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  # without this trick, there are error messages like
  # "No server-side cursors were available to process the query"
  # and the results are messed up.
  $self->{handle}->disconnect();
  $self->{handle} = $new_dbh;
  if (-f "/tmp/check_mssql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_mssql_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  my $new_dbh = $self->{handle}->clone();
  $self->trace(sprintf "fetchall_array: %s", $sql);
  while ($sql =~ /\?/) {
    my $param = shift @arguments;
    if ($param !~ /^\d+$/) {
      $param = $self->{handle}->quote($param);
    }
    $sql =~ s/\?/$param/;
  }
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
    my $asrows = $sth->fetchall_arrayref();
    $sth->finish();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  $self->{handle}->disconnect();
  $self->{handle} = $new_dbh;
  if (-f "/tmp/check_mssql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_mssql_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  #$self->trace(sprintf "disconnecting DBD %s",
  #    $self->{handle} ? "with handle" : "without handle");
  #$self->{handle}->disconnect() if $self->{handle};
}

1;



