#! /usr/bin/perl -w -I ..
#
# Source-level sanity checks for the check_mssql_health tree.
# These tests avoid external database dependencies and focus on the
# repository's own code paths and mode registrations.
#

use strict;
use FindBin;
use Test::More;

my $root = "$FindBin::Bin/..";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "unable to read $path: $!";
    local $/;
    return <$fh>;
}

sub perl_syntax_ok {
    my ($path) = @_;
    my $output = qx{$^X -c $path 2>&1};
    return ($? == 0, $output);
}

plan tests => 19;

for my $path (
    "$FindBin::Bin/10_database_live.t",
    "$root/plugins-scripts/check_mssql_health.pl",
    "$root/plugins-scripts/CheckMssqlHealth/Device.pm",
    "$root/plugins-scripts/CheckMssqlHealth/Sybase/DBI.pm",
    "$root/plugins-scripts/CheckMssqlHealth/Sybase/Sqsh.pm",
    "$root/plugins-scripts/CheckMssqlHealth/Sybase/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/MSSQL/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/ASE/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/APS/SqlRelay.pm",
) {
    my ($ok, $output) = perl_syntax_ok($path);
    ok($ok, "$path syntax ok") or diag($output);
}

my $script = slurp("$root/plugins-scripts/check_mssql_health.pl");
like($script, qr/\$plugin->add_mode\(\s*internal => 'server::uptime',\s*spec => 'uptime'/s, 'uptime mode registered');
like($script, qr/spec => 'database-free'/, 'database-free mode registered');
like($script, qr/spec => 'sql-recompilations'/, 'sql-recompilations mode registered');
like($script, qr/spec => 'sql-initcompilations'/, 'sql-initcompilations mode registered');
like($script, qr/spec => 'list-databases'/, 'list-databases mode registered');
like($script, qr/spec => 'list-locks'/, 'list-locks mode registered');
unlike($script, qr/\b(?:tnsping|sga-data-buffer-hit-ratio|pga-in-memory-sort-ratio|tablespace-usage|redo-io-traffic|enqueue-contention|soft-parse-ratio)\b/, 'legacy oracle modes are absent');

my $device = slurp("$root/plugins-scripts/CheckMssqlHealth/Device.pm");
like($device, qr/elsif \(\$self->opts->method eq "sqlcmd"\) \{.*?bless \$self, "CheckMssqlHealth::Sybase::Sqsh";/s, 'sqlcmd uses sqsh backend');
like($device, qr/elsif \(\$self->opts->method eq "sqlrelay"\) \{\s*bless \$self, "CheckMssqlHealth::Sybase::SqlRelay";/s, 'sqlrelay uses matching package');

my $sqlrelay_files = join "\n", map { slurp($_) } (
    "$root/plugins-scripts/CheckMssqlHealth/Sybase/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/MSSQL/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/ASE/SqlRelay.pm",
    "$root/plugins-scripts/CheckMssqlHealth/APS/SqlRelay.pm",
);
unlike($sqlrelay_files, qr/Sqlrelay/, 'lowercase Sqlrelay no longer appears');
