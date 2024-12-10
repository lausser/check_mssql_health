#! /usr/bin/perl

use strict;

eval {
  if ( ! grep /BEGIN/, keys %Monitoring::GLPlugin::) {
    require Monitoring::GLPlugin;
    require Monitoring::GLPlugin::DB;
  }
};
if ($@) {
  printf "UNKNOWN - module Monitoring::GLPlugin was not found. Either build a standalone version of this plugin or set PERL5LIB\n";
  printf "%s\n", $@;
  exit 3;
}

my $plugin = Classes::Device->new(
    shortname => '',
    usage => '%s [-v] [-t <timeout>] '.
        '--hostname=<db server hostname> [--port <port>] '.
        '--username=<username> --password=<password> '.
        '--mode=<mode> '.
        '...',
    version => '$Revision: #PACKAGE_VERSION# $',
    blurb => 'This plugin checks microsoft sql servers ',
    url => 'http://labs.consol.de/nagios/check_mssql_health',
    timeout => 60,
);
$plugin->add_db_modes();
$plugin->add_mode(
    internal => 'server::uptime',
    spec => 'uptime',
    alias => undef,
    help => 'The time since the server started',
);
$plugin->add_mode(
    internal => 'server::cpubusy',
    spec => 'cpu-busy',
    alias => undef,
    help => 'Cpu busy in percent',
);
$plugin->add_mode(
    internal => 'server::iobusy',
    spec => 'io-busy',
    alias => undef,
    help => 'IO busy in percent',
);
$plugin->add_mode(
    internal => 'server::fullscans',
    spec => 'full-scans',
    alias => undef,
    help => 'Full table scans per second',
);
$plugin->add_mode(
    internal => 'server::connectedusers',
    spec => 'connected-users',
    alias => undef,
    help => 'Number of currently connected users',
);
$plugin->add_mode(
    internal => 'server::database::transactions',
    spec => 'transactions',
    alias => undef,
    help => 'Transactions per second (per database)',
);
$plugin->add_mode(
    internal => 'server::batchrequests',
    spec => 'batch-requests',
    alias => undef,
    help => 'Batch requests per second',
);
$plugin->add_mode(
    internal => 'server::latch::waits',
    spec => 'latches-waits',
    alias => undef,
    help => 'Number of latch requests that could not be granted immediately',
);
$plugin->add_mode(
    internal => 'server::latch::waittime',
    spec => 'latches-wait-time',
    alias => undef,
    help => 'Average time for a latch to wait before the request is met',
);
$plugin->add_mode(
    internal => 'server::memorypool::lock::waits',
    spec => 'locks-waits',
    alias => undef,
    help => 'The number of locks per second that had to wait',
);
$plugin->add_mode(
    internal => 'server::memorypool::lock::timeouts',
    spec => 'locks-timeouts',
    alias => undef,
    help => 'The number of locks per second that timed out',
);
 $plugin->add_mode(
     internal => 'server::memorypool::lock::timeoutsgt0',
     spec => 'locks-timeouts-greater-0s',
     alias => undef,
     help => 'The number of locks per second where timeout is greater than 0',
);
$plugin->add_mode(
    internal => 'server::memorypool::lock::deadlocks',
    spec => 'locks-deadlocks',
    alias => undef,
    help => 'The number of deadlocks per second',
);
$plugin->add_mode(
    internal => 'server::sql::recompilations',
    spec => 'sql-recompilations',
    alias => undef,
    help => 'Re-Compilations per second',
);
$plugin->add_mode(
    internal => 'server::sql::initcompilations',
    spec => 'sql-initcompilations',
    alias => undef,
    help => 'Initial compilations per second',
);
$plugin->add_mode(
    internal => 'server::totalmemory',
    spec => 'total-server-memory',
    alias => undef,
    help => 'The amount of memory that SQL Server has allocated to it',
);
$plugin->add_mode(
    internal => 'server::memorypool::buffercache::hitratio',
    spec => 'mem-pool-data-buffer-hit-ratio',
    alias => ['buffer-cache-hit-ratio'],
    help => 'Data Buffer Cache Hit Ratio',
);
$plugin->add_mode(
    internal => 'server::memorypool::buffercache::lazywrites',
    spec => 'lazy-writes',
    alias => undef,
    help => 'Lazy writes per second',
);
$plugin->add_mode(
    internal => 'server::memorypool::buffercache::pagelifeexpectancy',
    spec => 'page-life-expectancy',
    alias => undef,
    help => 'Seconds a page is kept in memory before being flushed',
);
$plugin->add_mode(
    internal => 'server::memorypool::buffercache::freeliststalls',
    spec => 'free-list-stalls',
    alias => undef,
    help => 'Requests per second that had to wait for a free page',
);
$plugin->add_mode(
    internal => 'server::memorypool::buffercache::checkpointpages',
    spec => 'checkpoint-pages',
    alias => undef,
    help => 'Dirty pages flushed to disk per second. (usually by a checkpoint)',
);
$plugin->add_mode(
    internal => 'server::database::online',
    spec => 'database-online',
    alias => undef,
    help => 'Check if a database is online and accepting connections',
);
$plugin->add_mode(
    internal => 'server::database::free',
    spec => 'database-free',
    alias => undef,
    help => 'Free space in database',
);
$plugin->add_mode(
    internal => 'server::database::datafree',
    spec => 'database-data-free',
    alias => undef,
    help => 'Free (data) space in database',
);
$plugin->add_mode(
    internal => 'server::database::logfree',
    spec => 'database-log-free',
    alias => undef,
    help => 'Free (transaction log) space in database',
);
$plugin->add_mode(
    internal => 'server::database::free::details',
    spec => 'database-free-details',
    alias => undef,
    help => 'Free space in database and filegroups',
);
$plugin->add_mode(
    internal => 'server::database::datafree::details',
    spec => 'database-data-free-details',
    alias => undef,
    help => 'Free (data) space in database and filegroups',
);
$plugin->add_mode(
    internal => 'server::database::logfree::details',
    spec => 'database-log-free-details',
    alias => undef,
    help => 'Free (transaction log) space in database and filegroups',
);
$plugin->add_mode(
    internal => 'server::database::filegroup::free',
    spec => 'database-filegroup-free',
    alias => undef,
    help => 'Free space in database filegroups',
);
$plugin->add_mode(
    internal => 'server::database::file::free',
    spec => 'database-file-free',
    alias => undef,
    help => 'Free space in database files',
);
$plugin->add_mode(
    internal => 'server::database::size',
    spec => 'database-size',
    alias => undef,
    help => 'Size of a database',
);
$plugin->add_mode(
    internal => 'server::database::backupage',
    spec => 'database-backup-age',
    alias => ['backup-age'],
    help => 'Elapsed time (in hours) since a database was last backed up',
);
$plugin->add_mode(
    internal => 'server::database::backupage::full',
    spec => 'database-full-backup-age',
    alias => undef,
    help => 'Elapsed time (in hours) since a database was last fully backed up',
);
$plugin->add_mode(
    internal => 'server::database::backupage::differential',
    spec => 'database-differential-backup-age',
    alias => undef,
    help => 'Elapsed time (in hours) since a database was last differentially backed up',
);
$plugin->add_mode(
    internal => 'server::database::logbackupage',
    spec => 'database-logbackup-age',
    alias => ['logbackup-age'],
    help => 'Elapsed time (in hours) since a database transaction log was last backed up',
);
$plugin->add_mode(
    internal => 'server::database::autogrowths::file',
    spec => 'database-file-auto-growths',
    alias => undef,
    help => 'The number of File Auto Grow events (either data or log) in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::autogrowths::logfile',
    spec => 'database-logfile-auto-growths',
    alias => undef,
    help => 'The number of Log File Auto Grow events in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::autogrowths::datafile',
    spec => 'database-datafile-auto-growths',
    alias => undef,
    help => 'The number of Data File Auto Grow events in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::autoshrinks::file',
    spec => 'database-file-auto-shrinks',
    alias => undef,
    help => 'The number of File Auto Shrink events (either data or log) in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::autoshrinks::logfile',
    spec => 'database-logfile-auto-shrinks',
    alias => undef,
    help => 'The number of Log File Auto Shrink events in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::autoshrinks::datafile',
    spec => 'database-datafile-auto-shrinks',
    alias => undef,
    help => 'The number of Data File Auto Shrink events in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::database::dbccshrinks::file',
    spec => 'database-file-dbcc-shrinks',
    alias => undef,
    help => 'The number of DBCC File Shrink events (either data or log) in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::availabilitygroup::status',
    spec => 'availability-group-health',
    alias => undef,
    help => 'Checks the health status of availability groups',
);
$plugin->add_mode(
    internal => 'server::jobs::failed',
    spec => 'failed-jobs',
    alias => undef,
    help => 'The jobs which did not exit successful in the last <n> minutes (use --lookback)',
);
$plugin->add_mode(
    internal => 'server::jobs::enabled',
    spec => 'jobs-enabled',
    alias => undef,
    help => 'The jobs which are not enabled (scheduled)',
);
$plugin->add_mode(
    internal => 'server::database::createuser',
    spec => 'create-monitoring-user',
    alias => undef,
    help => 'convenience function which creates a monitoring user',
);
$plugin->add_mode(
    internal => 'server::database::deleteuser',
    spec => 'delete-monitoring-user',
    alias => undef,
    help => 'convenience function which deletes a monitoring user',
);
$plugin->add_mode(
    internal => 'server::database::list',
    spec => 'list-databases',
    alias => undef,
    help => 'convenience function which lists all databases',
);
$plugin->add_mode(
    internal => 'server::database::file::list',
    spec => 'list-database-files',
    alias => undef,
    help => 'convenience function which lists all datafiles',
);
$plugin->add_mode(
    internal => 'server::database::filegroup::list',
    spec => 'list-database-filegroups',
    alias => undef,
    help => 'convenience function which lists all data file groups',
);
$plugin->add_mode(
    internal => 'server::memorypool::lock::listlocks',
    spec => 'list-locks',
    alias => undef,
    help => 'convenience function which lists all locks',
);
$plugin->add_mode(
    internal => 'server::jobs::listjobs',
    spec => 'list-jobs',
    alias => undef,
    help => 'convenience function which lists all jobs',
);
$plugin->add_mode(
    internal => 'server::aps::component::failed',
    spec => 'aps-failed-components',
    alias => undef,
    help => 'check faulty components (Microsoft Analytics Platform only)',
);
$plugin->add_mode(
    internal => 'server::aps::alert::active',
    spec => 'aps-alerts',
    alias => undef,
    help => 'check for severe alerts (Microsoft Analytics Platform only)',
);
$plugin->add_mode(
    internal => 'server::aps::disk::free',
    spec => 'aps-disk-free',
    alias => undef,
    help => 'check free disk space (Microsoft Analytics Platform only)',
);
$plugin->add_arg(
    spec => 'hostname=s',
    help => "--hostname
   the database server",
    required => 0,
);
$plugin->add_arg(
    spec => 'username=s',
    help => "--username
   the mssql user",
    required => 0,
    decode => "rfc3986",
);
$plugin->add_arg(
    spec => 'password=s',
    help => "--password
   the mssql user's password",
    required => 0,
    decode => "rfc3986",
);
$plugin->add_arg(
    spec => 'port=i',
    default => 1433,
    help => "--port
   the database server's port",
    required => 0,
);
$plugin->add_arg(
    spec => 'server=s',
    help => "--server
   use a section in freetds.conf instead of hostname/port",
    required => 0,
);
$plugin->add_arg(
    spec => 'currentdb=s',
    help => "--currentdb
   the name of a database which is used as the current database
   for the connection. (don't use this parameter unless you
   know what you're doing)",
    required => 0,
);
$plugin->add_arg(
    spec => 'offlineok',
    help => "--offlineok
   if mode database-free finds a database which is currently offline,
   a WARNING is issued. If you don't want this and if offline databases
   are perfectly ok for you, then add --offlineok. You will get OK instead.",
    required => 0,
);
$plugin->add_arg(
    spec => 'nooffline',
    help => "--nooffline
   skip the offline databases",
    required => 0,);
$plugin->add_arg(
    spec => 'check-all-replicas',
    help => "--check-all-replicas
   In an Always On setup the backup the default is to run backup checks
   only on the preferred replica.
   For secondary replicas the backup checks return OK by default. Use this flag
   to check them as well for backup problems.",
    required => 0,
);

$plugin->add_db_args();
$plugin->add_default_args();

$plugin->getopts();
$plugin->classify();
$plugin->validate_args();


if (! $plugin->check_messages()) {
  $plugin->init();
  if (! $plugin->check_messages()) {
    $plugin->add_ok($plugin->get_summary())
        if $plugin->get_summary();
    $plugin->add_ok($plugin->get_extendedinfo(" "))
        if $plugin->get_extendedinfo();
  }
} else {
#  $plugin->add_critical('wrong device');
}
my ($code, $message) = $plugin->opts->multiline ?
    $plugin->check_messages(join => "\n", join_all => ', ') :
    $plugin->check_messages(join => ', ', join_all => ', ');
$message .= sprintf "\n%s\n", $plugin->get_info("\n")
    if $plugin->opts->verbose >= 1;
#printf "%s\n", Data::Dumper::Dumper($plugin);
$plugin->nagios_exit($code, $message);


