package CheckMssqlHealth::MSSQL::Component::JobSubsystem;
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
                round([run_duration] / 10000, 0) * 3600 +
                CAST(SUBSTRING(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 8), 5, 2) AS INT) * 60 +
                CAST(SUBSTRING(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 8), 7, 2) AS INT) AS LastRunDurationSeconds,
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
                cast( round([run_duration] / 10000, 0) as VARCHAR(30)) + ':' +
				        STUFF(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 4), 3, 0, ':') AS [LastRunDuration (HH:MM:SS)],
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
          ['jobs', $sql, 'CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job', sub { $self->opts->lookback;my $o = shift; $self->filter_name($o->{name}) && (! defined $o->{minutessincestart} || $o->{minutessincestart} <= $self->opts->lookback);  }, $columns],
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

package CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;
use warnings;
use Time::Local;
use POSIX 'strftime';

# Function: is_likely_dst_switch_week
# -----------------------------------
# Returns true if the current date falls within a two-week window (one week
# before to one week after) the *approximate* North American or European DST
# switch dates. This is designed to be intentionally inexact to cover
# various time zones and years.
#
# Arguments: None (uses current system time)
# Returns:   Boolean (true if likely switch week, false otherwise)
sub is_likely_dst_switch_week {
  my $self = shift;
  my $now = time();
  my ($mday, $mon, $year) = (localtime($now))[3,4,5];
  $year += 1900;
  $mon += 1; # Convert to 1-12

  # A list of months where DST switches commonly occur
  # March (3), October (10), November (11)
  return 0 unless $mon == 3 || $mon == 10 || $mon == 11;

  # --- Common DST Switch Rules ---
  # We will define the *center* date for the switch week.
  # The check will be: is $now within +/- 7 days of the center date?

  # 1. North America (Spring Forward: 2nd Sunday in March)
  #    - Approximate center date: March 15th
  # 2. North America (Fall Back: 1st Sunday in November)
  #    - Approximate center date: November 5th
  # 3. Europe (Spring Forward: Last Sunday in March)
  #    - Approximate center date: March 28th
  # 4. Europe (Fall Back: Last Sunday in October)
  #    - Approximate center date: October 28th

  my %switch_centers = (
    # Key: month (1-12) => Value: day of month (1-31)
    3  => [15, 28], # March 15 (NA), March 28 (EU)
    10 => [28],     # October 28 (EU)
    11 => [5],      # November 5 (NA)
  );

  # Iterate through all center dates for the current month
  foreach my $center_day (@{$switch_centers{$mon}}) {
    # Create a time value for the center date
    # We use a known time (e.g., noon) for the center day
    my $center_time;
    eval {
        $center_time = Time::Local::timelocal(0, 0, 12, $center_day, $mon - 1, $year - 1900);
    };
    next if $@; # Skip if date is invalid (e.g., March 32nd)

    # Define the two-week window:
    # 7 days before to 7 days after the center date (14 days total)
    my $SEVEN_DAYS_IN_SECONDS = 7 * 24 * 60 * 60;

    my $start_window = $center_time - $SEVEN_DAYS_IN_SECONDS;
    my $end_window   = $center_time + $SEVEN_DAYS_IN_SECONDS;

    # Check if the current time falls within this window
    if ($now >= $start_window && $now <= $end_window) {
      # Optionally, you could print which center date triggered it
      # print "DEBUG: Likely DST switch near $mon/$center_day/$year\n";
      return 1;
    }
  }

  return 0;
}


sub check {
  my $self = shift;
  if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
      # A never-run job is only actionable when its scheduled time is already overdue.
      my $nextrun_epoch = $self->nextrundatetime_to_epoch();
      if (defined $nextrun_epoch && $nextrun_epoch <= time()) {
        $self->add_warning(sprintf "%s did never run and is overdue since %s",
            $self->{name}, $self->{nextrundatetime});
      } else {
        $self->add_ok(sprintf "%s did never run", $self->{name});
      }
    } elsif ($self->{lastrunstatus} eq "Failed") {
      $self->add_critical(sprintf "%s failed at %s: %s",
          $self->{name}, $self->{lastrundatetime},
          $self->{lastrunstatusmessage});
    } elsif ($self->{lastrunstatus} eq "Retry" || $self->{lastrunstatus} eq "Canceled") {
      $self->add_warning(sprintf "%s %s: %s",
          $self->{name}, $self->{lastrunstatus}, $self->{lastrunstatusmessage});
    } else {
      my $label = 'job_'.$self->{name}.'_runtime';
      # Bei der Zeitumstellung Sommer/Winter anno 2025 kam hier ein negativer
      # Wert von der Datenbank zurueck. Damit es nicht 2x im Jahr einen Alarm
      # gibt, schauen wir mal, ob gerade die typische Zeit fuer
      # Zeitumstellungen ist. Wenn ja, dann wird so ein negativer Wert einfach
      # ignoriert. Und wenn einer rummault, daß das unsauber ist, dann darf
      # er gerne ein Ticket bei Microsoft aufmachen. Oder ... kreuzweis.
      if ($self->is_likely_dst_switch_week()) {
        # Sollte jetzt so ein Zeitsprung stattgefunden haben, dann haben wir
        # jetzt den letzten positiven Wert, zumindest fuer die naechsten
        # 5 retries.
        $self->protect_value($label, "lastrundurationseconds", "positive");
	# Im restlichen Jahr gibt's halt Alarm.
      }
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

sub nextrundatetime_to_epoch {
  my $self = shift;
  return undef if ! defined $self->{nextrundatetime};
  my $nextrun = $self->{nextrundatetime};
  return $nextrun if $nextrun =~ /^\d+$/;
  my %months = (
    Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
  );
  if ($nextrun =~ /^([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s+(\d{1,2}):(\d{2})(AM|PM)$/) {
    my ($mon, $mday, $year, $hour, $min, $ampm) = ($1, $2, $3, $4, $5, $6);
    return undef if ! exists $months{$mon};
    $hour %= 12;
    $hour += 12 if $ampm eq 'PM';
    return Time::Local::timelocal(0, $min, $hour, $mday, $months{$mon}, $year - 1900);
  }
  return undef;
}
