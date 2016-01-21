package Classes::Sybase;
our @ISA = qw(Classes::Device);

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;
our $AUTOLOAD;


sub check_version {
  my $self = shift;
  #$self->{version} = $self->{handle}->fetchrow_array(
  #    q{ SELECT SERVERPROPERTY('productversion') });
  # @@VERSION:
  # Variant1:
  # Adaptive Server Enterprise/15.5/EBF 18164 SMP ESD#2/P/x86_64/Enterprise Linux/asear155/2514/64-bit/FBO/Wed Aug 25 11:17:26 2010
  # Variant2:
  # Microsoft SQL Server 2005 - 9.00.1399.06 (Intel X86)
  #    Oct 14 2005 00:33:37
  #    Copyright (c) 1988-2005 Microsoft Corporation
  #    Enterprise Edition on Windows NT 5.2 (Build 3790: Service Pack 2)
  map {
      $self->set_variable("os", "Linux") if /Linux/;
      $self->set_variable("version", $1) if /Adaptive Server Enterprise\/([\d\.]+)/;
      $self->set_variable("os", $1) if /Windows (.*)/;
      $self->set_variable("version", $1) if /SQL Server.*\-\s*([\d\.]+)/;
      $self->set_variable("product", "ASE") if /Adaptive Server/;
      $self->set_variable("product", "MSSQL") if /SQL Server/;
      $self->set_variable("product", "APS") if /Parallel Data Warehouse/;
  } $self->fetchrow_array(q{ SELECT @@VERSION });
}

sub create_statefile {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  $extension .= $params{name} ? '_'.$params{name} : '';
  if ($self->opts->can('hostname') && $self->opts->hostname) {
    $extension .= '_'.$self->opts->hostname;
    $extension .= '_'.$self->opts->port;
  }
  if ($self->opts->can('server') && $self->opts->server) {
    $extension .= '_'.$self->opts->server;
  }
  if ($self->opts->mode eq 'sql' && $self->opts->username) {
    $extension .= '_'.$self->opts->username;
  }
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  return sprintf "%s/%s%s", $self->statefilesdir(),
      $self->opts->mode, lc $extension;
}

sub add_dbi_funcs {
  my $self = shift;
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::CSF::create_statefile'} = \&{"Classes::Sybase::create_statefile"};
  }
}

