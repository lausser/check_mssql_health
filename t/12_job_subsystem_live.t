#! /usr/bin/perl -w
#
# Integration tests for the failed-jobs mode against a REAL MSSQL Server.
#
# It creates real SQL Server Agent jobs, starts them, and lets them run for
# real durations (the whole suite takes ~7 minutes because one job runs for
# 6 minutes). It then drives the actual built plugin (plugins-scripts/
# check_mssql_health, --method sqlcmd) and asserts Nagios output and exit codes.
#
# This is the only place the timing-sensitive behaviour is exercised for real:
#   - runtime thresholds of a *running* job crossing 60s (WARNING) and 300s
#     (CRITICAL),
#   - a finished job whose duration exceeds the threshold,
#   - terminal jobs aging out of the lookback window (timezone-safe: the window
#     is measured against the server clock, not the monitoring host's),
#   - live sysjobactivity state winning over a stale history row.
#
# The server is a podman container. The plugin talks to it through a tiny
# `sqlcmd`-compatible wrapper (written to a temp dir) that shells into the
# container, so no SQL client is needed on the host. The suite is skipped
# unless podman and the container are available.
#
# Env overrides: MSSQL_CONTAINER, MSSQL_SA_PASSWORD, MSSQL_PLUGIN.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $container = $ENV{MSSQL_CONTAINER}    || 'checkmssql-sqlserver';
my $pass      = $ENV{MSSQL_SA_PASSWORD}  || 'Str0ng!Passw0rd123';
my $repo      = "$FindBin::Bin/..";
my $plugin    = $ENV{MSSQL_PLUGIN}       || "$repo/plugins-scripts/check_mssql_health";
my $sqlcmd    = '/opt/mssql-tools18/bin/sqlcmd';

# ---- Availability gate ---------------------------------------------------
plan skip_all => "podman not found"          unless `which podman 2>/dev/null`;
plan skip_all => "container $container not running"
    unless `podman ps --format '{{.Names}}' 2>/dev/null` =~ /^\Q$container\E$/m;
plan skip_all => "cannot reach sqlcmd in $container"
    unless system("podman exec $container $sqlcmd -S localhost -U sa -P '$pass' -C -l 5 -Q 'SELECT 1' >/dev/null 2>&1") == 0;

# ---- Rebuild the monolith so we test the current source ------------------
# The runnable plugin is concatenated from the .pm sources by make; editing a
# .pm without rebuilding would silently test stale code.
if (system("cd $repo/plugins-scripts && make check_mssql_health >/dev/null 2>&1") == 0) {
    diag "rebuilt $plugin from source";
} else {
    diag "could not rebuild plugin; testing existing $plugin";
}
plan skip_all => "plugin not found at $plugin" unless -x $plugin;

# ---- sqsh-compatible wrapper the plugin will call ------------------------
# The plugin invokes the `sqsh` binary for both --method sqsh and --method
# sqlcmd. This wrapper accepts the sqsh arguments the plugin passes and runs the
# query inside the container via sqlcmd. Host/port are ignored; we always target
# the container's local instance.
my $bindir = tempdir(CLEANUP => 1);
open my $w, '>', "$bindir/sqsh" or die "cannot write wrapper: $!";
print $w <<"WRAP";
#!/usr/bin/env bash
set -euo pipefail
infile=""; outfile=""; db="master"; user="sa"; password='$pass'
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -i) infile="\$2"; shift 2;;
    -o) outfile="\$2"; shift 2;;
    -D) db="\$2"; shift 2;;
    -U) user="\$2"; shift 2;;
    -P) password="\$2"; shift 2;;
    -S) shift 2;;
    -h|-s|-m)
      shift 1
      if [ "\${1:-}" = "bcp" ]; then shift 1; fi
      ;;
    *) shift 1;;
  esac
