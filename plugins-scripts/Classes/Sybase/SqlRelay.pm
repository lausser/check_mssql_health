package Classes::Sybase::SqlRelay;
our @ISA = qw(Classes::Sybase Monitoring::GLPlugin::DB::DBI);
use strict;
use File::Basename;

sub check_connect {
  my $self = shift;
  my $stderrvar;
  my $dbi_options = { RaiseError => 1, AutoCommit => $self->opts->commit, PrintError => 1 };
  my $dsn = "DBI:SQLRelay:";
  $dsn .= sprintf ";host=%s", $self->opts->hostname;
  $dsn .= sprintf ";port=%s", $self->opts->port;
  $dsn .= sprintf ";socket=%s", $self->opts->socket;
  if ($self->opts->currentdb) {
    if (index($self->opts->currentdb,"-") != -1) {
      $dsn .= sprintf ";database=\"%s\"", $self->opts->currentdb;
    } else {
      $dsn .= sprintf ";database=%s", $self->opts->currentdb;
    }
  }
  $self->set_variable("dsn", $dsn);
  eval {
    require DBI;
    use POSIX ':signal_h';
    if ($^O =~ /MSWin/) {
      local $SIG{'ALRM'} = sub {
        die "alrm";
      };
    } else {
      my $mask = POSIX::SigSet->new( SIGALRM );
      my $action = POSIX::SigAction->new(
          sub { die "alrm"; }, $mask
      );
      my $oldaction = POSIX::SigAction->new();
      sigaction(SIGALRM ,$action ,$oldaction );
    }
    alarm($self->opts->timeout - 1); # 1 second before the global unknown timeout
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    if ($self->{handle} = DBI->connect(
        $dsn,
        $self->opts->username,
        $self->decode_password($self->opts->password),
        $dbi_options)) {
      $Monitoring::GLPlugin::DB::session = $self->{handle};
    }
    $self->{tac} = Time::HiRes::time();
    *STDERR = *SAVEERR;
  };
  if ($@) {
    if ($@ =~ /alrm/) {
      $self->add_critical(
          sprintf "connection could not be established within %s seconds",
          $self->opts->timeout);
    } else {
      $self->add_critical($@);
    }
  } elsif (! $self->{handle}) {
    $self->add_critical("no connection");
  }
}

