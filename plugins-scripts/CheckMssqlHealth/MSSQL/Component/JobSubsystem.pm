package CheckMssqlHealth::MSSQL::Component::JobSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::jobs::(failed|enabled|list)/) {
    $self->override_opt('lookback', 30) if ! $self->opts->lookback;
    if ($self->version_is_minimum("9.x")) {
      my $columns = ['id', 'name', 'now', 'lastrundurationseconds', 'lastrundatetime', 'lastrunstatus', 'lastrunduration', 'lastrunstatusmessage', 'nextrundatetime'];
      # The base query needs only the three msdb objects the monitoring user is
      # granted by default (sysjobs, sysjobschedules, sysjobhistory). Two
      # enhancements need extra objects that a least-privilege user cannot read:
      #   - running-detection (live status + elapsed for a currently executing
      #     run) needs sysjobactivity;
      #   - overdue-never-run warnings need sysschedules.
      # Probe permissions with HAS_PERMS_BY_NAME (needs no special rights) and
      # splice those fragments in only when readable. Without them the query is
      # exactly the granted-3-table query and behaves like earlier versions - no
      # errors, just none of the two enhancements. See
      # doc/job-subsystem-privileges.md.
      my ($can_activity, $can_schedules) = $self->fetchrow_array(q{
          SELECT
              HAS_PERMS_BY_NAME('msdb.dbo.sysjobactivity', 'OBJECT', 'SELECT'),
              HAS_PERMS_BY_NAME('msdb.dbo.sysschedules',   'OBJECT', 'SELECT')
      });
      my $use_activity  = $can_activity  ? 1 : 0;
      my $use_schedules = $can_schedules ? 1 : 0;

      # The condition that flags a currently in-progress run.
      my $act_running = q{[sACT].[start_execution_date] IS NOT NULL AND [sACT].[stop_execution_date] IS NULL};

      # --- Optional column fragments (empty unless the grant exists) ---------
      # Duration: the history decode is a bare expression, so the running branch
      # must wrap it in a whole CASE (a leading WHEN alone would leave an invalid
      # "CASE ELSE ... END" when running-detection is off).
      my $duration_hist = q{round([run_duration] / 10000, 0) * 3600 +
                        CAST(SUBSTRING(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 8), 5, 2) AS INT) * 60 +
                        CAST(SUBSTRING(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 8), 7, 2) AS INT)};
      my $duration_col = $use_activity ? qq{CASE
                    WHEN $act_running THEN
                        DATEDIFF(SECOND, [sACT].[start_execution_date], CURRENT_TIMESTAMP)
                    ELSE
                        $duration_hist
                END} : $duration_hist;
      my $date_running_when = $use_activity ? qq{
                    WHEN $act_running THEN
                        CONVERT(VARCHAR(30), [sACT].[start_execution_date], 120)} : '';
      my $status_running_when = $use_activity ? qq{
                    WHEN $act_running THEN 'Running'} : '';
      # A running row carries a stale history message; blank it. Only meaningful
      # when running-detection is on, otherwise there is no running row.
      my $message_col = $use_activity ? qq{CASE WHEN $act_running THEN NULL ELSE [sJOBH].[message] END} : q{[sJOBH].[message]};
      my $nextrun_sch_when = $use_schedules ? qq{
                    WHEN [sSCH].[active_start_date] > 0 THEN
                        -- Never-run jobs have no computed next_run_date; fall back to the
                        -- schedule's configured start so a past start reads as overdue.
                        CONVERT(VARCHAR(30),
                            CAST(
                                CAST([sSCH].[active_start_date] AS CHAR(8)) + ' ' + STUFF(STUFF(RIGHT('000000' + CAST([sSCH].[active_start_time] AS VARCHAR(6)),  6), 3, 0, ':'), 6, 0, ':') AS DATETIME), 120)} : '';

      # --- Optional join fragments ------------------------------------------
      my $join_schedules = $use_schedules ? q{
                LEFT JOIN (
                    -- Configured schedule start, the overdue reference for jobs
                    -- that have never run (no computed next_run_date).
                    SELECT
                        js.[job_id],
                        MIN(ss.[active_start_date]) AS [active_start_date],
                        MIN(ss.[active_start_time]) AS [active_start_time]
                    FROM
                        [msdb].[dbo].[sysjobschedules] js
                    JOIN
                        [msdb].[dbo].[sysschedules] ss ON js.[schedule_id] = ss.[schedule_id]
                    GROUP BY
                        js.[job_id]
                ) AS [sSCH]
                ON
                    [sJOB].[job_id] = [sSCH].[job_id]} : '';
      my $join_activity = $use_activity ? q{
                LEFT JOIN (
                    -- In-progress executions of the current SQL Agent session.
                    -- The current session is the one with the highest session_id
                    -- that has activity rows, so no syssessions lookup is needed.
                    SELECT
                        [job_id],
                        [start_execution_date],
                        [stop_execution_date]
                    FROM
                        [msdb].[dbo].[sysjobactivity]
                    WHERE
                        [session_id] = (SELECT MAX([session_id]) FROM [msdb].[dbo].[sysjobactivity])
                ) AS [sACT]
                ON
                    [sJOB].[job_id] = [sACT].[job_id]} : '';

      my $sql = qq{
            SELECT
                [sJOB].[job_id] AS [JobID],
                [sJOB].[name] AS [JobName],
                CONVERT(VARCHAR(30), CURRENT_TIMESTAMP, 120) AS [Now], -- server clock, reference for all age/elapsed math (timezone-safe)
                -- A running row (sysjobactivity) takes priority over the latest
                -- finished run (sysjobhistory): its elapsed time so far, not the
                -- previous run's duration. Present only when sysjobactivity is
                -- readable, otherwise this is just the history decode.
                $duration_col AS LastRunDurationSeconds,
                CASE$date_running_when
                    WHEN [sJOBH].[run_date] IS NULL OR [sJOBH].[run_time] IS NULL THEN
                        NULL
                    ELSE
                        CONVERT(VARCHAR(30),
                            CAST(
                                CAST([sJOBH].[run_date] AS CHAR(8)) + ' ' +
                                STUFF(STUFF(RIGHT('000000' + CAST([sJOBH].[run_time] AS VARCHAR(6)), 6), 3, 0, ':'), 6, 0, ':') AS DATETIME), 120)
                END AS [LastRunDateTime],
                CASE$status_running_when
                    WHEN [sJOBH].[run_status] = 0 THEN 'Failed'
                    WHEN [sJOBH].[run_status] = 1 THEN 'Succeeded'
                    WHEN [sJOBH].[run_status] = 2 THEN 'Retry'
                    WHEN [sJOBH].[run_status] = 3 THEN 'Canceled'
                    WHEN [sJOBH].[run_status] = 4 THEN 'Running' -- In Progress
                    ELSE 'DidNeverRun'
                END AS [LastRunStatus],
                cast( round([run_duration] / 10000, 0) as VARCHAR(30)) + ':' +
				        STUFF(RIGHT('00000000' + CAST([run_duration] AS VARCHAR(30)), 4), 3, 0, ':') AS [LastRunDuration (HH:MM:SS)],
                $message_col AS [LastRunStatusMessage],
                CASE
                    WHEN [sJOBSCH].[NextRunDate] > 0 THEN
                        CONVERT(VARCHAR(30),
                            CAST(
                                CAST([sJOBSCH].[NextRunDate] AS CHAR(8)) + ' ' + STUFF(STUFF(RIGHT('000000' + CAST([sJOBSCH].[NextRunTime] AS VARCHAR(6)),  6), 3, 0, ':'), 6, 0, ':') AS DATETIME), 120)$nextrun_sch_when
                    ELSE
                        NULL
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
                    [sJOB].[job_id] = [sJOBSCH].[job_id]$join_schedules
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
                    [sJOBH].[RowNumber] = 1$join_activity
            ORDER BY
                [JobName]
      };
      $self->get_db_tables([
          ['jobs', $sql, 'CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job', sub { my $o = shift; $self->filter_name($o->{name}); }, $columns],
      ]);
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
    if ($self->mode =~ /server::jobs::failed/) {
      # Selection policy: keep active (Running, Retry) and never-run jobs
      # always visible, and keep terminal jobs (Failed, Succeeded, Canceled)
      # visible until <lookback> minutes after they finished. This closes the
      # blind spot where a long-running job that fails later than <lookback>
      # minutes after it *started* would otherwise never be reported.
      my $lookback = $self->opts->lookback;
      @{$self->{jobs}} = grep { $_->in_scope($lookback) } @{$self->{jobs}};
    }
    $self->SUPER::check();
    if (! @{$self->{jobs}}) {
      $self->add_ok(sprintf "no jobs finished within the last %d minutes",
          $self->opts->lookback);
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

#=============================================================================
# TIME / TIMEZONE MODEL  (read this before touching anything called *_epoch)
#=============================================================================
# WARNING: the numbers returned by iso_to_epoch/now_epoch/finished_epoch are
# NOT Unix timestamps. "epoch" here does not mean "seconds since 1970-01-01 UTC".
# They are "server-frame pseudo-epochs" and are only valid as DIFFERENCES.
#
# The design rests on three invariants:
#
#   1. Every date/time used for job timing comes from the DATABASE SERVER's
#      clock - never from the monitoring host. lastrundatetime, nextrundatetime
#      and the 'now' column are all CONVERT(...,120) renderings of server
#      columns (sysjobhistory/sysjobactivity/sysjobschedules/sysschedules) and
#      of CURRENT_TIMESTAMP. See doc/job-subsystem-timezones.md.
#
#   2. Each such string is normalized by iso_to_epoch() into an epoch-LIKE
#      integer count of seconds. It is parsed in one FIXED frame (timegm, i.e.
#      "as if UTC"). Because the server's wall-clock strings carry no timezone
#      offset, this integer equals the true Unix epoch ONLY when the server
#      itself runs in UTC; for any other server timezone it is off by that
#      server's offset. That absolute error is deliberate and harmless (see 3).
#
#   3. Since every value is in the same frame and the same unit (seconds),
#      a second-delta is just a subtraction, and the server's (unknown) offset
#      sits on both operands and cancels. So "did it finish within N minutes?"
#      and "is the next run overdue?" are correct regardless of the server's or
#      the host's timezone - which matters because one host checks servers all
#      over the world.
#
# Corollary: never compare one of these pseudo-epochs against Perl's time()
# (a real Unix epoch) in live operation - only against another server-frame
# value, i.e. now_epoch(). Doing so would reintroduce the offset you just
# cancelled.
#=============================================================================

# Parse an ISO datetime ("YYYY-MM-DD HH:MM:SS", as produced by CONVERT(..,120))
# into a server-frame pseudo-epoch (see the model note above - seconds, but NOT
# Unix time unless the server is UTC). A bare integer is passed through
# unchanged. Returns undef when the value is missing or unparseable.
sub iso_to_epoch {
  my ($self, $dt) = @_;
  return undef if ! defined $dt;
  return $dt if $dt =~ /^\d+$/;
  if ($dt =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/) {
    # timegm, not timelocal: parse in a fixed frame so the server's timezone
    # cancels out of every later difference (invariant 3 above).
    return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1 - 1900);
  }
  return undef;
}

