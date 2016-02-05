
package main;

use strict;
use Getopt::Long qw(:config no_ignore_case);
use File::Basename;
use lib dirname($0);
use Nagios::DBD::MSSQL::Server;
use Nagios::DBD::MSSQL::Server::Instance;
use Nagios::DBD::MSSQL::Server::Instance::SGA;
use Nagios::DBD::MSSQL::Server::Instance::SGA::DataBuffer;
use Nagios::DBD::MSSQL::Server::Instance::SGA::SharedPool;
use Nagios::DBD::MSSQL::Server::Instance::SGA::SharedPool::LibraryCache;
use Nagios::DBD::MSSQL::Server::Instance::SGA::SharedPool::DictionaryCache;
use Nagios::DBD::MSSQL::Server::Instance::SGA::Latches;
use Nagios::DBD::MSSQL::Server::Instance::PGA;
use Nagios::DBD::MSSQL::Server::Instance::SGA::RedoLogBuffer;


my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

use vars qw ($PROGNAME $REVISION $CONTACT $TIMEOUT $STATEFILESDIR $needs_restart %commandline);

$PROGNAME = "check_mssql_health";
$REVISION = '$Revision: #PACKAGE_VERSION# $';
$CONTACT = 'gerhard.lausser@consol.de';
$TIMEOUT = 60;
$STATEFILESDIR = '#STATEFILES_DIR#';
$needs_restart = 0;

my @modes = (
  ['server::connectiontime',
      'connection-time', undef,
      'Time to connect to the server' ],
  ['server::cpubusy',
      'cpu-busy', undef,
      'Cpu busy in percent' ],
  ['server::iobusy',
      'io-busy', undef,
      'IO busy in percent' ],
  ['server::fullscans',
      'full-scans', undef,
      'Full table scans per second' ],
  ['server::connectedusers',
      'connected-users', undef,
      'Number of currently connected users' ],
  ['server::database::transactions',
      'transactions', undef,
      'Transactions per second (per database)' ],
  ['server::batchrequests',
      'batch-requests', undef,
      'Batch requests per second' ],
  ['server::latch::waits',
      'latches-waits', undef,
      'Number of latch requests that could not be granted immediately' ],
  ['server::latch::waittime',
      'latches-wait-time', undef,
      'Average time for a latch to wait before the request is met' ],
  ['server::memorypool::lock::waits',
      'locks-waits', undef,
      'The number of locks per second that had to wait' ],
  ['server::memorypool::lock::timeouts',
      'locks-timeouts', undef,
      'The number of locks per second that timed out' ],
  ['server::memorypool::lock::deadlocks',
      'locks-deadlocks', undef,
      'The number of deadlocks per second' ],
  ['server::sql::recompilations',
      'sql-recompilations', undef,
      'Re-Compilations per second' ],
  ['server::sql::initcompilations',
      'sql-initcompilations', undef,
      'Initial compilations per second' ],
  ['server::totalmemory',
      'total-server-memory', undef,
      'The amount of memory that SQL Server has allocated to it' ],
  ['server::memorypool::buffercache::hitratio',
      'mem-pool-data-buffer-hit-ratio', ['buffer-cache-hit-ratio'],
      'Data Buffer Cache Hit Ratio' ],


  ['server::memorypool::buffercache::lazywrites',
      'lazy-writes', undef,
      'Lazy writes per second' ],
  ['server::memorypool::buffercache::pagelifeexpectancy',
      'page-life-expectancy', undef,
      'Seconds a page is kept in memory before being flushed' ],
  ['server::memorypool::buffercache::freeliststalls',
      'free-list-stalls', undef,
      'Requests per second that had to wait for a free page' ],
  ['server::memorypool::buffercache::checkpointpages',
      'checkpoint-pages', undef,
      'Dirty pages flushed to disk per second. (usually by a checkpoint)' ],


  ['server::database::online',
      'database-online', undef,
      'Check if a database is online and accepting connections' ],
  ['server::database::databasefree',
      'database-free', undef,
      'Free space in database' ],
  ['server::database::backupage',
      'database-backup-age', ['backup-age'],
      'Elapsed time (in hours) since a database was last backed up' ],
  ['server::database::logbackupage',
      'database-logbackup-age', ['logbackup-age'],
      'Elapsed time (in hours) since a database transaction log was last backed up' ],
  ['server::database::autogrowths::file',
      'database-file-auto-growths', undef,
      'The number of File Auto Grow events (either data or log) in the last <n> minutes (use --lookback)' ],
  ['server::database::autogrowths::logfile',
      'database-logfile-auto-growths', undef,
      'The number of Log File Auto Grow events in the last <n> minutes (use --lookback)' ],
  ['server::database::autogrowths::datafile',
      'database-datafile-auto-growths', undef,
      'The number of Data File Auto Grow events in the last <n> minutes (use --lookback)' ],
  ['server::database::autoshrinks::file',
      'database-file-auto-shrinks', undef,
      'The number of File Auto Shrink events (either data or log) in the last <n> minutes (use --lookback)' ],
  ['server::database::autoshrinks::logfile',
      'database-logfile-auto-shrinks', undef,
      'The number of Log File Auto Shrink events in the last <n> minutes (use --lookback)' ],
  ['server::database::autoshrinks::datafile',
      'database-datafile-auto-shrinks', undef,
      'The number of Data File Auto Shrink events in the last <n> minutes (use --lookback)' ],
  ['server::database::dbccshrinks::file',
      'database-file-dbcc-shrinks', undef,
      'The number of DBCC File Shrink events (either data or log) in the last <n> minutes (use --lookback)' ],

  ['server::jobs::failed',
      'failed-jobs', undef,
      'The jobs which did not exit successful in the last <n> minutes (use --lookback)' ],
  ['server::jobs::enabled',
      'jobs-enabled', undef,
      'The jobs which are not enabled (scheduled)' ],

  ['server::sql',
      'sql', undef,
      'any sql command returning a single number' ],
  ['server::sqlruntime',
      'sql-runtime', undef,
      'the time an sql command needs to run' ],

  ['server::database::listdatabases',
      'list-databases', undef,
      'convenience function which lists all databases' ],
  ['server::database::datafile::listdatafiles',
      'list-datafiles', undef,
      'convenience function which lists all datafiles' ],
  ['server::memorypool::lock::listlocks',
      'list-locks', undef,
      'convenience function which lists all locks' ],
);

