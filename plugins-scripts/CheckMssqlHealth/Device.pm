package Classes::Device;
our @ISA = qw(Monitoring::GLPlugin::DB);
use strict;


sub classify {
  my $self = shift;
  if ($self->opts->method eq "dbi") {
    bless $self, "Classes::Sybase::DBI";
    if ((! $self->opts->hostname && ! $self->opts->server) ||
        ! $self->opts->username || ! $self->opts->password) {
      $self->add_unknown('Please specify hostname or server, username and password');
    }
    if (! eval "require DBD::Sybase") {
      $self->add_critical('could not load perl module DBD::Sybase');
    }
  } elsif ($self->opts->method eq "sqsh") {
    bless $self, "Classes::Sybase::Sqsh";
    if ((! $self->opts->hostname && ! $self->opts->server) ||
        ! $self->opts->username || ! $self->opts->password) {
      $self->add_unknown('Please specify hostname or server, username and password');
    }
  } elsif ($self->opts->method eq "sqlcmd") {
    bless $self, "Classes::Sybase::Sqlcmd";
    if ((! $self->opts->hostname && ! $self->opts->server) ||
        ! $self->opts->username || ! $self->opts->password) {
      $self->add_unknown('Please specify hostname or server, username and password');
    }
  } elsif ($self->opts->method eq "sqlrelay") {
    bless $self, "Classes::Sybase::Sqlrelay";
    if ((! $self->opts->hostname && ! $self->opts->server) ||
        ! $self->opts->username || ! $self->opts->password) {
      $self->add_unknown('Please specify hostname or server, username and password');
    }
    if (! eval "require DBD::SQLRelay") {
      $self->add_critical('could not load perl module SQLRelay');
    }
  }
  if (! $self->check_messages()) {
    $self->check_connect();
    if (! $self->check_messages()) {
      $self->add_dbi_funcs();
      $self->check_version();
      my $class = ref($self);
      $class =~ s/::Sybase::/::MSSQL::/ if $self->get_variable("product") eq "MSSQL";
      $class =~ s/::Sybase::/::ASE::/ if $self->get_variable("product") eq "ASE";
      $class =~ s/::Sybase::/::APS::/ if $self->get_variable("product") eq "APS";
      bless $self, $class;
      $self->add_dbi_funcs();
      if ($self->opts->mode =~ /^my-/) {
        $self->load_my_extension();
      }
    }
  }
}