# The reference clock for every age/overdue comparison: the DB server's own
# 'now' (CURRENT_TIMESTAMP, selected as the 'now' column), as a server-frame
# pseudo-epoch. Every other timestamp is compared against THIS, never against
# the monitoring host's clock, so the server timezone cancels (invariants 1-3).
# Falls back to Perl time() only when 'now' is absent (unit tests build rows by
# hand); in live operation 'now' is a constant column on every row, so the
# fallback never fires and pseudo-epochs are never mixed with real Unix time.
sub now_epoch {
  my $self = shift;
  my $now = $self->iso_to_epoch($self->{now});
  return defined $now ? $now : time();
}

# When did this job's latest execution finish, as a server-frame pseudo-epoch
# (see the TIME / TIMEZONE MODEL note above): start + duration. lastrundatetime
# is a server timestamp; lastrundurationseconds is a real second count computed
# on the server, so the sum stays in the server frame. Returns undef when start
# time or duration is unknown.
sub finished_epoch {
  my $self = shift;
  my $start = $self->iso_to_epoch($self->{lastrundatetime});
  return undef if ! defined $start;
  return undef if ! defined $self->{lastrundurationseconds};
  return $start + $self->{lastrundurationseconds};
}

# Is this job in scope for the failed-jobs check?
# Active states (Running, Retry) and never-run jobs are always in scope so the
# runtime-threshold and overdue-next-run paths can always run. Terminal states
# (Failed, Succeeded, Canceled) stay in scope until <lookback> minutes after
# they finished, then age out so the mode can return to OK.
sub in_scope {
  my ($self, $lookback) = @_;
  my $status = $self->{lastrunstatus};
  return 1 if ! defined $status;
  return 1 if $status =~ /^(Running|Retry|DidNeverRun)$/;
  my $finished = $self->finished_epoch;
  return 1 if ! defined $finished;
  return $finished + $lookback * 60 >= $self->now_epoch() ? 1 : 0;
}

sub check {
  my $self = shift;
  if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
      # A never-run job is only actionable when its scheduled time is already overdue.
      my $nextrun_epoch = $self->iso_to_epoch($self->{nextrundatetime});
      if (defined $nextrun_epoch && $nextrun_epoch <= $self->now_epoch()) {
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