sub print_usage () {
  print <<EOUS;
  Usage:
    $PROGNAME [-v] [-t <timeout>] --hostname=<db server hostname>
        --username=<username> --password=<password> [--port <port>]
        --mode=<mode>
    $PROGNAME [-v] [-t <timeout>] --server=<db server>
        --username=<username> --password=<password>
        --mode=<mode>
    $PROGNAME [-h | --help]
    $PROGNAME [-V | --version]

  Options:
    --hostname
       the database server
    --port
       the database server's port
    --server
       the name of a predefined connection
    --currentdb
       the name of a database which is used as the current database
       for the connection. (don't use this parameter unless you
       know what you're doing)
    --username
       the mssql user
    --password
       the mssql user's password
    --kerberos
       where applicable, the Kerberos realm for authentication
       (this will switch to the ODBC driver!)
    --warning
       the warning range
    --critical
       the critical range
    --mode
       the mode of the plugin. select one of the following keywords:
EOUS
  my $longest = length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0]);
  my $format = "       %-".
  (length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0])).
  "s\t(%s)\n";
  foreach (@modes) {
    printf $format, $_->[1], $_->[3];
  }
  printf "\n";
  print <<EOUS;
    --name
       the name of the database etc depending on the mode.
    --name2
       if name is a sql statement, this statement would appear in
       the output and the performance data. This can be ugly, so 
       name2 can be used to appear instead.
    --regexp
       if this parameter is used, name will be interpreted as a 
       regular expression.
    --units
       one of %, KB, MB, GB. This is used for a better output of mode=sql
       and for specifying thresholds for mode=tablespace-free
    --offlineok
       if mode database-free finds a database which is currently offline,
       a WARNING is issued. If you don't want this and if offline databases
       are perfectly ok for you, then add --offlineok. You will get OK instead.
    --commit
       turns on autocommit for the dbd::sybase module

  Database-related modes check all databases in one run by default.
  If only a single database should be checked, use the --name parameter.
  The same applies to datafile-related modes.
  If an additional --regexp is added, --name's argument will be interpreted
  as a regular expression.
  The parameter --mitigation lets you classify the severity of an offline
  tablespace. 

  In mode sql you can url-encode the statement so you will not have to mess
  around with special characters in your Nagios service definitions.
  Instead of 
  --name="select count(*) from master..sysprocesses"
  you can say 
  --name=select%20count%28%2A%29%20from%20master%2E%2Esysprocesses
  For your convenience you can call check_mssql_health with the --encode
  option and it will encode the standard input.

  You can find the full documentation for this plugin at
  http://labs.consol.de/nagios/check_mssql_health or


