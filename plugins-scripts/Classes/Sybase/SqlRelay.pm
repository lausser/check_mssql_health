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
    $self->set_timeout_alarm($self->opts->timeout - 1, sub {
      die "alrm";
    });  
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    if ($self->{handle} = DBI->connect(
        $dsn,
        $self->opts->username,
        $self->opts->password,
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
  } else {
    $self->set_timeout_alarm($self->opts->timeout - ($self->{tac} - $self->{tic}));
  }
}

