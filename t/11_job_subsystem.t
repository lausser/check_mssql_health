#! /usr/bin/perl -w -I ..

use strict;
use Test::More;

BEGIN {
    package Monitoring::GLPlugin::DB::Item;
    sub import { }
    package Monitoring::GLPlugin::DB::TableItem;
    sub import { }
}

use lib 'plugins-scripts';
use CheckMssqlHealth::MSSQL::Component::JobSubsystem;

{
    package CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job;
    use strict;
    no warnings 'redefine';
    *Monitoring::GLPlugin::DB::TableItem::check = sub { };
    sub new {
        my $class = shift;
        my %args = (
            mode => $_[0],
            name => $_[1],
            nextrundatetime => $_[2],
            lastrundatetime => $_[3],
            lastrunstatus => $_[4],
            lastrunstatusmessage => $_[5],
            lastrundurationseconds => $_[6],
            # Server "now" reference; when a test passes one ($_[7]) use it,
            # otherwise default to the current time in the same UTC frame as
            # format_dt() so age math is self-consistent.
            now => defined $_[7] ? $_[7] : ::format_dt(time()),
            freqtype => $_[8],
        );
        return bless \%args, $class;
    }
    sub mode { $_[0]->{mode} }
    sub add_ok { $_[0]->{result} = ['OK', $_[1]] }
    sub add_warning { $_[0]->{result} = ['WARNING', $_[1]] }
    sub add_critical { $_[0]->{result} = ['CRITICAL', $_[1]] }
    sub add_info { }
    sub is_likely_dst_switch_week { 0 }
    sub protect_value { }
    sub set_thresholds { }
    sub check_thresholds { 'OK' }
    sub add_message { $_[0]->{result} = [$_[1], $_[2]] }
    sub add_perfdata { }
}

sub check_result {
    my ($job) = @_;
    $job->check();
    return $job->{result};
}

# Format an epoch as the ISO string the SQL query emits (CONVERT(..,120)).
# Uses gmtime so it round-trips through iso_to_epoch() (which uses timegm),
# making the whole test timezone-independent - the plugin compares server
# timestamps against the server "now", never the host clock.
sub format_dt {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

plan tests => 29;

my $now = time();
my $future = format_dt($now + 86400);
my $past   = format_dt($now - 86400);

# --- Per-job verdicts (Job::check) ---

is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'failed-job', undef, '2026-07-13 11:53:00', 'Failed', 'boom', 0)),
    ['CRITICAL', 'failed-job failed at 2026-07-13 11:53:00: boom'], 'failed job is critical');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'retry-job', undef, '2026-07-13 11:53:00', 'Retry', 'again', 0)),
    ['WARNING', 'retry-job Retry: again'], 'retry job is warning');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'canceled-job', undef, '2026-07-13 11:53:00', 'Canceled', 'stop', 0)),
    ['WARNING', 'canceled-job Canceled: stop'], 'canceled job is warning');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never-run-future', $future, undef, 'DidNeverRun', undef, undef)),
    ['OK', 'never-run-future did never run'], 'future never-run job stays ok');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never-run-past', $past, undef, 'DidNeverRun', undef, undef)),
    ['OK', 'never-run-past did never run'], 'past never-run job stays ok in failed-jobs');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'succeeded-job', undef, '2026-07-13 11:53:00', 'Succeeded', 'fine', 300)),
    ['OK', 'job succeeded-job ran for 300 seconds (started 2026-07-13 11:53:00)'], 'succeeded job follows runtime path');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'running-job', undef, '2026-07-13 11:53:00', 'Running', 'in progress', 120)),
    ['OK', 'job running-job ran for 120 seconds (started 2026-07-13 11:53:00)'], 'running job follows runtime-threshold path');

# --- finished_epoch: start + duration ---

my $start_epoch = $now - 1000;
my $fe_job = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'fe', undef, format_dt($start_epoch), 'Failed', 'x', 300);
is($fe_job->finished_epoch, $start_epoch + 300, 'finished_epoch = start + duration');

# --- in_scope: selection policy (Job::in_scope) ---

# Terminal job that finished 2 minutes ago is within a 30-minute lookback.
my $recent = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'failed-recent', undef, format_dt($now - 120), 'Failed', 'boom', 0);
ok($recent->in_scope(30), 'recently-finished failed job is in scope');
is_deeply(check_result($recent), ['CRITICAL', "failed-recent failed at ${\ format_dt($now - 120)}: boom"], 'recently-finished failed job is CRITICAL');

# The blind-spot case: started long ago, ran long, finished just now -> in scope.
my $late = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'late-fail', undef, format_dt($now - 120 * 60), 'Failed', 'boom', 118 * 60);
ok($late->in_scope(30), 'long-running job that just failed is in scope despite old start');

# Terminal job that finished 31 minutes ago has aged out of a 30-minute lookback.
my $old = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'failed-old', undef, format_dt($now - 51 * 60), 'Failed', 'old boom', 20 * 60);
ok(! $old->in_scope(30), 'failed job that finished before lookback is out of scope');

