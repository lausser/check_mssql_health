package DBD::MSSQL::Server::Job;

use strict;

our @ISA = qw(DBD::MSSQL::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @jobs = ();
  my $initerrors = undef;

  sub add_job {
    push(@jobs, shift);
  }

  sub return_jobs {
    return reverse
        sort { $a->{name} cmp $b->{name} } @jobs;
  }

  sub init_jobs {
    my %params = @_;
    my $num_jobs = 0;
    if (($params{mode} =~ /server::jobs::failed/) ||
        ($params{mode} =~ /server::jobs::enabled/) ||
        ($params{mode} =~ /server::jobs::dummy/)) {
      my @jobresult = ();
      if ($params{product} eq "MSSQL") {
        if (DBD::MSSQL::Server::return_first_server()->version_is_minimum("9.x")) {
          @jobresult = $params{handle}->fetchall_array(q{
            SELECT 
                [sJOB].[job_id] AS [JobID]
                , [sJOB].[name] AS [JobName]
                ,CURRENT_TIMESTAMP  --can be used for debugging
                , CASE 
                    WHEN [sJOBH].[run_date] IS NULL OR [sJOBH].[run_time] IS NULL THEN NULL
                    ELSE datediff(Minute, CAST(
                        CAST([sJOBH].[run_date] AS CHAR(8))
                        + ' ' 
                        + STUFF(
                            STUFF(RIGHT('000000' + CAST([sJOBH].[run_time] AS VARCHAR(6)),  6)
                                , 3, 0, ':')
                                , 6, 0, ':')
                        AS DATETIME), current_timestamp)
                  END AS [MinutesSinceStart]
                ,CAST(SUBSTRING(RIGHT('000000' + CAST([sJOBH].[run_duration] AS VARCHAR(6)), 6), 1, 2) AS INT) * 3600 +
                 CAST(SUBSTRING(RIGHT('000000' + CAST([sJOBH].[run_duration] AS VARCHAR(6)), 6), 3, 2) AS INT) * 60 +
                 CAST(SUBSTRING(RIGHT('000000' + CAST([sJOBH].[run_duration] AS VARCHAR(6)), 6), 5, 2) AS INT) AS LastRunDurationSeconds
                , CASE 
                    WHEN [sJOBH].[run_date] IS NULL OR [sJOBH].[run_time] IS NULL THEN NULL
                    ELSE CAST(
                            CAST([sJOBH].[run_date] AS CHAR(8))
                            + ' ' 
                            + STUFF(
                                STUFF(RIGHT('000000' + CAST([sJOBH].[run_time] AS VARCHAR(6)),  6)
                                    , 3, 0, ':')
                                , 6, 0, ':')
                            AS DATETIME)
                  END AS [LastRunDateTime]
                , CASE [sJOBH].[run_status]
                    WHEN 0 THEN 'Failed'
                    WHEN 1 THEN 'Succeeded'
                    WHEN 2 THEN 'Retry'
                    WHEN 3 THEN 'Canceled'
                    WHEN 4 THEN 'Running' -- In Progress
                  END AS [LastRunStatus]
                , STUFF(
                        STUFF(RIGHT('000000' + CAST([sJOBH].[run_duration] AS VARCHAR(6)),  6)
                            , 3, 0, ':')
                        , 6, 0, ':') 
                    AS [LastRunDuration (HH:MM:SS)]
                , [sJOBH].[message] AS [LastRunStatusMessage]
                , CASE [sJOBSCH].[NextRunDate]
                    WHEN 0 THEN NULL
                    ELSE CAST(
                            CAST([sJOBSCH].[NextRunDate] AS CHAR(8))
                            + ' ' 
                            + STUFF(
                                STUFF(RIGHT('000000' + CAST([sJOBSCH].[NextRunTime] AS VARCHAR(6)),  6)
                                    , 3, 0, ':')
                                , 6, 0, ':')
                            AS DATETIME)
                  END AS [NextRunDateTime]
            FROM 
                [msdb].[dbo].[sysjobs] AS [sJOB]
                LEFT JOIN (
                            SELECT
                                [job_id]
                                , MIN([next_run_date]) AS [NextRunDate]
                                , MIN([next_run_time]) AS [NextRunTime]
                            FROM [msdb].[dbo].[sysjobschedules]
                            GROUP BY [job_id]
                        ) AS [sJOBSCH]
                    ON [sJOB].[job_id] = [sJOBSCH].[job_id]
                LEFT JOIN (
                            SELECT 
                                [job_id]
                                , [run_date]
                                , [run_time]
                                , [run_status]
                                , [run_duration]
                                , [message]
                                , ROW_NUMBER() OVER (
                                                        PARTITION BY [job_id] 
                                                        ORDER BY [run_date] DESC, [run_time] DESC
                                  ) AS RowNumber
                            FROM [msdb].[dbo].[sysjobhistory]
                            WHERE [step_id] = 0
                        ) AS [sJOBH]
                    ON [sJOB].[job_id] = [sJOBH].[job_id]
                    AND [sJOBH].[RowNumber] = 1
            ORDER BY [JobName]
          });
        } else {
          @jobresult = ();
        }
      } elsif ($params{product} eq "ASE") {
        @jobresult = $params{handle}->fetchall_array(q{
          SELECT name, dbid FROM master.dbo.sysjobs
        });
      }
      foreach (@jobresult) {
        my ($id, $name, $now, $minutessincestart, $lastrundurationseconds, $lastrundatetime, $lastrunstatus, $lastrunduration, $lastrunstatusmessage, $nextrundatetime) = @{$_};
        next if defined $minutessincestart && $minutessincestart > $params{lookback};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{id} = $id;
        $thisparams{lastrundatetime} = $lastrundatetime;
        $thisparams{minutessincestart} = $minutessincestart;
        $thisparams{lastrundurationseconds} = $lastrundurationseconds;
        $thisparams{lastrunstatus} = $lastrunstatus;
        $thisparams{lastrunstatusmessage} = $lastrunstatusmessage;
        $thisparams{netxtrundatetime} = $nextrundatetime;
        my $job = DBD::MSSQL::Server::Job->new(
            %thisparams);
        add_job($job);
        $num_jobs++;
      }
      if (! $num_jobs) {
        $initerrors = 1;
        return undef;
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
    lastrundatetime => $params{lastrundatetime},
    minutessincestart => $params{minutessincestart},
    lastrundurationseconds => $params{lastrundurationseconds},
    lastrunstatus => lc $params{lastrunstatus},
    lastrunstatusmessage => $params{lastrunstatusmessage},
    netxtrundatetime => $params{netxtrundatetime},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  $self->set_local_db_thresholds(%params);
  if ($params{mode} =~ /server::jobs::failed/) {
    #printf "init job %s\n", Data::Dumper::Dumper($self);
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::jobs::failed/ ||
        $params{mode} =~ /server::jobs::enabled/) {
      if ($self->{lastrunstatus} eq "failed") {
          $self->add_nagios_critical(
              sprintf "%s failed: %s", $self->{name}, $self->{lastrunstatusmessage});
      } elsif ($self->{lastrunstatus} eq "retry" || $self->{lastrunstatus} eq "canceled") {
          $self->add_nagios_warning(
              sprintf "%s %s: %s", $self->{name}, $self->{lastrunstatus}, $self->{lastrunstatusmessage});
      } elsif ($params{mode} =~ /server::jobs::enabled/ && ! defined $self->{nextrundatetime}) {
          $self->add_nagios_critical(
              sprintf "%s is not enabled", $self->{name});
      } elsif (! defined $self->{lastrundatetime}) {
          $self->add_nagios_ok(
              sprintf "%s did never run", $self->{name});
      } else {
        $self->add_nagios(
            $self->check_thresholds($self->{lastrundurationseconds}, 60, 300),
                sprintf("job %s ran for %d seconds (started %s)", $self->{name}, 
                $self->{lastrundurationseconds}, $self->{lastrundatetime}));
        if ($params{mode} =~ /server::jobs::enabled/) {
          $self->add_nagios_ok(sprintf "next run %s", $self->{nextrundatetime});
        }
      }
    } 
  }
}


1;