EOUS
#
# --basis
#  one of rate, delta, value
  
}

sub print_help () {
  print "Copyright (c) 2009 Gerhard Lausser\n\n";
  print "\n";
  print "  Check various parameters of MSSQL databases \n";
  print "\n";
  print_usage();
  support();
}


sub print_revision ($$) {
  my $commandName = shift;
  my $pluginRevision = shift;
  $pluginRevision =~ s/^\$Revision: //;
  $pluginRevision =~ s/ \$\s*$//;
  print "$commandName ($pluginRevision)\n";
  print "This nagios plugin comes with ABSOLUTELY NO WARRANTY. You may redistribute\ncopies of this plugin under the terms of the GNU General Public License.\n";
}

sub support () {
  my $support='Send email to gerhard.lausser@consol.de if you have questions\nregarding use of this software. \nPlease include version information with all correspondence (when possible,\nuse output from the --version option of the plugin itself).\n';
  $support =~ s/@/\@/g;
  $support =~ s/\\n/\n/g;
  print $support;
}

sub contact_author ($$) {
  my $item = shift;
  my $strangepattern = shift;
  if ($commandline{verbose}) {
    printf STDERR
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n".
        "You found a line which is not recognized by %s\n".
        "This means, certain components of your system cannot be checked.\n".
        "Please contact the author %s and\nsend him the following output:\n\n".
        "%s /%s/\n\nThank you!\n".
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n",
            $PROGNAME, $CONTACT, $item, $strangepattern;
  }
}

%commandline = ();
my @params = (
    "timeout|t=i",
    "version|V",
    "help|h",
    "verbose|v",
    "debug|d",
    "hostname=s",
    "username=s",
    "password=s",
    "kerberos=s",
    "port=i",
    "server=s",
    "currentdb=s",
    "mode|m=s",
    "tablespace=s",
    "database=s",
    "datafile=s",
    "waitevent=s",
    "offlineok",
    "mitigation=s",
    "notemp",
    "name=s",
    "name2=s",
    "regexp",
    "perfdata",
    "warning=s",
    "critical=s",
    "dbthresholds:s",
    "absolute|a",
    "basis",
    "lookback|l=i",
    "environment|e=s%",
    "negate=s%",
    "method=s",
    "runas|r=s",
    "scream",
    "shell",
    "eyecandy",
    "encode",
    "units=s",
    "3",
    "statefilesdir=s",
    "with-mymodules-dyn-dir=s",
    "report=s",
    "commit",
    "labelformat=s",
    "selectedperfdata=s",
    "extra-opts:s");

if (! GetOptions(\%commandline, @params)) {
  print_help();
  exit $ERRORS{UNKNOWN};
}

