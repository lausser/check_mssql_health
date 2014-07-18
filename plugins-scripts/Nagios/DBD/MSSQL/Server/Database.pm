package DBD::MSSQL::Server::Database;

use strict;

our @ISA = qw(DBD::MSSQL::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @databases = ();
  my $initerrors = undef;

  sub add_database {
    push(@databases, shift);
  }

  sub return_databases {
    return reverse
        sort { $a->{name} cmp $b->{name} } @databases;
  }

  sub init_databases {
    my %params = @_;
    my $num_databases = 0;
    my $cache_db_sizes = {};
    if (($params{mode} =~ /server::database::listdatabases/) ||
        ($params{mode} =~ /server::database::databasefree/) ||
        ($params{mode} =~ /server::database::lastbackup/) ||
        ($params{mode} =~ /server::database::transactions/) ||
        ($params{mode} =~ /server::database::datafile/)) {
      my @databaseresult = ();
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          @databaseresult = $params{handle}->fetchall_array(q{
            SELECT name, database_id, state FROM master.sys.databases
          });
        } else {
          @databaseresult = $params{handle}->fetchall_array(q{
            SELECT name, dbid, status FROM master.dbo.sysdatabases
          });
        }
      } elsif ($params{product} eq "ASE") {
        # erst ab 15.x
        my @sysusageresult = $params{handle}->fetchall_array(q{
            SELECT
              db_name(d.dbid) AS db_name,
              SUM(
                CASE WHEN u.segmap != 4 
                     THEN u.size/1048576.*@@maxpagesize 
                END)
              AS data_size,
              SUM(
                CASE WHEN u.segmap != 4 
                     THEN size - curunreservedpgs(u.dbid, u.lstart, u.unreservedpgs)
                END)/1048576.*@@maxpagesize
              AS data_used,
              SUM(
                CASE WHEN u.segmap = 4 
                     THEN u.size/1048576.*@@maxpagesize
                END)
              AS log_size,
              SUM(
                CASE WHEN u.segmap = 4
                     THEN u.size/1048576.*@@maxpagesize
                END) - lct_admin("logsegment_freepages",d.dbid)/1048576.*@@maxpagesize
              AS log_used
              FROM master..sysdatabases d, master..sysusages u
              WHERE u.dbid = d.dbid AND d.status != 256
              GROUP BY d.dbid
              ORDER BY db_name(d.dbid)
        });
        foreach (@sysusageresult) {
          my($db_name, $data_size, $data_used, $log_size, $log_used) = @{$_};
          $log_size = 0 if ! defined $log_size;
          $log_used = 0 if ! defined $log_used;
          $cache_db_sizes->{$db_name} = {
              'db_name' => $db_name, 
              'data_size' => $data_size,
              'data_used' => $data_used,
              'log_size' => $log_size,
              'log_used' => $log_used,
          };
          $cache_db_sizes->{$db_name}->{data_used_pct} = 100 *
              $cache_db_sizes->{$db_name}->{data_used} /
              $cache_db_sizes->{$db_name}->{data_size};
          $cache_db_sizes->{$db_name}->{log_used_pct} = 
              $cache_db_sizes->{$db_name}->{log_size} ?
              100 *
              $cache_db_sizes->{$db_name}->{log_used} /
              $cache_db_sizes->{$db_name}->{log_size}
              : 0;
          $cache_db_sizes->{$db_name}->{data_free} =
              $cache_db_sizes->{$db_name}->{data_size} - 
              $cache_db_sizes->{$db_name}->{data_used};
          $cache_db_sizes->{$db_name}->{log_free} =
              $cache_db_sizes->{$db_name}->{log_size} - 
              $cache_db_sizes->{$db_name}->{log_used};
        }
        @databaseresult = $params{handle}->fetchall_array(q{
          SELECT name, dbid, status2 FROM master.dbo.sysdatabases
        });
      }
      if ($params{mode} =~ /server::database::transactions/) {
        push(@databaseresult, [ '_Total', 0 ]);
      }
      foreach (sort {$a->[0] cmp $b->[0]} @databaseresult) {
        my ($name, $id, $state) = @{$_};
        next if $params{notemp} && $name eq "tempdb";
        next if $params{database} && $name ne $params{database};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{id} = $id;
        $thisparams{state} = $state;
        $thisparams{cache_db_sizes} = $cache_db_sizes;
        my $database = DBD::MSSQL::Server::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      }
      if (! $num_databases) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::database::online/) {
      my @databaseresult = ();
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          @databaseresult = $params{handle}->fetchall_array(q{
            SELECT name, state, state_desc, collation_name FROM master.sys.databases
          });
        }
      }
      foreach (@databaseresult) {
        my ($name, $state, $state_desc, $collation_name) = @{$_};
        next if $params{notemp} && $name eq "tempdb";
        next if $params{database} && $name ne $params{database};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{state} = $state;
        $thisparams{state_desc} = $state_desc;
        $thisparams{collation_name} = $collation_name;
        my $database = DBD::MSSQL::Server::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      }
      if (! $num_databases) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::database::auto(growths|shrinks)/) {
      my @databasenames = ();
      my @databaseresult = ();
      my $lookback = $params{lookback} || 30;
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          @databasenames = $params{handle}->fetchall_array(q{
            SELECT name FROM master.sys.databases
          });
          @databasenames = map { $_->[0] } @databasenames;
            # starttime = Oct 22 2012 01:51:41:373AM = DBD::Sybase datetype LONG
          my $sql = q{
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
          if ($params{mode} =~ /server::database::autogrowths::file/) {
            $sql =~ s/EVENTNAME/'Data File Auto Grow', 'Log File Auto Grow'/;
          } elsif ($params{mode} =~ /server::database::autogrowths::logfile/) {
            $sql =~ s/EVENTNAME/'Log File Auto Grow'/;
          } elsif ($params{mode} =~ /server::database::autogrowths::datafile/) {
            $sql =~ s/EVENTNAME/'Data File Auto Grow'/;
          }
          if ($params{mode} =~ /server::database::autoshrinks::file/) {
            $sql =~ s/EVENTNAME/'Data File Auto Shrink', 'Log File Auto Shrink'/;
          } elsif ($params{mode} =~ /server::database::autoshrinks::logfile/) {
            $sql =~ s/EVENTNAME/'Log File Auto Shrink'/;
          } elsif ($params{mode} =~ /server::database::autoshrinks::datafile/) {
            $sql =~ s/EVENTNAME/'Data File Auto Shrink'/;
          }
          @databaseresult = $params{handle}->fetchall_array($sql, $lookback);
        }
      }
      foreach my $name (@databasenames) {
        next if $params{notemp} && $name eq "tempdb";
        next if $params{database} && $name ne $params{database};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my $autogrowshrink = eval {
            map { $_->[1] } grep { $_->[0] eq $name } @databaseresult;
        } || 0;
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{growshrinkinterval} = $lookback;
        $thisparams{autogrowshrink} = $autogrowshrink;
        my $database = DBD::MSSQL::Server::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      }
      if (! $num_databases) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::database::dbccshrinks/) {
      my @databasenames = ();
      my @databaseresult = ();
      my $lookback = $params{lookback} || 30;
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          @databasenames = $params{handle}->fetchall_array(q{
            SELECT name FROM master.sys.databases
          });
          @databasenames = map { $_->[0] } @databasenames;
            # starttime = Oct 22 2012 01:51:41:373AM = DBD::Sybase datetype LONG
          my $sql = q{
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
          @databaseresult = $params{handle}->fetchall_array($sql, $lookback);
        }
      }
      foreach my $name (@databasenames) {
        next if $params{notemp} && $name eq "tempdb";
        next if $params{database} && $name ne $params{database};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my $autogrowshrink = eval {
            map { $_->[1] } grep { $_->[0] eq $name } @databaseresult;
        } || 0;
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{growshrinkinterval} = $lookback;
        $thisparams{autogrowshrink} = $autogrowshrink;
        my $database = DBD::MSSQL::Server::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      }
      if (! $num_databases) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::database::.*backupage/) {
      my @databaseresult = ();
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          if ($params{mode} =~ /server::database::backupage/) {
            @databaseresult = $params{handle}->fetchall_array(q{
              SELECT D.name AS [database_name], D.recovery_model, BS1.last_backup, BS1.last_duration
              FROM sys.databases D
              LEFT JOIN (
                SELECT BS.[database_name],
                DATEDIFF(HH,MAX(BS.[backup_finish_date]),GETDATE()) AS last_backup,
                DATEDIFF(MI,MAX(BS.[backup_start_date]),MAX(BS.[backup_finish_date])) AS last_duration
                FROM msdb.dbo.backupset BS
                WHERE BS.type IN ('D', 'I')
                GROUP BY BS.[database_name]
              ) BS1 ON D.name = BS1.[database_name]
              ORDER BY D.[name];
            });
          } elsif ($params{mode} =~ /server::database::logbackupage/) {
            @databaseresult = $params{handle}->fetchall_array(q{
              SELECT D.name AS [database_name], D.recovery_model, BS1.last_backup, BS1.last_duration
              FROM sys.databases D
              LEFT JOIN (
                SELECT BS.[database_name],
                DATEDIFF(HH,MAX(BS.[backup_finish_date]),GETDATE()) AS last_backup,
                DATEDIFF(MI,MAX(BS.[backup_start_date]),MAX(BS.[backup_finish_date])) AS last_duration
                FROM msdb.dbo.backupset BS
                WHERE BS.type = 'L'
                GROUP BY BS.[database_name]
              ) BS1 ON D.name = BS1.[database_name]
              ORDER BY D.[name];
            });
          }
        } else {
          @databaseresult = $params{handle}->fetchall_array(q{
            SELECT
              a.name, a.recovery_model,
              DATEDIFF(HH, MAX(b.backup_finish_date), GETDATE()),
              DATEDIFF(MI, MAX(b.backup_start_date), MAX(b.backup_finish_date))
            FROM master.dbo.sysdatabases a LEFT OUTER JOIN msdb.dbo.backupset b
            ON b.database_name = a.name
            GROUP BY a.name 
            ORDER BY a.name 
          }); 
        }
        foreach (sort {
          if (! defined $b->[1]) {
            return 1;
          } elsif (! defined $a->[1]) {
            return -1;
          } else {
            return $a->[1] <=> $b->[1];
          }
        } @databaseresult) { 
          my ($name, $recovery_model, $age, $duration) = @{$_};
          next if $params{notemp} && $name eq "tempdb";
          next if $params{database} && $name ne $params{database};
          if ($params{regexp}) { 
            next if $params{selectname} && $name !~ /$params{selectname}/;
          } else {
            next if $params{selectname} && lc $params{selectname} ne lc $name;
          }
          my %thisparams = %params;
          $thisparams{name} = $name;
          $thisparams{backup_age} = $age;
          $thisparams{backup_duration} = $duration;
          $thisparams{recovery_model} = $recovery_model;
          my $database = DBD::MSSQL::Server::Database->new(
              %thisparams);
          add_database($database);
          $num_databases++;
        }
      } elsif ($params{product} eq "ASE") {
        # sollte eigentlich als database::init implementiert werden, dann wiederum
        # gaebe es allerdings mssql=klassenmethode, ase=objektmethode. also hier.
        @databaseresult = $params{handle}->fetchall_array(q{
          SELECT name, dbid FROM master.dbo.sysdatabases
        });
        foreach (@databaseresult) {
          my ($name, $id) = @{$_};
          next if $params{notemp} && $name eq "tempdb";
          next if $params{database} && $name ne $params{database};
          if ($params{regexp}) {
            next if $params{selectname} && $name !~ /$params{selectname}/;
          } else {
            next if $params{selectname} && lc $params{selectname} ne lc $name;
          }
          my %thisparams = %params;
          $thisparams{name} = $name;
          $thisparams{id} = $id;
          $thisparams{backup_age} = undef;
          $thisparams{backup_duration} = undef;
          my $sql = q{
            dbcc traceon(3604)
            dbcc dbtable("?")
          };
          $sql =~ s/\?/$name/g;
          my @dbccresult = $params{handle}->fetchall_array($sql);
          foreach (@dbccresult) {
            #dbt_backup_start: 0x1686303d8 (dtdays=40599, dttime=7316475)    Feb 27 2011  6:46:28:250AM
            if (/dbt_backup_start: \w+\s+\(dtdays=0, dttime=0\) \(uninitialized\)/) {
              # never backed up
              last;
            } elsif (/dbt_backup_start: \w+\s+\(dtdays=\d+, dttime=\d+\)\s+(\w+)\s+(\d+)\s+(\d+)\s+(\d+):(\d+):(\d+):\d+([AP])/) {
              require Time::Local;
              my %months = ("Jan" => 0, "Feb" => 1, "Mar" => 2, "Apr" => 3, "May" => 4, "Jun" => 5, "Jul" => 6, "Aug" => 7, "Sep" => 8, "Oct" => 9, "Nov" => 10, "Dec" => 11);
              $thisparams{backup_age} = (time - Time::Local::timelocal($6, $5, $4 + ($7 eq "A" ? 0 : 12), $2, $months{$1}, $3 - 1900)) / 3600;
              $thisparams{backup_duration} = 0;
              last;
            }
          }
          # to keep compatibility with mssql. recovery_model=3=simple will be skipped later
          $thisparams{recovery_model} = 0;
          my $database = DBD::MSSQL::Server::Database->new(
              %thisparams);
          add_database($database);
          $num_databases++;
        }
        if (! $num_databases) {
          $initerrors = 1;
          return undef;
        }
      }
    }
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    name => $params{name},
    id => $params{id},
    datafiles => [],
    backup_age => $params{backup_age},
    backup_duration => $params{backup_duration},
    autogrowshrink => $params{autogrowshrink},
    growshrinkinterval => $params{growshrinkinterval},
    state => $params{state},
    state_desc => $params{state_desc} ? lc $params{state_desc} : undef,
    collation_name => $params{collation_name},
    recovery_model => $params{recovery_model},
    offline => 0,
    accessible => 1,
    other_error => 0,
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  # clear errors (offline, missing privileges...) from other databases
  $self->{handle}->{errstr} = "";
  $self->init_nagios();
  $self->set_local_db_thresholds(%params);
  if ($params{mode} =~ /server::database::datafile/) {
    $params{database} = $self->{name};
    DBD::MSSQL::Server::Database::Datafile::init_datafiles(%params);
    if (my @datafiles = 
        DBD::MSSQL::Server::Database::Datafile::return_datafiles()) {
      $self->{datafiles} = \@datafiles;
    } else {
      $self->add_nagios_critical("unable to aquire datafile info");
    }
  } elsif ($params{mode} =~ /server::database::databasefree/) {
    if (DBD::MSSQL::Server::return_first_server()->{product} eq "ASE") {
      # 0x0010 offline
      # 0x0020 offline until recovery completes
      $self->{offline} = $self->{state} & 0x0030;
    } elsif (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
      $self->{offline} = $self->{state} == 6 ? 1 : 0;
    } else {
      # bit 512 is offline
      $self->{offline} = $self->{state} & 0x0200;
    }
    ###################################################################################
    #                            fuer's museum
    # 1> sp_spaceused
    # 2> go
    # database_name   database_size   unallocated space
    # master  4.50 MB 1.32 MB
    # reserved        data    index_size      unused
    # 2744 KB 1056 KB 1064 KB 624 KB
    # (return status = 0)
    #my($database_name, $database_size, $unallocated_space,
    #    $reserved, $data, $index_size, $unused) =
    #     $params{handle}->fetchrow_array(
    #    "USE ".$self->{name}."\nEXEC SP_SPACEUSED"
    #);
    # server mgmt studio           sp_spaceused
    # Currently Allocated Space    database_size       641.94MB
    # Available Free Space         unallocated space   457.09MB 
    #$database_size =~ s/MB//g;
    #$unallocated_space =~ s/MB//g;
    #$self->{size} = $database_size * 1024 * 1024;
    #$self->{free} = $unallocated_space * 1024 * 1024;
    #$self->{percent_free} = $unallocated_space / $database_size * 100;
    #$self->{used} = $self->{size} - $self->{free};
    #$self->{maxsize} = "99999999999999999";
    ###################################################################################

    if (DBD::MSSQL::Server::return_first_server()->{product} eq "ASE") {
      my $cache_db_sizes = $params{cache_db_sizes}->{$self->{name}},
      my $maxpagesize = DBD::MSSQL::Server::return_first_server()->{maxpagesize};
      my $mb = 1024 * 1024;
      my($sp_db_name, $sp_db_size, $sp_db_reserved, $sp_db_data, $sp_db_index, $sp_db_unused) =
           $params{handle}->fetchrow_array(
          "USE ".$self->{name}."\nEXEC sp_spaceused"
      );
      $sp_db_reserved =~ /([\d\.]+)\s*([GMKB]+)/;
      $sp_db_reserved = $1 * ($2 eq "KB" ? 1/1024 : ($2 eq "GB" ? 1024 : 1));
      $sp_db_data =~ /([\d\.]+)\s*([GMKB]+)/;
      $sp_db_data = $1 * ($2 eq "KB" ? 1/1024 : ($2 eq "GB" ? 1024 : 1));
      $sp_db_index =~ /([\d\.]+)\s*([GMKB]+)/;
      $sp_db_index = $1 * ($2 eq "KB" ? 1/1024 : ($2 eq "GB" ? 1024 : 1));
      $sp_db_unused =~ /([\d\.]+)\s*([GMKB]+)/;
      $sp_db_unused = $1 * ($2 eq "KB" ? 1/1024 : ($2 eq "GB" ? 1024 : 1));
      my($sp_log_name, $sp_log_total_pages, $sp_log_free_pages, $sp_log_used_pages, $sp_log_reserved_pages) =
          # returns number of logical pages
          $params{handle}->fetchrow_array(
        "USE ".$self->{name}."\nEXEC sp_spaceused syslogs"
      );
      $sp_log_total_pages = $sp_log_total_pages * $maxpagesize / $mb;  # ! name is _pages, but unit is mb
      $sp_log_free_pages = $sp_log_free_pages * $maxpagesize / $mb;
      $sp_log_used_pages = $sp_log_used_pages * $maxpagesize / $mb;
      $sp_log_reserved_pages = $sp_log_reserved_pages * $maxpagesize / $mb;

      my $unreserved = $cache_db_sizes->{data_size} - $sp_db_reserved;
      my $reserved = $sp_db_reserved;
      my $unreserved_pct = 100 * ($unreserved / $cache_db_sizes->{data_size});
      my $reserved_pct = 100  - $unreserved_pct;

      if ($reserved_pct < 0 || $reserved_pct > 100) {
        # werte aus sp_spaceused
        # sind von der theorie her nicht so exakt, in der praxis aber doch.
        # wenn obige werte seltsam aussehen, dann lieber daten aus sysusages verwenden.
        $unreserved = $cache_db_sizes->{data_free}; # 
        $reserved = $cache_db_sizes->{data_size} - $unreserved;
        $unreserved_pct = 100 * ($unreserved / $cache_db_sizes->{data_size});
        $reserved_pct = 100  - $unreserved_pct;
      }
      if ($cache_db_sizes->{log_size}) {
        # has separate transaction log devices
        my $database_size = $cache_db_sizes->{data_size} + $cache_db_sizes->{log_size};
        my $log_free = $cache_db_sizes->{log_free};
        my $log_used = $cache_db_sizes->{log_used};
        my $log_free_pct = 100 * ($sp_log_free_pages / $sp_log_total_pages);
        my $log_used_pct = 100 - $log_free_pct;
        if ($sp_log_reserved_pages < 0 && ($log_free_pct < 0 || $log_free_pct > 100)) {
          # sp_spaceused data are not good enough, need to run dbcc
          $log_free_pct = 100 * ($log_free / $cache_db_sizes->{log_size});
          $log_used_pct = 100 - $log_free_pct;
        }
        $self->{max_mb} = $cache_db_sizes->{data_size};
        $self->{free_mb} = $cache_db_sizes->{data_free};
        $self->{free_percent} = $unreserved_pct;
        $self->{allocated_percent} = $reserved_pct; # data_size - unreserved - unused
        $self->{free_log_mb} = $sp_log_free_pages;
        $self->{free_log_percent} = $log_free_pct;
        #printf "%14s %.2f%% %.2f%%  %.2f%%  %.2f%%\n", 
        #    $self->{name}, $unreserved_pct, $reserved_pct, $log_free_pct, $log_used_pct;
      } else {
        my $database_size = $cache_db_sizes->{data_size};

        my $log_used_pct = 100 * $sp_log_used_pages / $cache_db_sizes->{data_size};
        my $log_free_pct = 100 * $sp_log_free_pages / $cache_db_sizes->{data_size};
        #printf "%14s %.2f%% %.2f%%  %.2f%%  %.2f%%\n", 
        #    $self->{name}, $unreserved_pct, $reserved_pct, $log_free_pct, $log_used_pct;
        $self->{max_mb} = $cache_db_sizes->{data_size};
        $self->{free_mb} = $unreserved;
        $self->{free_percent} = $unreserved_pct;
        $self->{allocated_percent} = $reserved_pct; # data_size - unreserved - unused
        $self->{free_log_mb} = $sp_log_free_pages;
        $self->{free_log_percent} = $log_free_pct;
      }
    } else {
      my $calc = {};
      if ($params{method} eq 'sqlcmd' || $params{method} eq 'sqsh') {
        foreach($self->{handle}->fetchall_array(q{
          if object_id('tempdb..#FreeSpace') is null
            create table #FreeSpace(
              Drive varchar(10),
              MB_Free bigint
            )
          go
          DELETE FROM tempdb..#FreeSpace
          INSERT INTO tempdb..#FreeSpace exec master.dbo.xp_fixeddrives
          go
          SELECT * FROM tempdb..#FreeSpace
        })) {
          $calc->{drive_mb}->{lc $_->[0]} = $_->[1];
        }
      } else {
        $self->{handle}->execute(q{
          if object_id('tempdb..#FreeSpace') is null 
            create table #FreeSpace(  
              Drive varchar(10),  
              MB_Free bigint  
            ) 
        });
        $self->{handle}->execute(q{
          DELETE FROM #FreeSpace
        });
        $self->{handle}->execute(q{
          INSERT INTO #FreeSpace exec master.dbo.xp_fixeddrives
        });
        foreach($self->{handle}->fetchall_array(q{
          SELECT * FROM #FreeSpace
        })) {
          $calc->{drive_mb}->{lc $_->[0]} = $_->[1];
        }
      }
      #$self->{handle}->execute(q{
      #  DROP TABLE #FreeSpace
      #});
      # Page = 8KB
      # sysfiles ist sv2000, noch als kompatibilitaetsview vorhanden
      # dbo.sysfiles kann 2008 durch sys.database_files ersetzt werden?
      # omeiomeiomei in 2005 ist ein sys.sysindexes compatibility view
      #   fuer 2000.dbo.sysindexes
      #   besser ist sys.allocation_units
      if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
        my $sql = q{
            SELECT 
                SUM(CAST(used AS BIGINT)) / 128
            FROM 
                [?].sys.sysindexes
            WHERE
                indid IN (0,1,255)
        };
        #$sql =~ s/\[\?\]/$self->{name}/g;
        $sql =~ s/\?/$self->{name}/g;
        $self->{used_mb} = $self->{handle}->fetchrow_array($sql);
        my $retries = 0;
        while ($retries < 10 && $self->{handle}->{errstr} =~ /was deadlocked .* victim/i) {
          # Sachen gibt's.... DBD::Sybase::st execute failed: Server message number=1205 severity=13 state=56 line=2 server=AUDIINSV0665 text=Transaction (Process ID 173) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.
          sleep 0.1;
          $self->trace(sprintf
              "%s sysindexes query was a deadlock victim. retry",
              $self->{name});
          $self->{used_mb} = $self->{handle}->fetchrow_array($sql);
          $retries++;
        }
      } else {
        my $sql = q{
            SELECT 
                SUM(CAST(used AS BIGINT)) / 128
            FROM 
                [?].dbo.sysindexes
            WHERE
                indid IN (0,1,255)
        };
        #$sql =~ s/\[\?\]/$self->{name}/g;
        $sql =~ s/\?/$self->{name}/g;
        $self->{used_mb} = $self->{handle}->fetchrow_array($sql);
      }
      if (exists $self->{used_mb} && ! defined $self->{used_mb}) {
        # exists = Query ist gelaufen
        # ! defined = hat NULL geliefert (Ja, gibt's. ich habe es gerade
        # mit eigenen Augen gesehen)
        $self->{used_mb} = 0;
        $self->trace(sprintf "%s uses no indices", $self->{name});
        $self->trace(sprintf "also error %s", $self->{handle}->{errstr}) if $self->{handle}->{errstr};

      }
      my @fileresult = ();
      if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
        my $sql = q{
            SELECT
                RTRIM(a.name), RTRIM(a.filename), CAST(a.size AS BIGINT),
                CAST(a.maxsize AS BIGINT), a.growth
            FROM
                [?].sys.sysfiles a
            JOIN
                [?].sys.sysfilegroups b
            ON
                a.groupid = b.groupid
        };
        #$sql =~ s/\[\?\]/$self->{name}/g;
        $sql =~ s/\?/$self->{name}/g;
        @fileresult = $self->{handle}->fetchall_array($sql);
        if ($self->{handle}->{errstr} =~ /offline/i) {
          $self->{allocated_mb} = 0;
          $self->{max_mb} = 1;
          $self->{used_mb} = 0;
        } elsif ($self->{handle}->{errstr} =~ /is not able to access the database/i) {
          $self->{accessible} = 0;
          $self->{allocated_mb} = 0;
          $self->{max_mb} = 1;
          $self->{used_mb} = 0;
        } elsif ($self->{handle}->{errstr}) {
          $self->{allocated_mb} = 0;
          $self->{max_mb} = 1;
          $self->{used_mb} = 0;
          if ($self->{handle}->{errstr} =~ /Message String: ([\w ]+)/) {
            $self->{other_error} = $1;
          } else {
            $self->{other_error} = $self->{handle}->{errstr};
          }
        }
      } else {
        my $sql = q{
            SELECT
                RTRIM(a.name), RTRIM(a.filename), CAST(a.size AS BIGINT),
                CAST(a.maxsize AS BIGINT), a.growth
            FROM
                [?].dbo.sysfiles a
            JOIN
                [?].dbo.sysfilegroups b
            ON
                a.groupid = b.groupid
        };
        #$sql =~ s/\[\?\]/$self->{name}/g;
        $sql =~ s/\?/$self->{name}/g;
        @fileresult = $self->{handle}->fetchall_array($sql);
      }
      foreach(@fileresult) {
        my($name, $filename, $size, $maxsize, $growth) = @{$_};
        my $drive = lc substr($filename, 0, 1);
        $calc->{datafile}->{$name}->{allocsize} = $size / 128;
        if ($growth == 0) {
          $calc->{datafile}->{$name}->{maxsize} = $size / 128;
        } else {
          if ($maxsize == -1) {
            $calc->{datafile}->{$name}->{maxsize} =
                exists $calc->{drive_mb}->{$drive} ?
                    ($calc->{datafile}->{$name}->{allocsize} + 
                     $calc->{drive_mb}->{$drive}) : 4 * 1024;
            # falls die platte nicht gefunden wurde, dann nimm halt 4GB
            if (exists $calc->{drive_mb}->{$drive}) {
              # davon kann ausgegangen werden. wenn die drives nicht zur
              # vefuegung stehen, stimmt sowieso hinten und vorne nichts.
              $calc->{drive_mb}->{$drive} = 0;
              # damit ist der platz dieses laufwerks verbraten und in
              # max_mb eingeflossen. es darf nicht sein, dass der freie platz
              # mehrfach gezaehlt wird, wenn es mehrere datafiles auf diesem
              # laufwerk gibt.
            }
          } else {
            $calc->{datafile}->{$name}->{maxsize} = $maxsize / 128;
          }
        }
        $self->{allocated_mb} += $calc->{datafile}->{$name}->{allocsize};
        $self->{max_mb} += $calc->{datafile}->{$name}->{maxsize};
      }
      $self->{allocated_mb} = $self->{allocated_mb};
      if ($self->{used_mb} > $self->{allocated_mb}) {
        # obige used-berechnung liefert manchmal (wenns knapp hergeht) mehr als
        # den maximal verfuegbaren platz. vermutlich muessen dann
        # zwecks ermittlung des tatsaechlichen platzverbrauchs 
        # irgendwelche dbcc updateusage laufen.
        # egal, wird schon irgendwie stimmen.
        $self->{used_mb} = $self->{allocated_mb};
        $self->{estimated} = 1;
      } else {
        $self->{estimated} = 0;
      }
      $self->{free_mb} = $self->{max_mb} - $self->{used_mb};
      $self->{free_percent} = 100 * $self->{free_mb} / $self->{max_mb};
      $self->{allocated_percent} = 100 * $self->{allocated_mb} / $self->{max_mb};
    }
  } elsif ($params{mode} =~ /^server::database::transactions/) {
    $self->{transactions_s} = $self->{handle}->get_perf_counter_instance(
        'SQLServer:Databases', 'Transactions/sec', $self->{name});
    my $autoclosed = 0;
    if ($self->{name} ne '_Total' &&
        DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
      my $sql = q{
          SELECT is_cleanly_shutdown, CAST(DATABASEPROPERTYEX('?', 'isautoclose') AS VARCHAR)
          FROM master.sys.databases WHERE name = '?'};
      $sql =~ s/\?/$self->{name}/g;
      my @autoclose = $self->{handle}->fetchrow_array($sql);
      if ($autoclose[0] == 1 && $autoclose[1] == 1) {
        $autoclosed = 1;
      }
    }
    if ($autoclosed) {
      $self->{transactions_s} = 0;
      $self->{transactions_per_sec} = 0;
      $self->valdiff(\%params, qw(transactions_s));
    } elsif (! defined $self->{transactions_s}) {
      $self->add_nagios_unknown("unable to aquire counter data");
    } else {
      $self->valdiff(\%params, qw(transactions_s));
      $self->{transactions_per_sec} = $self->{delta_transactions_s} / $self->{delta_timestamp};
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::database::datafile::listdatafiles/) {
      foreach (sort { $a->{logicalfilename} cmp $b->{logicalfilename}; }  @{$self->{datafiles}}) {
	printf "%s\n", $_->{logicalfilename};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::database::online/) {
      if ($self->{state_desc} eq "online") {
        if ($self->{collation_name}) {
          $self->add_nagios_ok(
            sprintf "%s is %s and accepting connections", $self->{name}, $self->{state_desc});
        } else {
          $self->add_nagios_warning(
            sprintf "%s is %s but not accepting connections", $self->{name}, $self->{state_desc});
        }
      } elsif ($self->{state_desc} =~ /^recover/) {
        $self->add_nagios_warning(
            sprintf "%s is %s", $self->{name}, $self->{state_desc});
      } else {
        $self->add_nagios_critical(
            sprintf "%s is %s", $self->{name}, $self->{state_desc});
      }
    } elsif ($params{mode} =~ /^server::database::transactions/) {
      $self->add_nagios(
          $self->check_thresholds($self->{transactions_per_sec}, 10000, 50000),
          sprintf "%s has %.4f transactions / sec",
          $self->{name}, $self->{transactions_per_sec});
      $self->add_perfdata(sprintf "%s_transactions_per_sec=%.4f;%s;%s",
          $self->{name}, $self->{transactions_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::database::databasefree/) {
      # ->percent_free
      # ->free
      #
      # ausgabe
      #   perfdata db_<db>_free_pct
      #   perfdata db_<db>_free        (real_bytes_max - bytes) + bytes_free  (with units)
      #   perfdata db_<db>_alloc_free  bytes_free (with units)
      #
              # umrechnen der thresholds
      # ()/%
      # MB
      # GB
      # KB
      if (($self->{warningrange} && $self->{warningrange} !~ /^\d+[\.\d]*:/) ||
          ($self->{criticalrange} && $self->{criticalrange} !~ /^\d+[\.\d]*:/)) {
        $self->add_nagios_unknown("you want an alert if free space is _above_ a threshold????");
        return;
      }
      if (! $params{units}) {
        $params{units} = "%";
      } else {
        $params{units} = uc $params{units};
      }
      $self->{warning_bytes} = 0;
      $self->{critical_bytes} = 0;
      if ($self->{offline}) {
        # offlineok hat vorrang
        $params{mitigation} = $params{offlineok} ? 0 : defined $params{mitigation} ? $params{mitigation} : 1;
        $self->add_nagios(
            $params{mitigation},
            sprintf("database %s is offline", $self->{name})
        );
      } elsif (! $self->{accessible}) {
        $self->add_nagios(
            defined $params{mitigation} ? $params{mitigation} : 1, 
            sprintf("insufficient privileges to access %s", $self->{name})
        );
      } elsif ($self->{other_error}) {
        $self->add_nagios(
            defined $params{mitigation} ? $params{mitigation} : 1, 
            sprintf("error accessing %s: %s", $self->{name}, $self->{other_error})
        );
      } elsif ($params{units} eq "%") {
        $self->add_nagios(
            $self->check_thresholds($self->{free_percent}, "5:", "2:"),
                sprintf("database %s has %.2f%% free space left",
                $self->{name}, $self->{free_percent},
                ($self->{estimated} ? " (estim.)" : ""))
        );
        $self->add_perfdata(sprintf "\'db_%s_free_pct\'=%.2f%%;%s;%s",
            lc $self->{name},
            $self->{free_percent},
            $self->{warningrange}, $self->{criticalrange});
        $self->add_perfdata(sprintf "\'db_%s_free\'=%.2fMB;%.2f:;%.2f:;0;%.2f",
            lc $self->{name},
            $self->{free_mb},
            (($self->{warn_mb} = $self->{warningrange}) =~ s/://g && $self->{warn_mb} || $self->{warningrange}) * $self->{max_mb} / 100,
            (($self->{crit_mb} = $self->{criticalrange}) =~ s/://g && $self->{crit_mb} || $self->{criticalrange}) * $self->{max_mb} / 100,
            $self->{max_mb});
        $self->add_perfdata(sprintf "\'db_%s_allocated_pct\'=%.2f%%",
            lc $self->{name},
            $self->{allocated_percent});
        if (exists $self->{free_log_percent}) {
          # sybase with extra transaction log device
          $self->add_nagios(
              $self->check_thresholds($self->{free_log_percent}, "5:", "2:"),
                  sprintf("database %s has %.2f%% free log space left",
                  $self->{name}, $self->{free_log_percent},
                  ($self->{estimated} ? " (estim.)" : ""))
          );
          $self->add_perfdata(sprintf "\'db_%s_free_log_pct\'=%.2f%%;%s;%s",
              lc $self->{name},
              $self->{free_log_percent},
              $self->{warningrange}, $self->{criticalrange});
        }
      } else {
        my $factor = 1; # default MB
        if ($params{units} eq "GB") {
          $factor = 1024;
        } elsif ($params{units} eq "MB") {
          $factor = 1;
        } elsif ($params{units} eq "KB") {
          $factor = 1 / 1024;
        }
        $self->{warningrange} ||= "5:";
        $self->{criticalrange} ||= "2:";
        # : entfernen weil gerechnet werden muss
        my $wnum = $self->{warningrange};
        my $cnum = $self->{criticalrange};
        $wnum =~ s/://g;
        $cnum =~ s/://g;
        $wnum *= $factor; # ranges in mb umrechnen
        $cnum *= $factor;
        $self->{percent_warning} = 100 * $wnum / $self->{max_mb};
        $self->{percent_critical} = 100 * $wnum / $self->{max_mb};
        #$self->{warningrange} = ($wnum / $factor).":";
        #$self->{criticalrange} = ($cnum / $factor).":";
        $self->add_nagios(
            $self->check_thresholds($self->{free_mb} / $factor, "5242880:", "1048576:"),
                sprintf("database %s has %.2f%s free space left", $self->{name},
                    $self->{free_mb} / $factor, $params{units})
        );
        $self->add_perfdata(sprintf "\'db_%s_free_pct\'=%.2f%%;%.2f:;%.2f:",
            lc $self->{name},
            $self->{free_percent}, $self->{percent_warning},
            $self->{percent_critical});
        $self->add_perfdata(sprintf "\'db_%s_free\'=%.2f%s;%s;%s;0;%.2f",
            lc $self->{name},
            $self->{free_mb} / $factor, $params{units},
            $self->{warningrange},
            $self->{criticalrange},
            $self->{max_mb} / $factor);
        $self->add_perfdata(sprintf "\'db_%s_allocated_pct\'=%.2f%%",
            lc $self->{name},
            $self->{allocated_percent});
        if (exists $self->{free_log_percent}) {
          # sybase with extra transaction log device
          $self->add_nagios(
              $self->check_thresholds($self->{free_log_mb} / $factor, "5:", "2:"),
                  sprintf("database %s has %.2f%s free log space left",
                  $self->{name}, $self->{free_log_mb} / $factor, $params{units})
          );
          $self->add_perfdata(sprintf "\'db_%s_free_log_pct\'=%.2f%%;%s;%s",
              lc $self->{name},
              $self->{free_log_percent},
              $self->{warningrange}, $self->{criticalrange});
        }
      }
    } elsif ($params{mode} =~ /server::database::auto(growths|shrinks)/) {
      my $type = ""; 
      if ($params{mode} =~ /::datafile/) {
        $type = "data ";
      } elsif ($params{mode} =~ /::logfile/) {
        $type = "log ";
      }
      $self->add_nagios( 
          $self->check_thresholds($self->{autogrowshrink}, 1, 5), 
          sprintf "%s had %d %sfile auto %s events in the last %d minutes", $self->{name},
              $self->{autogrowshrink}, $type, 
              ($params{mode} =~ /server::database::autogrowths/) ? "grow" : "shrink",
              $self->{growshrinkinterval});
    } elsif ($params{mode} =~ /server::database::dbccshrinks/) {
      # nur relevant fuer master
      $self->add_nagios( 
          $self->check_thresholds($self->{autogrowshrink}, 1, 5), 
          sprintf "%s had %d DBCC Shrink events in the last %d minutes", $self->{name}, $self->{autogrowshrink}, $self->{growshrinkinterval});
    } elsif ($params{mode} =~ /server::database::.*backupage/) {
      my $log = "";
      if ($params{mode} =~ /server::database::logbackupage/) {
        $log = "log of ";
      }
      if ($params{mode} =~ /server::database::logbackupage/ &&
          $self->{recovery_model} == 3) {
        $self->add_nagios_ok(sprintf "%s has no logs",
            $self->{name}); 
      } else {
        if (! defined $self->{backup_age}) { 
          $self->add_nagios(defined $params{mitigation} ? $params{mitigation} : 2, sprintf "%s%s was never backed up",
              $log, $self->{name}); 
          $self->{backup_age} = 0;
          $self->{backup_duration} = 0;
          $self->check_thresholds($self->{backup_age}, 48, 72); # init wg perfdata
        } else { 
          $self->add_nagios( 
              $self->check_thresholds($self->{backup_age}, 48, 72), 
              sprintf "%s%s was backed up %dh ago", $log, $self->{name}, $self->{backup_age});
        } 
        $self->add_perfdata(sprintf "'%s_bck_age'=%d;%s;%s", 
            $self->{name}, $self->{backup_age}, 
            $self->{warningrange}, $self->{criticalrange}); 
        $self->add_perfdata(sprintf "'%s_bck_time'=%d", 
            $self->{name}, $self->{backup_duration}); 
      }
    } 
  }
}


1;
