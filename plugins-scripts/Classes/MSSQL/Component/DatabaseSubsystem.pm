package Classes::MSSQL::Component::DatabaseSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub filter_all {
  my $self = shift;
}

# database-free			database::free
# database-data-free		database::datafree
# database-logs-free		database::logfree
# list-databases		database::list
# list-database-filegroups	database::filegroup::list
# list-database-files		database::file::list
# database-files-free		database::file::free
# database-filegroups-free	database::filegroup::free
sub init {
  my $self = shift;
  my $sql = undef;
  my $allfilter = sub {
    my $o = shift;
    $self->filter_name($o->{name}) &&
        ! (($self->opts->notemp && $o->is_temp) || ($self->opts->nooffline && $o->is_offline));
  };
  if ($self->mode =~ /server::database::(createuser|deleteuser|list|free.*|datafree.*|logfree.*|transactions|size)$/ ||
      $self->mode =~ /server::database::(file|filegroup)/) {
    my $columns = ['name', 'id', 'state', 'state_desc', 'mirroring_role_desc'];
    if ($self->version_is_minimum("9.x")) {
      if ($self->get_variable('ishadrenabled')) {
        if ($self->version_is_minimum("12.x")) {
          # is_primary_replica was introduced with 12.0 "Hekaton" (2014)
          $sql = q{
            SELECT
                db.name, db.database_id AS id, db.state, db.state_desc, mr.mirroring_role_desc
            FROM
                master.sys.databases db
            LEFT OUTER JOIN
                master.sys.dm_hadr_database_replica_states AS dbrs
            ON
                db.replica_id = dbrs.replica_id AND db.group_database_id = dbrs.group_database_id
            LEFT OUTER JOIN
                sys.database_mirroring AS mr
            ON
                db.database_id = mr.database_id
            WHERE
                -- ignore database snapshots  AND -- ignore alwayson replicas 
                db.source_database_id IS NULL AND (dbrs.is_primary_replica IS NULL OR dbrs.is_primary_replica = 1)
          };
        } else {
          $sql = q{
            SELECT
                db.name, db.database_id AS id, db.state, db.state_desc, mr.mirroring_role_desc
            FROM
                master.sys.databases db
            LEFT OUTER JOIN
                master.sys.dm_hadr_database_replica_states AS dbrs
            ON
                db.replica_id = dbrs.replica_id AND db.group_database_id = dbrs.group_database_id
            LEFT OUTER JOIN
                sys.database_mirroring AS mr
            ON
                db.database_id = mr.database_id
            WHERE
                -- ignore database snapshots
                db.source_database_id IS NULL
          };
        }
      } else {
        $sql = q{
          SELECT
              db.name, db.database_id AS id, db.state, db.state_desc, mr.mirroring_role_desc
          FROM
              master.sys.databases db
          LEFT OUTER JOIN
              sys.database_mirroring AS mr
          ON
              db.database_id = mr.database_id
          WHERE
              db.source_database_id IS NULL
          ORDER BY
              db.name
        };
      }
    } else {
      $sql = q{
        SELECT
            name, dbid AS id, status, NULL, NULL
        FROM
            master.dbo.sysdatabases
        ORDER BY
            name
      };
    }
    if ($self->mode =~ /server::database::(free|datafree|logfree|size)/ ||
        $self->mode =~ /server::database::(file|filegroup)/) {
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
    my $columns = ['name', 'state', 'state_desc', 'collation_name', 'mirroring_role_desc'];
    if ($self->version_is_minimum("9.x")) {
      if ($self->get_variable('ishadrenabled')) {
        if ($self->version_is_minimum("12.x")) {
          $sql = q{
            SELECT
                db.name, db.state, db.state_desc, db.collation_name,
                mr.mirroring_role_desc
            FROM
                master.sys.databases db
            LEFT OUTER JOIN
                master.sys.dm_hadr_database_replica_states AS dbrs
            ON
                db.replica_id = dbrs.replica_id AND db.group_database_id = dbrs.group_database_id
            LEFT JOIN
                sys.database_mirroring mr
            ON
                db.database_id = mr.database_id
            WHERE
                -- ignore database snapshots  AND -- ignore alwayson replicas
                db.source_database_id IS NULL AND (dbrs.is_primary_replica IS NULL OR dbrs.is_primary_replica = 1)
          };
        } else {
          $sql = q{
            SELECT
                db.name, db.state, db.state_desc, db.collation_name,
                mr.mirroring_role_desc
            FROM
                master.sys.databases db
            LEFT OUTER JOIN
                master.sys.dm_hadr_database_replica_states AS dbrs
            ON
                db.replica_id = dbrs.replica_id AND db.group_database_id = dbrs.group_database_id
            LEFT JOIN
                sys.database_mirroring mr
            ON
                db.database_id = mr.database_id
            WHERE
                -- ignore database snapshots
                db.source_database_id IS NULL
          };
        }
      } else {
        $sql = q{
          SELECT
              db.name, db.state, db.state_desc, db.collation_name,
              mr.mirroring_role_desc
          FROM
              master.sys.databases db
          LEFT JOIN
              sys.database_mirroring mr
          ON
              db.database_id = mr.database_id
          WHERE
              db.source_database_id IS NULL
          ORDER BY
              db.name
        };
      }
    }
    $self->get_db_tables([
        ['databases', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database', $allfilter, $columns],
    ]);
    @{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
  } elsif ($self->mode =~ /server::database::(.*backupage)/) {
    my $columns = ['name', 'recovery_model', 'backup_age', 'backup_duration', 'state', 'state_desc', 'db_age', 'mirroring_role_desc'];
    if ($self->mode =~ /server::database::backupage/) {
      if ($self->version_is_minimum("9.x")) {
        $sql = q{
          SELECT
              d.name AS database_name, d.recovery_model, bs1.last_backup, bs1.last_duration, d.state, d.state_desc,
              DATEDIFF(HH, d.create_date, GETDATE()) AS db_age,
              mr.mirroring_role_desc
          FROM
              sys.databases d
          LEFT JOIN (
            SELECT
                bs.database_name,
                DATEDIFF(HH, MAX(bs.backup_finish_date), GETDATE()) AS last_backup,
                DATEDIFF(MI, MAX(bs.backup_start_date), MAX(bs.backup_finish_date)) AS last_duration
            FROM
                msdb.dbo.backupset bs WITH (NOLOCK)
            WHERE
                bs.type IN ('D', 'I')
            GROUP BY
                bs.database_name
          ) bs1 ON
              d.name = bs1.database_name
          LEFT JOIN
              sys.database_mirroring mr
          ON
              d.database_id = mr.database_id
          WHERE
              -- source_database_id hat nur dann einen Wert, wenn beim
              -- Anlegen einer Datenbank diese aus einem Snapshot einer
              -- anderen Datenbank erzeugt wird.
              d.source_database_id IS NULL
          ORDER BY
              d.name
        };
        if ($self->mode =~ /server::database::(.*backupage::full)/) {
          $sql =~ s/'D', 'I'/'D'/g;
        } elsif ($self->mode =~ /server::database::(.*backupage::differential)/) {
          $sql =~ s/'D', 'I'/'I'/g;
        }
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
              a.state,
              NULL AS state_desc,
              NULL AS create_date,
              "UNIMPLEMENTED" AS mirroring_role_desc
          FROM
              master.dbo.sysdatabases a LEFT OUTER JOIN msdb.dbo.backupset b
          ON
              b.database_name = a.name
          GROUP BY
              a.name
          ORDER BY
              a.name
        };
      }
    } elsif ($self->mode =~ /server::database::logbackupage/) {
      if ($self->version_is_minimum("9.x")) {
        $sql = q{
          SELECT
              d.name AS database_name, d.recovery_model, bs1.last_backup, bs1.last_duration, d.state, d.state_desc,
              DATEDIFF(HH, d.create_date, GETDATE()) AS db_age,
              mr.mirroring_role_desc
          FROM
              sys.databases d
          LEFT JOIN (
            SELECT
                bs.database_name,
                DATEDIFF(HH, MAX(bs.backup_finish_date), GETDATE()) AS last_backup,
                DATEDIFF(MI, MAX(bs.backup_start_date), MAX(bs.backup_finish_date)) AS last_duration
            FROM
                msdb.dbo.backupset bs WITH (NOLOCK)
            WHERE
                bs.type = 'L'
            GROUP BY
                bs.database_name
          ) bs1 ON
              d.name = bs1.database_name
          LEFT JOIN
              sys.database_mirroring mr
          ON
              d.database_id = mr.database_id
          WHERE
              -- source_database_id hat nur dann einen Wert, wenn beim
              -- Anlegen einer Datenbank diese aus einem Snapshot einer
              -- anderen Datenbank erzeugt wird.
              d.source_database_id IS NULL
          ORDER BY
              d.name
        };
      } else {
        $self->no_such_mode();
      }
    }
    $self->get_db_tables([
        ['databases', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub', $allfilter, $columns],
    ]);
    @{$self->{databases}} =  reverse sort {$a->{name} cmp $b->{name}} @{$self->{databases}};
    foreach (@{$self->{databases}}) {
      bless $_, 'Classes::MSSQL::Component::DatabaseSubsystem::Database';
      $_->finish();
    }
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
          -- INNER JOIN
          --    sys.trace_categories AS cat
          -- ON
          --     e.category_id = cat.category_id
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
          -- INNER JOIN
          --     sys.trace_categories AS cat
          -- ON
          --     e.category_id = cat.category_id
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
  if ($self->mode =~ /server::database::deleteuser$/) {
    foreach (@{$self->{databases}}) {
      $_->check();
    }
    $self->execute(q{
      USE MASTER DROP USER
    }.$self->opts->name2);
    $self->execute(q{
      USE MASTER DROP LOGIN
    }.$self->opts->name2);
  } elsif ($self->mode =~ /server::database::createuser$/) {
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
    if ($self->get_variable('ishadrenabled')) {
      $self->execute(q{
        USE MASTER GRANT SELECT ON sys.availability_groups TO
      }.$self->opts->name2);
      $self->execute(q{
        USE MASTER GRANT SELECT ON sys.availability_replicas TO
      }.$self->opts->name2);
      $self->execute(q{
        USE MASTER GRANT SELECT ON sys.dm_hadr_database_replica_cluster_states TO
      }.$self->opts->name2);
      $self->execute(q{
        USE MASTER GRANT SELECT ON sys.dm_hadr_database_replica_states TO
      }.$self->opts->name2);
      $self->execute(q{
        USE MASTER GRANT SELECT ON sys.fn_hadr_backup_is_preferred_replica TO
      }.$self->opts->name2);
    }
    # for instances with secure configuration
    $self->execute(q{
      USE MASTER GRANT SELECT ON sys.filegroups TO
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
printf "CODE %d MESS %s\n", $code, $message;
      if (grep ! /(The server principal.*already exists)|(User.*group.*role.*already exists in the current database)/, split(/\n/, $message)) {
        $self->clear_critical();
        foreach (@{$self->{databases}}) {
          $_->check();
        }
      }
    }
    $self->add_ok("have fun");
  } elsif ($self->mode =~ /server::database::.*list$/) {
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
      { map { uc $_->{drive} => 1024 * 1024 * $_->{mb_free} } @{$self->{filesystems}} };
}

package Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub finish {
  my $self = shift;
  $self->override_opt("units", "%") if ! $self->opts->units;
  $self->{full_name} = $self->{name};
  $self->{state_desc} = lc $self->{state_desc} if $self->{state_desc};
  $self->{mirroring_role_desc} = lc $self->{mirroring_role_desc} if $self->{mirroring_role_desc};
}

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

sub is_restoring_mirror {
  my $self = shift;
  if (exists $self->{mirroring_role_desc} &&
      lc $self->{mirroring_role_desc} eq "mirror") {
    # and state_desc == RESTORING
    # das Gegenstueck hat mirroring_role_desc == PRINCIPAL und
    # state_desc == ONLINE (wenn alles normal ist, ansonsten auch OFFLINE etc)
    # Leider braucht man sa-Privilegien, um mirroring_role_desc auslesen zu
    # koennen, sonst ist die Spalte NULL
    # 1> SELECT name, db.database_id, state_desc, mirroring_role_desc FROM master.sys.databases db LEFT JOIN sys.database_mirroring mr ON db.database_id = mr.database_id
    # 2> go
    # name	database_id	state_desc	mirroring_role_desc
    # master	1	ONLINE	NULL
    # tempdb	2	ONLINE	NULL
    # model	3	ONLINE	NULL
    # msdb	4	ONLINE	NULL
    # SIT_AdminDB	5	ONLINE	NULL
    # SecretServer	6	RESTORING	NULL
    # (6 rows affected)
    # Korrekt waere:
    # SecretServer	6	RESTORING	MIRROR
    return 1;
  } else {
    return 0;
  }
}

sub is_offline {
  my $self = shift;
  return 0 if $self->{messages}->{critical} && grep /is offline/i, @{$self->{messages}->{critical}};
  if ($self->version_is_minimum("9.x")) {
    # https://docs.microsoft.com/de-de/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver15
    return 1 if $self->{state} && $self->{state} == 6;
    return 1 if $self->{state} && $self->{state} == 10;
  } else {
    # bit 512 is offline
    return $self->{state} & 0x0200 ? 1 : 0;
  }
  return 0;
}

sub is_online {
  my $self = shift;
  return 0 if $self->{messages}->{critical} && grep /is offline/i, @{$self->{messages}->{critical}};
  if ($self->version_is_minimum("9.x")) {
    return 1 if $self->{state_desc} && lc $self->{state_desc} eq "online";
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

sub mbize {
  my $self = shift;
  foreach (qw(max_size size used_size rows_max_size rows_size rows_used_size logs_max_size logs_size logs_used_size)) {
    next if ! exists $self->{$_};
    $self->{$_.'_mb'} = $self->{$_} / (1024*1024);
  }
}

package Classes::MSSQL::Component::DatabaseSubsystem::Database;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem Classes::MSSQL::Component::DatabaseSubsystem::DatabaseStub);
use strict;

sub finish {
  my $self = shift;
  $self->SUPER::finish();
  if ($self->mode =~ /server::database::(free.*|datafree.*|logfree.*|size)$/ ||
      $self->mode =~ /server::database::(file|filegroup)/) {
    # private copy for this database
    %{$self->{filesystems}} = %{$Classes::MSSQL::Component::DatabaseSubsystem::filesystems};
    my @filesystems = keys %{$self->{filesystems}};
    $self->{size} = 0;
    $self->{max_size} = 0;
    $self->{used_size} = 0;
    $self->{drive_reserve} = 0;
    my $sql;
    my $columns = ['database_name', 'filegroup_name', 'name', 'is_media_read_only', 'is_read_only',
        'is_sparse', 'size', 'max_size', 'growth', 'is_percent_growth',
        'used_size', 'type', 'state', 'drive', 'path'];
    if ($self->version_is_minimum("9.x")) {
      $sql = q{
        USE
      [}.$self->{name}.q{]
        SELECT
          '}.$self->{name}.q{',
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
        WHERE
          dbf.type_desc != 'FILESTREAM'
      };
    }
    if ($self->is_online) {
      $self->localize_errors();
      $self->get_db_tables([
        ['files', $sql, 'Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafile', undef, $columns],
      ]);
      $self->globalize_errors();
      $self->{filegroups} = [];
      my %seen = ();
      foreach my $group (grep !$seen{$_}++, map { $_->{filegroup_name} } @{$self->{files}}) {
        push (@{$self->{filegroups}},
            Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafilegroup->new(
                name => $group,
                database_name => $self->{name},
                files => [grep { $_->{filegroup_name} eq $group } @{$self->{files}}],
        ));
      #  @{$self->{files}} = grep { $_->{filegroup_name} eq $group } @{$self->{files}};
      }
      delete $self->{files};
      # $filegroup->{drive_reserve} ist mehrstufig, drives jeweils extra
      $self->{drive_reserve} = {};
      map { $self->{drive_reserve}->{$_} = 0; } @filesystems;
      foreach my $filegroup (@{$self->{filegroups}}) {
        next if $filegroup->{type} eq 'LOG'; # alles ausser logs zaehlt als rows
        $self->{'rows_size'} += $filegroup->{size};
        $self->{'rows_used_size'} += $filegroup->{used_size};
        $self->{'rows_max_size'} += $filegroup->{max_size};
        map { $self->{drive_reserve}->{$_} += $filegroup->{drive_reserve}->{$_}} @filesystems;
      }
      # 1x reserve pro drive erlaubt
      map {
        $self->{'rows_max_size'} -= --$self->{drive_reserve}->{$_} * $self->{filesystems}->{$_};
        $self->{drive_reserve}->{$_} = 1;
      } grep {
        $self->{drive_reserve}->{$_};
      } @filesystems;
      # fuer modus database-free wird freier drive-platz sowohl den rows als auch den logs zugeschlagen
      map { $self->{drive_reserve}->{$_} = 0; } @filesystems;
      foreach my $filegroup (@{$self->{filegroups}}) {
        next if $filegroup->{type} ne 'LOG';
        $self->{'logs_size'} += $filegroup->{size};
        $self->{'logs_used_size'} += $filegroup->{used_size};
        $self->{'logs_max_size'} += $filegroup->{max_size};
        map { $self->{drive_reserve}->{$_} += $filegroup->{drive_reserve}->{$_}} @filesystems;
      }
      map {
        $self->{'logs_max_size'} -= --$self->{drive_reserve}->{$_} * $self->{filesystems}->{$_};
        $self->{drive_reserve}->{$_} = 1;
      } grep {
        exists $self->{'logs_max_size'} && $self->{drive_reserve}->{$_};
      } @filesystems;
    }
    $self->mbize();
  } elsif ($self->mode =~ /server::database::(.*backupage(::(full|differential))*)$/) {
    if ($self->version_is_minimum("11.x")) {
      if ($self->get_variable('ishadrenabled')) {
        my @replicated_databases = $self->fetchall_array_cached(q{
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
          # -> every node had to be backupped, the db is local on every node
          $self->{preferred_replica} = 1;
        }
      } else {
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
  if ($self->mode =~ /server::database::list$/) {
    printf "%s\n", $self->{name};
  } elsif ($self->mode =~ /server::database::deleteuser$/) {
    $self->execute(q{
      USE
    }.$self->{name}.q{
      DROP USER
    }.$self->opts->name2);
    $self->execute(q{
      USE
    }.$self->{name}.q{
      DROP ROLE CHECKMSSQLHEALTH
    });
  } elsif ($self->mode =~ /server::database::createuser$/) {
    $self->execute(q{
      USE
    }.$self->{name}.q{
      CREATE USER
    }.$self->opts->name2.q{
      FOR LOGIN
    }.$self->opts->name2) if $self->{name} ne "msdb";
    $self->execute(q{
      USE
    }.$self->{name}.q{
      CREATE ROLE CHECKMSSQLHEALTH
    });
    $self->execute(q{
      USE
    }.$self->{name}.q{
      EXEC sp_addrolemember CHECKMSSQLHEALTH,
    }.$self->opts->name2);
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
    if (my ($code, $message) = $self->check_messages(join_all => "\n")) {
      if (! grep ! /User.*group.*role.*already exists in the current database/, split(/\n/, $message)) {
        $self->clear_critical();
      }
      if (! grep ! /availability_groups.*because it does not exist/, split(/\n/, $message)) {
        $self->clear_critical();
      }
    }
  } elsif ($self->mode =~ /server::database::(filegroup|file)/) {
    foreach (@{$self->{filegroups}}) {
      if ($self->filter_name2($_->{name})) {
        $_->check();
      }
    }
  } elsif ($self->mode =~ /server::database::(free|datafree|logfree)/) {
    my @filetypes = qw(rows logs);
    if ($self->mode =~ /server::database::datafree/) {
      @filetypes = qw(rows);
    } elsif ($self->mode =~ /server::database::logfree/) {
      @filetypes = qw(logs);
    }
    if (! $self->is_online and $self->is_restoring_mirror) {
      $self->add_ok(sprintf "database %s is a restoring mirror", $self->{name});
    } elsif (! $self->is_online) {
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
      foreach (@{$self->{filegroups}}) {
        $_->check();
      }
      $self->clear_ok();
      foreach my $type (@filetypes) {
        next if ! exists $self->{$type."_size"}; # not every db has a separate log
        my $metric_pct = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_free_pct' : 'db_'.lc $self->{name}.'_log_free_pct';
        my $metric_units = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_free' : 'db_'.lc $self->{name}.'_log_free';
        my $metric_allocated = ($type eq "rows") ?
            'db_'.lc $self->{name}.'_allocated_pct' : 'db_'.lc $self->{name}.'_log_allocated_pct';
        my ($free_percent, $free_size, $free_units, $allocated_percent, $factor) = $self->calc(
            'database', $self->{full_name}, $type,
            $self->{$type."_used_size"}, $self->{$type."_size"}, $self->{$type."_max_size"},
            $metric_pct, $metric_units, $metric_allocated
        );
        $self->add_perfdata(
            label => $metric_pct,
            value => $free_percent,
            places => 2,
            uom => '%',
        );
        $self->add_perfdata(
            label => $metric_units,
            value => $free_units,
            uom => $self->opts->units eq "%" ? "MB" : $self->opts->units,
            places => 2,
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
    if ($self->mode =~ /server::database::logfree/ && ! exists $self->{logs_size}) {
      $self->add_ok(sprintf "database %s has no logs", $self->{name});
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
    } elsif ($self->is_restoring_mirror) {
      $self->add_ok(sprintf "database %s is a restoring mirror", $self->{name});
    } elsif ($self->{state_desc} =~ /^recover/i) {
      $self->add_warning(sprintf "%s is %s", $self->{name}, $self->{state_desc});
    } elsif ($self->{state_desc} =~ /^restor/i) {
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
        $self->{name}, $self->{rows_size} / $factor,
        $self->opts->units);
    $self->add_perfdata(
        label => 'db_'.$self->{name}.'_alloc_size',
        value => $self->{rows_size} / $factor,
        uom => $self->opts->units,
        max => $self->{rows_max_size} / $factor,
    );
    if ($self->{logs_size}) {
      $self->add_ok(sprintf "db %s logs allocated %.4f%s",
          $self->{name}, $self->{logs_size} / $factor,
          $self->opts->units);
      $self->add_perfdata(
          label => 'db_'.$self->{name}.'_alloc_logs_size',
          value => $self->{logs_size} / $factor,
          uom => $self->opts->units,
          max => $self->{logs_max_size} / $factor,
      );
    }
  } elsif ($self->mode =~ /server::database::(.*backupage(::(full|differential))*)$/) {
    if (! $self->is_backup_node && ! $self->opts->get("check-all-replicas")) {
      $self->add_ok(sprintf "this is not the preferred replica for backups of %s", $self->{name});
      return;
    }
    if (! $self->is_online and $self->is_restoring_mirror) {
      $self->add_ok(sprintf "database %s is a restoring mirror", $self->{name});
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
      # database_name, d.recovery_model, last_backup, last_duration, state, state_desc
      # vor 3 Stunden gesichert:
      # [ 'hloda_nobackup', 1, 3, 0, 0, 'ONLINE', 4 ],
      # nagelneu
      # [ 'hlodaBACKUP', 1, undef, undef, 0, 'ONLINE', 0 ],
      if (! defined $self->{backup_age}) {
        # kein Backup bislang
        if (defined $self->opts->mitigation()) {
          # moeglicherweise macht das nichts
          if ($self->opts->mitigation() =~ /(\w+)=(\d+)/ and
            defined $self->{db_age} and $2 >= $self->{db_age}) {
          # der grund fuer das fehlende backup kann sein, dass die db nagelneu ist.
            $self->add_ok(sprintf "db %s was created just %d hours ago", $self->{name}, $self->{db_age});
          } elsif ($self->opts->mitigation() =~ /(\w+)=(\d+)/ and
            defined $self->{db_age} and $2 < $self->{db_age}) {
            # die erstellung der db ist schon laenger als der mitigation-zeitraum her
            $self->add_critical(sprintf "%s%s was never backed up", $log, $self->{name});
          } else {
            $self->add_critical_mitigation(sprintf "%s%s was never backed up", $log, $self->{name});
          }
        } else {
          $self->add_critical(sprintf "%s%s was never backed up", $log, $self->{name});
        }
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

sub calc {
  my ($self, $item, $name, $type, $used_size, $size, $max_size,
      $metric_pct, $metric_units, $metric_allocated) = @_;
  #item = database,filegroup,file
  #type log, rows oder nix
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
  my $free_percent = 100 - 100 * $used_size / $max_size;
  my $allocated_percent = 100 * $size / $max_size;
  my $free_size = $max_size - $used_size;
  my $free_units = $free_size / $factor;
  if ($self->opts->units eq "%") {
    $self->set_thresholds(metric => $metric_pct, warning => "10:", critical => "5:");
    ($warning_pct, $critical_pct) = ($self->get_thresholds(metric => $metric_pct));
    ($warning_units, $critical_units) = map {
        # sonst schnippelt der von den originalen den : weg
        $_ =~ s/://g; (($_ * $max_size / 100) / $factor).":";
    } map { my $tmp = $_; $tmp; } ($warning_pct, $critical_pct);
    $self->force_thresholds(metric => $metric_units, warning => $warning_units, critical => $critical_units);
    if ($self->filter_name2($name)) {
      $self->add_message($self->check_thresholds(metric => $metric_pct, value => $free_percent),
          sprintf("%s %s has %.2f%s free %sspace left", $item, $name, $free_percent, $self->opts->units, ($type eq "logs" ? "log " : "")));
    } else {
      $self->add_ok(
          sprintf("%s %s has %.2f%s free %sspace left", $item, $name, $free_percent, $self->opts->units, ($type eq "logs" ? "log " : "")));
    }
  } else {
    $self->set_thresholds(metric => $metric_units, warning => "5:", critical => "10:");
    ($warning_units, $critical_units) = ($self->get_thresholds(metric => $metric_units));
    ($warning_pct, $critical_pct) = map {
        $_ =~ s/://g; (100 * ($_ * $factor) / $max_size).":";
    } map { my $tmp = $_; $tmp; } ($warning_units, $critical_units);
    $self->force_thresholds(metric => $metric_pct, warning => $warning_pct, critical => $critical_pct);
    if ($self->filter_name2($name)) {
      $self->add_message($self->check_thresholds(metric => $metric_units, value => $free_units),
          sprintf("%s %s has %.2f%s free %sspace left", $item, $name, $free_units, $self->opts->units, ($type eq "logs" ? "log " : "")));
    } else {
      $self->add_ok(
          sprintf("%s %s has %.2f%s free %sspace left", $item, $name, $free_units, $self->opts->units, ($type eq "logs" ? "log " : "")));
    }
  }
  return ($free_percent, $free_size, $free_units, $allocated_percent, $factor);
}

package Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafilegroup;
our @ISA = qw(Classes::MSSQL::Component::DatabaseSubsystem::Database);
use strict;

sub finish {
  my ($self, %params) = @_;
  %{$self->{filesystems}} = %{$Classes::MSSQL::Component::DatabaseSubsystem::filesystems};
  my @filesystems = keys %{$self->{filesystems}};
  $self->{full_name} = sprintf "%s::%s",
      $self->{database_name}, $self->{name};
  $self->{size} = 0;
  $self->{max_size} = 0;
  $self->{used_size} = 0;
  $self->{drive_reserve} = {};
  map { $self->{drive_reserve}->{$_} = 0; } keys %{$self->{filesystems}};
  # file1 E reserve 0          += max_size
  # file2 E reserve 100        += max_size    += drive_reserve (von E)   filesystems->E fliegt raus
  # file3 E reserve 100        += max_size    -= max_size, reserve(E) abziehen
  # file4 F reserve 0	       += max_size
  # file5 G reserve 1000       += max_size    += drive_reserve (von G)   filesystems->G fliegt raus
  foreach my $datafile (@{$self->{files}}) {
    $self->{size} += $datafile->{size};
    $self->{used_size} += $datafile->{used_size};
    $self->{max_size} += $datafile->{max_size};
    $self->{type} = $datafile->{type};
    if ($datafile->{drive_reserve}->{$datafile->{drive}}) {
      $self->{drive_reserve}->{$datafile->{drive}}++;
    }
  }
  my $ddsub = join " ", map { my $x = sprintf "%d*%s", $self->{drive_reserve}->{$_} - 1, $_; $x; } grep { $self->{drive_reserve}->{$_} > 1 } grep { $self->{drive_reserve}->{$_} } keys %{$self->{drive_reserve}};
  $self->{formula} = sprintf "g %15s msums %d (%dMB) %s", $self->{name}, $self->{max_size}, $self->{max_size} / 1048576, $ddsub ? " - (".$ddsub.")" : "";
  map {
    $self->{max_size} -= --$self->{drive_reserve}->{$_} * $self->{filesystems}->{$_};
    $self->{drive_reserve}->{$_} = 1;
  } grep {
    $self->{drive_reserve}->{$_};
  } @filesystems;
  $self->mbize();
}

sub check {
  my ($self) = @_;
  if ($self->mode =~ /server::database::datafree/ && $self->{type} eq "LOG") {
    return;
  } elsif ($self->mode =~ /server::database::logfree/ && $self->{type} ne "LOG") {
    return;
  }
  if ($self->mode =~ /server::database::filegroup::list$/) {
    printf "%s %s %d\n", $self->{database_name}, $self->{name}, scalar(@{$self->{files}});
  } elsif ($self->mode =~ /server::database::file::list/) {
    foreach (@{$self->{files}}) {
      $_->{database_name} = $self->{database_name};
      if ($self->filter_name2($_->{path})) {
        $_->check();
      }
    }
  } elsif ($self->mode =~ /server::database::(free|datafree|logfree)$/) {
    my $metric_pct = 'grp_'.lc $self->{full_name}.'_free_pct';
    my $metric_units = 'grp_'.lc $self->{full_name}.'_free';
    my $metric_allocated = 'grp_'.lc $self->{full_name}.'_allocated_pct';
    my ($free_percent, $free_size, $free_units, $allocated_percent, $factor) = $self->calc(
        "filegroup", $self->{full_name}, "",
        $self->{used_size}, $self->{size}, $self->{max_size},
        $metric_pct, $metric_units, $metric_allocated
    );
  } elsif ($self->mode =~ /server::database::filegroup::free$/ ||
      $self->mode =~ /server::database::(free|datafree|logfree)::details/) {
    my $metric_pct = 'grp_'.lc $self->{full_name}.'_free_pct';
    my $metric_units = 'grp_'.lc $self->{full_name}.'_free';
    my $metric_allocated = 'grp_'.lc $self->{full_name}.'_allocated_pct';
    my ($free_percent, $free_size, $free_units, $allocated_percent, $factor) = $self->calc(
        "filegroup", $self->{full_name}, "",
        $self->{used_size}, $self->{size}, $self->{max_size},
        $metric_pct, $metric_units, $metric_allocated
    );
    $self->add_perfdata(
        label => $metric_pct,
        value => $free_percent,
        places => 2,
        uom => '%',
    );
    $self->add_perfdata(
        label => $metric_units,
        value => $free_units,
        uom => $self->opts->units eq "%" ? "MB" : $self->opts->units,
        places => 2,
        min => 0,
        max => $self->{max_size} / $factor,
    );
    $self->add_perfdata(
        label => $metric_allocated,
        value => $allocated_percent,
        places => 2,
        uom => '%',
    );
  } elsif ($self->mode =~ /server::database::file::free$/) {
    foreach (@{$self->{files}}) {
      if ($self->filter_name3($_->{name})) {
        $_->check();
      }
    }
  }
}

package Classes::MSSQL::Component::DatabaseSubsystem::Database::Datafile;
our @ISA = qw(Classes::MSSQL::Component::DatabaseSubsystem::Database);
use strict;

sub finish {
  my ($self) = @_;
  %{$self->{filesystems}} = %{$Classes::MSSQL::Component::DatabaseSubsystem::filesystems};
  $self->{full_name} = sprintf "%s::%s::%s",
      $self->{database_name}, $self->{filegroup_name}, $self->{name};
  # 8k-pages, umrechnen in bytes
  $self->{size} *= 8*1024;
  $self->{used_size} ||= 0; # undef kommt vor, alles schon gesehen.
  $self->{used_size} *= 8*1024;
  $self->{max_size} =~ s/\.$//g;
  if ($self->{growth} == 0) {
    # ist schon am anschlag
    $self->{max_size} = $self->{size};
    $self->{drive_reserve}->{$self->{drive}} = 0;
    $self->{formula} = sprintf "f %15s fixed %d (%dMB)", $self->{name}, $self->{max_size}, $self->{max_size} / 1048576;
    $self->{growth_desc} = "fixed size";
  } else {
    if ($self->{max_size} == -1) {
      # kann unbegrenzt wachsen, bis das filesystem voll ist.
      $self->{max_size} = $self->{size} +
          (exists $self->{filesystems}->{$self->{drive}} ? $self->{filesystems}->{$self->{drive}} : 0);
      $self->{drive_reserve}->{$self->{drive}} = 1;
      $self->{formula} = sprintf "f %15s ulimt %d (%dMB)", $self->{name}, $self->{max_size}, $self->{max_size} / 1048576;
      $self->{growth_desc} = "unlimited size";
    } elsif ($self->{max_size} == 268435456) {
      $self->{max_size} = 2 * 1024 * 1024 * 1024 * 1024;
      $self->{formula} = sprintf "f %15s ulims %d (%dMB)", $self->{name}, $self->{max_size}, $self->{max_size} / 1048576;
      $self->{drive_reserve}->{$self->{drive}} = 0;
      $self->{growth_desc} = "limited to 2TB";
    } else {
      # hat eine obergrenze
      $self->{max_size} *= 8*1024;
      $self->{formula} = sprintf "f %15s  limt %d (%dMB)", $self->{name}, $self->{max_size}, $self->{max_size} / 1048576;
      $self->{drive_reserve}->{$self->{drive}} = 0;
      $self->{growth_desc} = "limited";
    }
  }
  $self->mbize();
}

sub check {
  my ($self) = @_;
  if ($self->mode =~ /server::database::file::list$/) {
    printf "%s %s %s %s\n", $self->{database_name}, $self->{filegroup_name}, $self->{name}, $self->{path};
  } elsif ($self->mode =~ /server::database::file::free$/) {
    my $metric_pct = 'file_'.lc $self->{full_name}.'_free_pct';
    my $metric_units = 'file_'.lc $self->{full_name}.'_free';
    my $metric_allocated = 'file_'.lc $self->{full_name}.'_allocated_pct';
    my ($free_percent, $free_size, $free_units, $allocated_percent, $factor) = $self->calc(
        "file", $self->{full_name}, "",
        $self->{used_size}, $self->{size}, $self->{max_size},
        $metric_pct, $metric_units, $metric_allocated
    );
    $self->add_perfdata(
        label => $metric_pct,
        value => $free_percent,
        places => 2,
        uom => '%',
    );
    $self->add_perfdata(
        label => $metric_units,
        value => $free_units,
        uom => $self->opts->units eq "%" ? "MB" : $self->opts->units,
        places => 2,
        min => 0,
        max => $self->{max_size} / $factor,
    );
    $self->add_perfdata(
        label => $metric_allocated,
        value => $allocated_percent,
        places => 2,
        uom => '%',
    );
  }
}