if (exists $commandline{'extra-opts'}) {
  # read the extra file and overwrite other parameters
  my $extras = Extraopts->new(file => $commandline{'extra-opts'}, commandline => \%commandline);
  if (! $extras->is_valid()) {
    printf "extra-opts are not valid: %s\n", $extras->{errors};
    exit $ERRORS{UNKNOWN};
  } else {
    $extras->overwrite();
  }
}

if (exists $commandline{version}) {
  print_revision($PROGNAME, $REVISION);
  exit $ERRORS{OK};
}

if (exists $commandline{help}) {
  print_help();
  exit $ERRORS{OK};
} elsif (! exists $commandline{mode}) {
  printf "Please select a mode\n";
  print_help();
  exit $ERRORS{OK};
}

if ($commandline{mode} eq "encode") {
  my $input = <>;
  chomp $input;
  $input =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  printf "%s\n", $input;
  exit $ERRORS{OK};
}

if (exists $commandline{3}) {
  $ENV{NRPE_MULTILINESUPPORT} = 1;
}

if (exists $commandline{timeout}) {
  $TIMEOUT = $commandline{timeout};
}

if (exists $commandline{verbose}) {
  $DBD::MSSQL::Server::verbose = exists $commandline{verbose};
}

if (exists $commandline{scream}) {
#  $DBD::MSSQL::Server::hysterical = exists $commandline{scream};
}

if (exists $commandline{report}) {
  # short, long, html
} else {
  $commandline{report} = "long";
}

if (exists $commandline{commit}) {
  $commandline{commit} = 1;
} else {
  $commandline{commit} = 0;
}

if (exists $commandline{labelformat}) {
  # groundwork
} else {
  $commandline{labelformat} = "pnp4nagios";
}

if (exists $commandline{'with-mymodules-dyn-dir'}) {
  $DBD::MSSQL::Server::my_modules_dyn_dir = $commandline{'with-mymodules-dyn-dir'};
} else {
  $DBD::MSSQL::Server::my_modules_dyn_dir = '#MYMODULES_DYN_DIR#';
}


if (exists $commandline{environment}) {
  # if the desired environment variable values are different from
  # the environment of this running script, then a restart is necessary.
  # because setting $ENV does _not_ change the environment of the running script.
  foreach (keys %{$commandline{environment}}) {
    if ((! $ENV{$_}) || ($ENV{$_} ne $commandline{environment}->{$_})) {
      $needs_restart = 1;
      $ENV{$_} = $commandline{environment}->{$_};
      printf STDERR "new %s=%s forces restart\n", $_, $ENV{$_} 
          if $DBD::MSSQL::Server::verbose;
    }
  }
  # e.g. called with --runas dbnagio. shlib_path environment variable is stripped
  # during the sudo.
  # so the perl interpreter starts without a shlib_path. but --runas cares for
  # a --environment shlib_path=...
  # so setting the environment variable in the code above and restarting the 
  # perl interpreter will help it find shared libs
}

if (exists $commandline{runas}) {
  # remove the runas parameter
  # exec sudo $0 ... the remaining parameters
  $needs_restart = 1;
  # if the calling script has a path for shared libs and there is no --environment
  # parameter then the called script surely needs the variable too.
  foreach my $important_env (qw(LD_LIBRARY_PATH SHLIB_PATH 
      MSSQL_HOME TNS_ADMIN ORA_NLS ORA_NLS33 ORA_NLS10)) {
    if ($ENV{$important_env} && ! scalar(grep { /^$important_env=/ } 
        keys %{$commandline{environment}})) {
      $commandline{environment}->{$important_env} = $ENV{$important_env};
      printf STDERR "add important --environment %s=%s\n", 
          $important_env, $ENV{$important_env} if $DBD::MSSQL::Server::verbose;
    }
  }
}