done
[ -n "\$infile" ] && [ -n "\$outfile" ] || { echo "missing -i/-o" >&2; exit 1; }
podman cp "\$infile" $container:/tmp/plugin_cmd.sql >/dev/null
podman exec $container $sqlcmd -S localhost,1433 -U "\$user" -P "\$password" -d "\$db" -C -W -s '|' -h -1 -i /tmp/plugin_cmd.sql > "\$outfile"
WRAP
close $w;
chmod 0755, "$bindir/sqsh";

# ---- Helpers -------------------------------------------------------------
sub db {   # run inline SQL in the container, return output
    my ($sql) = @_;
    $sql =~ s/'/'\\''/g;
    return `podman exec $container $sqlcmd -S localhost -U sa -P '$pass' -C -W -s '|' -h -1 -Q '$sql' 2>&1`;
}

sub db_file {   # run a .sql file (with GO batches) in the container
    my ($path) = @_;
    system("podman cp '$path' $container:/tmp/plugin_setup.sql >/dev/null 2>&1") == 0
        or die "podman cp $path failed";
    return `podman exec $container $sqlcmd -S localhost -U sa -P '$pass' -C -i /tmp/plugin_setup.sql 2>&1`;
}

sub plugin {   # run the built plugin, return (exit_code, output)
    # plugin($args) runs as sa (full grants); plugin($args, $user, $pw) runs as
    # another login, used to exercise the least-privilege path.
    my ($args, $user, $password) = @_;
    $user     = 'sa'  if ! defined $user;
    $password = $pass if ! defined $password;
    local $ENV{PATH} = "$bindir:$ENV{PATH}";
    my $out = `$plugin --hostname 127.0.0.1 --port 1433 --username $user --password '$password' --method sqlcmd --mode failed-jobs $args 2>&1`;
    return ($? >> 8, $out);
}

my $T0;
sub wait_until {   # sleep until $sec seconds after the jobs were started
    my ($sec) = @_;
    my $target = $T0 + $sec;
    my $now = time();
    sleep($target - $now) if $target > $now;
}

sub job_run_status {   # latest step_0 run_status for a job, '' if none yet
    my ($name) = @_;
    my $out = db(qq{SELECT h.run_status FROM msdb.dbo.sysjobhistory h }
        . qq{JOIN msdb.dbo.sysjobs j ON h.job_id=j.job_id }
        . qq{WHERE j.name=N'$name' AND h.step_id=0 }
        . qq{ORDER BY h.run_date DESC, h.run_time DESC});
    return ($out =~ /^\s*(\d+)\s*$/m) ? $1 : '';
}

# ---- Setup ---------------------------------------------------------------
diag "Cleaning up any leftover JobTest_ jobs...";
db_file("$FindBin::Bin/sql/job_scenarios_cleanup.sql");
diag "Creating scenario jobs...";
db_file("$FindBin::Bin/sql/job_scenarios_setup.sql");

diag "Starting jobs (T0)...";
db(q{USE msdb;
    EXEC dbo.sp_start_job @job_name=N'JobTest_FailQuick';
    EXEC dbo.sp_start_job @job_name=N'JobTest_SucceedQuick';
    EXEC dbo.sp_start_job @job_name=N'JobTest_SucceedSlow';
    EXEC dbo.sp_start_job @job_name=N'JobTest_Runner';
    EXEC dbo.sp_start_job @job_name=N'JobTest_CancelMe';});
$T0 = time();

# ---- Waypoint ~20s: quick jobs done, long jobs running -------------------
wait_until(20);

subtest 'FailQuick is CRITICAL' => sub {
    my ($rc, $out) = plugin("--name JobTest_FailQuick --lookback 30");
    is($rc, 2, "exit CRITICAL") or diag $out;
    like($out, qr/CRITICAL/, "says CRITICAL");
    like($out, qr/JobTest_FailQuick failed/, "names the failure");
};

