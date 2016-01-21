package Classes::MSSQL::Component::JobSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::jobs::(failed|enabled|list)/) {
    $self->override_opt('lookback', 30) if ! $self->opts->lookback;
    if ($self->version_is_minimum("9.x")) {
      my $columns = ['id', 'name', 'now', 'minutessincestart', 'lastrundurationseconds', 'lastrundatetime', 'lastrunstatus', 'lastrunduration', 'lastrunstatusmessage', 'nextrundatetime'];
      my $sql = q{
            SELECT
                [sJOB].[job_id] AS [JobID],
                [sJOB].[name] AS [JobName],
                CURRENT_TIMESTAMP,  --can be used for debugging
                CASE
                    WHEN
                        [sJOBH].[run_date] IS NULL OR [sJOBH].[run_time] IS NULL
                    THEN
                        NULL
                    ELSE
                        DATEDIFF(Minute, CAST(CAST([sJOBH].[run_date] AS CHAR(8)) + ' ' +
                        STUFF(STUFF(RIGHT('000000' + CAST([sJOBH].[run_time] AS VARCHAR(6)),  6), 3, 0, ':'), 6, 0, ':') AS DATETIME), CURRENT_TIMESTAMP)
                END AS [MinutesSinceStart],
                CAST(SUBSTRING(RIGHT('00000000' + CAST([sJOBH].[run_duration] AS VARCHAR(8)), 8), 1, 4) AS INT) * 3600 +
                CAST(SUBSTRING(RIGHT('00000000' + CAST([sJOBH].[run_duration] AS VARCHAR(8)), 8), 5, 2) AS INT) * 60 +
                CAST(SUBSTRING(RIGHT('00000000' + CAST([sJOBH].[run_duration] AS VARCHAR(8)), 8), 7, 2) AS INT) AS LastRunDurationSeconds,
                CASE
                    WHEN
                        [sJOBH].[run_date] IS NULL OR [sJOBH].[run_time] IS NULL
                    THEN
                        NULL
                    ELSE
                        CAST(
                            CAST([sJOBH].[run_date] AS CHAR(8)) + ' ' +
                            STUFF(STUFF(RIGHT('000000' + CAST([sJOBH].[run_time] AS VARCHAR(6)), 6), 3, 0, ':'), 6, 0, ':') AS DATETIME)
                END AS [LastRunDateTime],
                CASE [sJOBH].[run_status]
                    WHEN 0 THEN 'Failed'
                    WHEN 1 THEN 'Succeeded'
                    WHEN 2 THEN 'Retry'
                    WHEN 3 THEN 'Canceled'
                    WHEN 4 THEN 'Running' -- In Progress
                    ELSE 'DidNeverRun'
                END AS [LastRunStatus],
                STUFF(STUFF(RIGHT('00000000' + CAST([sJOBH].[run_duration] AS VARCHAR(8)), 8), 5, 0, ':'), 8, 0, ':') AS [LastRunDuration (HH:MM:SS)],
                [sJOBH].[message] AS [LastRunStatusMessage],
                CASE [sJOBSCH].[NextRunDate]
                    WHEN
                        0
                    THEN
                        NULL
                    ELSE
                        CAST(
                            CAST([sJOBSCH].[NextRunDate] AS CHAR(8)) + ' ' + STUFF(STUFF(RIGHT('000000' + CAST([sJOBSCH].[NextRunTime] AS VARCHAR(6)),  6), 3, 0, ':'), 6, 0, ':') AS DATETIME)
                END AS [NextRunDateTime]
            FROM
                [msdb].[dbo].[sysjobs] AS [sJOB]
                LEFT JOIN (
                    SELECT
                        [job_id],
                        MIN([next_run_date]) AS [NextRunDate],
                        MIN([next_run_time]) AS [NextRunTime]
                    FROM
                        [msdb].[dbo].[sysjobschedules]
                    GROUP BY
                        [job_id]
                ) AS [sJOBSCH]
                ON
                    [sJOB].[job_id] = [sJOBSCH].[job_id]
                LEFT JOIN (
                    SELECT
                        [job_id],
                        [run_date],
                        [run_time],
                        [run_status],
                        [run_duration],
                        [message],
                        ROW_NUMBER()
                        OVER (
                            PARTITION BY [job_id]
                            ORDER BY [run_date] DESC, [run_time] DESC
                        ) AS RowNumber
                    FROM
                        [msdb].[dbo].[sysjobhistory]
                    WHERE
                        [step_id] = 0
                ) AS [sJOBH]
                ON
                    [sJOB].[job_id] = [sJOBH].[job_id]
                AND
                    [sJOBH].[RowNumber] = 1
            ORDER BY
                [JobName]
      };
      $self->get_db_tables([
          ['jobs', $sql, 'Classes::MSSQL::Component::JobSubsystem::Job', sub { $self->opts->lookback;my $o = shift; $self->filter_name($o->{name}) && (! defined $o->{minutessincestart} || $o->{minutessincestart} <= $self->opts->lookback);  }, $columns],
      ]);      
@{$self->{jobs}} = reverse @{$self->{jobs}};
    }
  } else {
    $self->no_such_mode();
  }
}

sub check {
  my $self = shift;
  $self->add_info('checking jobs');
  if ($self->mode =~ /server::jobs::listjobs/) {
    foreach (@{$self->{jobs}}) {
      printf "%s\n", $_->{name};
    }
    $self->add_ok("have fun");
  } else {
    $self->SUPER::check();
    if (scalar @{$self->{jobs}} == 0) {
      $self->add_ok(sprintf "no jobs ran within the last %d minutes", $self->opts->lookback);
    }
  }
}

package Classes::MSSQL::Component::JobSubsystem::Job;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub check {
  my $self = shift;
  if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
      $self->add_ok(sprintf "%s did never run", $self->{name});
    } elsif ($self->{lastrunstatus} eq "Failed") {
      $self->add_critical(sprintf "%s failed at %s: %s",
          $self->{name}, $self->{lastrundatetime},
          $self->{lastrunstatusmessage});
    } elsif ($self->{lastrunstatus} eq "Retry" || $self->{lastrunstatus} eq "Canceled") {
      $self->add_warning(sprintf "%s %s: %s",
          $self->{name}, $self->{lastrunstatus}, $self->{lastrunstatusmessage});
    } else {
      my $label = 'job_'.$self->{name}.'_runtime';
      $self->set_thresholds(
          metric => $label,
          warning => 60,
          critical => 300,
      );
      $self->add_message(
          $self->check_thresholds(metric => $label, value => $self->{lastrundurationseconds}),
              sprintf("job %s ran for %d seconds (started %s)", $self->{name}, 
              $self->{lastrundurationseconds}, $self->{lastrundatetime})
      );
      $self->add_perfdata(
          label => $label,
          value => $self->{lastrundurationseconds},
          uom => 's',
      );
    }
  } elsif ($self->mode =~ /server::jobs::enabled/) {
    if (! defined $self->{nextrundatetime}) {
      $self->add_critical(sprintf "%s is not enabled",
          $self->{name});
    } else {
      $self->add_ok(sprintf "job %s will run at %s",
          $self->{name},  $self->{nextrundatetime});
    }
  }
}