if ($needs_restart) {
  my @newargv = ();
  my $runas = undef;
  if (exists $commandline{runas}) {
    $runas = $commandline{runas};
    delete $commandline{runas};
  }
  foreach my $option (keys %commandline) {
    if (grep { /^$option/ && /=/ } @params) {
      if (ref ($commandline{$option}) eq "HASH") {
        foreach (keys %{$commandline{$option}}) {
          push(@newargv, sprintf "--%s", $option);
          push(@newargv, sprintf "%s=%s", $_, $commandline{$option}->{$_});
        }
      } else {
        push(@newargv, sprintf "--%s", $option);
        push(@newargv, sprintf "%s", $commandline{$option});
      }
    } else {
      push(@newargv, sprintf "--%s", $option);
    }
  }
  if ($runas && ($> == 0)) {
    # this was not my idea. some people connect as root to their nagios clients.
    exec "su", "-c", sprintf("%s %s", $0, join(" ", @newargv)), "-", $runas;
  } elsif ($runas) {
    exec "sudo", "-S", "-u", $runas, $0, @newargv;
  } else {
    exec $0, @newargv;  
    # this makes sure that even a SHLIB or LD_LIBRARY_PATH are set correctly
    # when the perl interpreter starts. Setting them during runtime does not
    # help loading e.g. libclntsh.so
  }
  exit;
}

if (exists $commandline{mitigation}) {
  if ($commandline{mitigation} eq "ok") {
    $commandline{mitigation} = 0;
  } elsif ($commandline{mitigation} eq "warning") {
    $commandline{mitigation} = 1;
  } elsif ($commandline{mitigation} eq "critical") {
    $commandline{mitigation} = 2;
  } elsif ($commandline{mitigation} eq "unknown") {
    $commandline{mitigation} = 3;
  }
}

if (exists $commandline{shell}) {
  # forget what you see here.
  system("/bin/sh");
}

if (! exists $commandline{statefilesdir}) {
  if (exists $ENV{OMD_ROOT}) {
    $commandline{statefilesdir} = $ENV{OMD_ROOT}."/var/tmp/check_mssql_health";
  } else {
    $commandline{statefilesdir} = $STATEFILESDIR;
  }
}

if (exists $commandline{name}) {
  if ($^O =~ /MSWin/ && $commandline{name} =~ /^'(.*)'$/) {
    # putting arguments in single ticks under Windows CMD leaves the ' intact
    # we remove them
    $commandline{name} = $1;
  }
  # objects can be encoded like an url
  # with s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  if (($commandline{mode} ne "sql") || 
      (($commandline{mode} eq "sql") &&
       ($commandline{name} =~ /select%20/i))) { # protect ... like '%cac%' ... from decoding
    $commandline{name} =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
  }
  if ($commandline{name} =~ /^0$/) {
    # without this, $params{selectname} would be treated like undef
    $commandline{name} = "00";
  } 
}

$SIG{'ALRM'} = sub {
  printf "UNKNOWN - %s timed out after %d seconds\n", $PROGNAME, $TIMEOUT;
  exit $ERRORS{UNKNOWN};
};
alarm($TIMEOUT);

my $nagios_level = $ERRORS{UNKNOWN};
my $nagios_message = "";
my $perfdata = "";
my $racmode = 0;
if ($commandline{mode} =~ /^rac-([^\-.]+)/) {
  $racmode = 1;
  $commandline{mode} =~ s/^rac\-//g;
}
if ($commandline{mode} =~ /^my-([^\-.]+)/) {
  my $param = $commandline{mode};
  $param =~ s/\-/::/g;
  push(@modes, [$param, $commandline{mode}, undef, 'my extension']);
} elsif ((! grep { $commandline{mode} eq $_ } map { $_->[1] } @modes) &&
    (! grep { $commandline{mode} eq $_ } map { defined $_->[2] ? @{$_->[2]} : () } @modes)) {
  printf "UNKNOWN - mode %s\n", $commandline{mode};
  print_usage();
  exit 3;
}