subtest 'least-privilege user: base query works, no permission error' => sub {
    # A monitoring user with exactly the create-monitoring-user msdb grants
    # (sysjobs, sysjobschedules, sysjobhistory) and none of the enhancement
    # objects (sysjobactivity, sysschedules). The permission-aware query must
    # fall back to the base 3-table form: no "SELECT permission denied", and the
    # core failed-job verdict must still be correct.
    db(q{USE master; IF SUSER_ID('checkmon_t') IS NOT NULL DROP LOGIN checkmon_t;
         CREATE LOGIN checkmon_t WITH PASSWORD='Ch3ckM0n!t', CHECK_POLICY=OFF;});
    db(q{USE msdb; IF DATABASE_PRINCIPAL_ID('checkmon_t') IS NOT NULL DROP USER checkmon_t;
         CREATE USER checkmon_t FOR LOGIN checkmon_t;
         GRANT SELECT ON sysjobhistory TO checkmon_t;
         GRANT SELECT ON sysjobschedules TO checkmon_t;
         GRANT SELECT ON sysjobs TO checkmon_t;});
    my ($rc, $out) = plugin("--name JobTest_FailQuick --lookback 30", 'checkmon_t', 'Ch3ckM0n!t');
    unlike($out, qr/denied|permission/i, "no permission error for least-privilege user");
    is($rc, 2, "failed job still CRITICAL for least-privilege user") or diag $out;
    like($out, qr/JobTest_FailQuick failed/, "failure reported");
    db(q{USE msdb; IF DATABASE_PRINCIPAL_ID('checkmon_t') IS NOT NULL DROP USER checkmon_t;});
    db(q{USE master; IF SUSER_ID('checkmon_t') IS NOT NULL DROP LOGIN checkmon_t;});
};

subtest 'SucceedQuick is OK via runtime path' => sub {
    my ($rc, $out) = plugin("--name JobTest_SucceedQuick --lookback 30");
    is($rc, 0, "exit OK") or diag $out;
    like($out, qr/JobTest_SucceedQuick ran for \d+ seconds/, "reports runtime");
};

subtest 'Runner detected as running with no history (sysjobactivity)' => sub {
    # First-ever run: no history row exists yet, so this only works if the live
    # activity join surfaces it as Running instead of DidNeverRun.
    is(job_run_status('JobTest_Runner'), '', "no history row yet (first run)");
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30");
    is($rc, 0, "running job under default threshold is OK") or diag $out;
    like($out, qr/JobTest_Runner ran for \d+ seconds/, "runtime path, not never-run");
};

subtest 'NeverRunFuture is OK' => sub {
    my ($rc, $out) = plugin("--name JobTest_NeverRunFuture --lookback 30");
    is($rc, 0, "exit OK") or diag $out;
    like($out, qr/JobTest_NeverRunFuture did never run/, "reports never-run");
};

subtest 'NeverRunPast is WARNING (overdue)' => sub {
    my ($rc, $out) = plugin("--name JobTest_NeverRunPast --lookback 30");
    is($rc, 1, "exit WARNING") or diag $out;
    like($out, qr/JobTest_NeverRunPast did never run and is overdue/, "reports overdue");
};

diag "Cancelling JobTest_CancelMe mid-run...";
db(q{USE msdb; EXEC dbo.sp_stop_job @job_name=N'JobTest_CancelMe';});

# ---- Waypoint ~45s: cancellation has been recorded ----------------------
wait_until(45);

subtest 'CancelMe is WARNING (Canceled)' => sub {
    is(job_run_status('JobTest_CancelMe'), 3, "history run_status is Canceled(3)");
    my ($rc, $out) = plugin("--name JobTest_CancelMe --lookback 30");
    is($rc, 1, "exit WARNING") or diag $out;
    like($out, qr/JobTest_CancelMe Canceled/, "reports Canceled");
};

# ---- Waypoint ~95s: SucceedSlow finished (>60s), Runner still running ----
wait_until(95);