# Succeeded ages out too.
my $succ_old = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'succ-old', undef, format_dt($now - 51 * 60), 'Succeeded', 'done', 20 * 60);
ok(! $succ_old->in_scope(30), 'succeeded job that finished before lookback is out of scope');
my $succ_recent = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'succ-recent', undef, format_dt($now - 120), 'Succeeded', 'done', 0);
ok($succ_recent->in_scope(30), 'recently-finished succeeded job is in scope');

# Canceled ages out too.
my $canc_old = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'canc-old', undef, format_dt($now - 51 * 60), 'Canceled', 'stop', 20 * 60);
ok(! $canc_old->in_scope(30), 'canceled job that finished before lookback is out of scope');

# Active and never-run states are always in scope, regardless of age.
my $running_old = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'run-old', undef, format_dt($now - 999 * 60), 'Running', 'busy', 999 * 60);
ok($running_old->in_scope(30), 'running job is always in scope');
my $retry_old = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'retry-old', undef, format_dt($now - 999 * 60), 'Retry', 'again', 0);
ok($retry_old->in_scope(30), 'retry job is always in scope');
my $never = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never', $future, undef, 'DidNeverRun', undef, undef);
ok($never->in_scope(30), 'never-run job is always in scope');
my $never_noscore = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never2', undef, undef, undef, undef, undef);
ok($never_noscore->in_scope(30), 'job with undefined status is always in scope');

# --- overdue-jobs mode: never-run jobs, warning only when overdue ---

my $overdue_future = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::overdue', 'overdue-future', $future, undef, 'DidNeverRun', undef, undef);
is_deeply(check_result($overdue_future), ['OK', 'overdue-future did never run'], 'future never-run job stays ok in overdue-jobs');

my $overdue_past = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::overdue', 'overdue-past', $past, undef, 'DidNeverRun', undef, undef);
is_deeply(check_result($overdue_past), ['WARNING', "overdue-past did never run and is overdue since $past"], 'past never-run job warns in overdue-jobs');

# --- detect-running-jobs: sACT gives an in-progress run a defined start time ---
# A job running for the very first time (no completed history) is surfaced by
# the SQL as Running with a start time from sysjobactivity. It must go through
# the runtime-threshold path, NOT the never-run path.
my $first_run = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'first-run', undef, format_dt($now - 45), 'Running', undef, 45);
is_deeply(check_result($first_run), ['OK', "job first-run ran for 45 seconds (started ${\ format_dt($now - 45)})"], 'first-ever running job takes the runtime path, not never-run');
ok($first_run->in_scope(30), 'first-ever running job is always in scope');

# --- long-running ignore-list and freq_type=64 skip ---

# Task 4.1: Running job with freq_type=64 -> OK (auto-start skip)
my $autostart = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'cdc.MCM_CDB_capture', undef,
    format_dt($now - 86400), 'Running', 'in progress', 86400,
    undef, 64);
is_deeply(check_result($autostart),
    ['OK', 'cdc.MCM_CDB_capture is intentionally long-running (auto-start)'],
    'running job with freq_type=64 is OK (auto-start skip)');

# Task 4.2: Running job with freq_type!=64 -> runtime threshold check
my $nonautostart = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'daily-backup', undef,
    format_dt($now - 120), 'Running', 'in progress', 120,
    undef, 4);
is_deeply(check_result($nonautostart),
    ['OK', 'job daily-backup ran for 120 seconds (started ' . format_dt($now - 120) . ')'],
    'running job with freq_type!=64 follows runtime-threshold path');

# Task 4.3: Running job matching ignore-list -> OK (ignore-list skip)
my $cdccapture = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'cdc.MyDB_capture', undef,
    format_dt($now - 86400), 'Running', 'in progress', 86400);
is_deeply(check_result($cdccapture),
    ['OK', 'cdc.MyDB_capture is intentionally long-running (ignore-list)'],
    'running CDC capture job is OK (ignore-list skip)');

# Task 4.4: Failed job matching ignore-list -> CRITICAL (ignore-list does not apply)
my $cdcfailed = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'cdc.OtherDB_capture', undef,
    format_dt($now - 300), 'Failed', 'capture agent crashed', 300);
is_deeply(check_result($cdcfailed),
    ['CRITICAL', 'cdc.OtherDB_capture failed at ' . format_dt($now - 300) . ': capture agent crashed'],
    'failed CDC capture job is CRITICAL (ignore-list does not apply)');

# Task 4.5: Running job without sysschedules permission -> runtime threshold check
# (freq_type is undef, but ignore-list still works for CDC capture jobs)
my $noperm_cdc = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'cdc.Production_capture', undef,
    format_dt($now - 86400), 'Running', 'in progress', 86400);
is_deeply(check_result($noperm_cdc),
    ['OK', 'cdc.Production_capture is intentionally long-running (ignore-list)'],
    'CDC capture job without sysschedules permission still matches ignore-list');

# Running job without permission that is NOT in ignore-list -> runtime threshold
my $noperm_other = CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new(
    'server::jobs::failed', 'long-maintenance', undef,
    format_dt($now - 600), 'Running', 'cleanup', 600);
is_deeply(check_result($noperm_other),
    ['OK', 'job long-maintenance ran for 600 seconds (started ' . format_dt($now - 600) . ')'],
    'non-CDC running job without permission follows runtime-threshold path');