# Kerberos environment initialization
if ($commandline{kerberos}) {
  use Authen::Krb5;
  my $krb_context=Authen::Krb5::init_context();
  my $krb_userp=Authen::Krb5::parse_name($commandline{username});
  my $krb_credcache=Authen::Krb5::cc_default();
  my $krb_servicep=Authen::Krb5::build_principal_ext(Authen::Krb5::parse_name("krbtgt"));

  my $kerberos_result = Authen::Krb5::get_in_tkt_with_password($krb_userp, $krb_servicep, $commandline{password}, $krb_credcache);
  if (! $kerberos_result) {
    printf "UNKNOWN - Kerberos authentication failed for user ".$commandline{username}.": ".Authen::Krb5::error()."\n";
    exit 3;
  }
}

my %params = (
    timeout => $TIMEOUT,
    mode => (
        map { $_->[0] } 
        grep {
           ($commandline{mode} eq $_->[1]) || 
           ( defined $_->[2] && grep { $commandline{mode} eq $_ } @{$_->[2]}) 
        } @modes
    )[0],
    cmdlinemode => $commandline{mode},
    method => $commandline{method} ||
        $ENV{NAGIOS__SERVICEMSSQL_METH} ||
        $ENV{NAGIOS__HOSTMSSQL_METH} || 'dbi',
    hostname => $commandline{hostname}  || 
        $ENV{NAGIOS__SERVICEMSSQL_HOST} ||
        $ENV{NAGIOS__HOSTMSSQL_HOST},
    username => $commandline{username} || 
        $ENV{NAGIOS__SERVICEMSSQL_USER} ||
        $ENV{NAGIOS__HOSTMSSQL_USER},
    password => $commandline{password} || 
        $ENV{NAGIOS__SERVICEMSSQL_PASS} ||
        $ENV{NAGIOS__HOSTMSSQL_PASS},
    kerberos => $commandline{kerberos},
    port => $commandline{port} || 
        $ENV{NAGIOS__SERVICEMSSQL_PORT} ||
        $ENV{NAGIOS__HOSTMSSQL_PORT},
    server => $commandline{server}  || 
        $ENV{NAGIOS__SERVICEMSSQL_SERVER} ||
        $ENV{NAGIOS__HOSTMSSQL_SERVER},
    currentdb => $commandline{currentdb}  || 
        $ENV{NAGIOS__SERVICEMSSQL_CURRENTDB} ||
        $ENV{NAGIOS__HOSTMSSQL_CURRENTDB},
    warningrange => $commandline{warning},
    criticalrange => $commandline{critical},
    dbthresholds => $commandline{dbthresholds},
    absolute => $commandline{absolute},
    lookback => $commandline{lookback} || 30,
    tablespace => $commandline{tablespace},
    database => $commandline{database},
    datafile => $commandline{datafile},
    offlineok => $commandline{offlineok},
    mitigation => $commandline{mitigation},
    basis => $commandline{basis},
    offlineok => $commandline{offlineok},
    mitigation => $commandline{mitigation},
    notemp => $commandline{notemp},
    selectname => $commandline{name} || $commandline{tablespace} || $commandline{datafile},
    regexp => $commandline{regexp},
    name => $commandline{name},
    name2 => $commandline{name2} || $commandline{name},
    units => $commandline{units},
    eyecandy => $commandline{eyecandy},
    statefilesdir => $commandline{statefilesdir},
    verbose => $commandline{verbose},
    report => $commandline{report},
    commit => $commandline{commit},
    labelformat => $commandline{labelformat},
    selectedperfdata => $commandline{selectedperfdata},
    negate => $commandline{negate},
);

my $server = undef;

$server = DBD::MSSQL::Server->new(%params);
$server->nagios(%params);
$server->calculate_result();
$nagios_message = $server->{nagios_message};
$nagios_level = $server->{nagios_level};
$perfdata = $server->{perfdata};

printf "%s - %s", $ERRORCODES{$nagios_level}, $nagios_message;
printf " | %s", $perfdata if $perfdata;
printf "\n";
exit $nagios_level;