subtest 'SucceedSlow succeeded but over threshold -> WARNING' => sub {
    is(job_run_status('JobTest_SucceedSlow'), 1, "history run_status is Succeeded(1)");
    my ($rc, $out) = plugin("--name JobTest_SucceedSlow --lookback 30");
    is($rc, 1, "exit WARNING (ran >60s)") or diag $out;
    like($out, qr/JobTest_SucceedSlow ran for (?:[6-9]\d|\d{3,}) seconds/, "runtime over 60s");
};

subtest 'Runner running past WARNING threshold -> WARNING' => sub {
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30");
    is($rc, 1, "exit WARNING (running >60s, <300s, default thresholds)") or diag $out;
    like($out, qr/JobTest_Runner ran for (?:[6-9]\d|[12]\d\d) seconds/, "runtime 60-299s");
};

# ---- Waypoint ~315s: Runner running past CRITICAL threshold -------------
wait_until(315);

subtest 'Runner running past CRITICAL threshold -> CRITICAL' => sub {
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30");
    is($rc, 2, "exit CRITICAL (running >300s, default thresholds)") or diag $out;
    like($out, qr/JobTest_Runner ran for [3-9]\d\d seconds/, "runtime >=300s");
};

# ---- Wait for Runner to finish (~360s) ----------------------------------
diag "Waiting for Runner to finish...";
while (time() < $T0 + 420) {
    last if job_run_status('JobTest_Runner') ne '' && job_run_status('JobTest_Runner') != 4;
    sleep 10;
}

subtest 'Runner finished: long success trips CRITICAL at default threshold' => sub {
    is(job_run_status('JobTest_Runner'), 1, "history run_status is Succeeded(1)");
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30");
    is($rc, 2, "exit CRITICAL (duration ~360s > 300)") or diag $out;
    like($out, qr/JobTest_Runner ran for [3-9]\d\d seconds/, "reports the long duration");
};

subtest 'Runner finished: OK with a wider threshold' => sub {
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30 --warning 400 --critical 600");
    is($rc, 0, "exit OK with --warning 400 --critical 600") or diag $out;
    like($out, qr/JobTest_Runner ran for [3-9]\d\d seconds/, "reports the long duration");
};

subtest 'Live activity wins over the stale Succeeded history' => sub {
    # Runner now has a Succeeded history row (~360s). Restart it: the fresh
    # in-progress activity must win, so the reported runtime is small, not 360s.
    db(q{USE msdb; EXEC dbo.sp_start_job @job_name=N'JobTest_Runner';});
    sleep 10;
    my ($rc, $out) = plugin("--name JobTest_Runner --lookback 30");
    is($rc, 0, "new running instance is OK (small runtime)") or diag $out;
    like($out, qr/JobTest_Runner ran for \d{1,2} seconds/, "runtime is the new run, not the stale 360s");
    db(q{USE msdb; EXEC dbo.sp_stop_job @job_name=N'JobTest_Runner';});
};

# ---- Aging out of the lookback window (timezone-safe) --------------------
subtest 'FailQuick ages out with a 1-minute lookback' => sub {
    # FailQuick finished minutes ago; with lookback 1 it is out of scope.
    my ($rc, $out) = plugin("--name JobTest_FailQuick --lookback 1");
    is($rc, 0, "exit OK (aged out)") or diag $out;
    like($out, qr/no jobs finished within the last 1 minutes/, "empty-scope message");
};

subtest 'FailQuick still CRITICAL within a 60-minute lookback' => sub {
    my ($rc, $out) = plugin("--name JobTest_FailQuick --lookback 60");
    is($rc, 2, "exit CRITICAL (still in window)") or diag $out;
    like($out, qr/JobTest_FailQuick failed/, "still reported");
};

subtest 'SucceedQuick ages out with a 1-minute lookback' => sub {
    my ($rc, $out) = plugin("--name JobTest_SucceedQuick --lookback 1");
    is($rc, 0, "exit OK (aged out)") or diag $out;
};

# ---- Cleanup -------------------------------------------------------------
diag "Cleaning up scenario jobs...";
db_file("$FindBin::Bin/sql/job_scenarios_cleanup.sql");

done_testing();
