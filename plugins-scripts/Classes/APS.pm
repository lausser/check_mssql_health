package Classes::APS;
our @ISA = qw(Classes::Sybase);

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;
our $AUTOLOAD;


sub init {
  my $self = shift;
  $self->set_variable("dbuser", $self->fetchrow_array(
      q{ SELECT SYSTEM_USER }
  ));
  if ($self->mode =~ /^server::aps::component/) {
    $self->analyze_and_check_component_subsystem("Classes::APS::Component::ComponentSubsystem");
  } elsif ($self->mode =~ /^server::aps::alert/) {
    $self->analyze_and_check_alert_subsystem("Classes::APS::Component::AlertSubsystem");
  } elsif ($self->mode =~ /^server::aps::disk/) {
    $self->analyze_and_check_alert_subsystem("Classes::APS::Component::DiskSubsystem");
  } else {
    $self->no_such_mode();
  }
}

sub has_threshold_table {
  my $self = shift;
  if (! exists $self->{has_threshold_table}) {
    my $find_sql;
    if ($self->version_is_minimum("9.x")) {
      $find_sql = q{
          SELECT name FROM sys.objects
          WHERE name = 'check_mssql_health_thresholds'
      };
    } else {
      $find_sql = q{
          SELECT name FROM sysobjects
          WHERE name = 'check_mssql_health_thresholds'
      };
    }
    if ($self->{handle}->fetchrow_array($find_sql)) {
      $self->{has_threshold_table} = 'check_mssql_health_thresholds';
    } else {
      $self->{has_threshold_table} = undef;
    }
  }
  return $self->{has_threshold_table};
}

