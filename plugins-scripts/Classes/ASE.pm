package Classes::ASE;
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
      q{ SELECT SUSER_NAME() }
  ));
  $self->set_variable("maxpagesize", $self->fetchrow_array(
      q{ SELECT @@MAXPAGESIZE }
  ));
  if ($self->mode =~ /^server::connectedsessions/) {
    my $connectedusers = $self->fetchrow_array(q{
        SELECT
          COUNT(*)
        FROM
          master..sysprocesses
        WHERE
          hostprocess IS NOT NULL AND program_name != 'JS Agent'
      });
    if (! defined $connectedsessions) {
      $self->add_unknown("unable to count connected sessions");
    } else {
      $self->set_thresholds(warning => 50, critical => 80);
      $self->add_message($self->check_thresholds($connectedsessions),
          sprintf "%d connected users", $connectedsessions);
      $self->add_perfdata(
          label => "connected_sessions",
          value => $connectedsessions
      );
    }
  } elsif ($self->mode =~ /^server::connectedusers/) {
    my $connectedusers = $self->fetchrow_array(q{
        SELECT
          COUNT(DISTINCT loginame)
        FROM
          master..sysprocesses
        WHERE
          hostprocess IS NOT NULL AND program_name != 'JS Agent'
      });
    if (! defined $connectedusers) {
      $self->add_unknown("unable to count connected users");
    } else {
      $self->set_thresholds(warning => 50, critical => 80);
      $self->add_message($self->check_thresholds($connectedusers),
          sprintf "%d connected users", $connectedusers);
      $self->add_perfdata(
          label => "connected_users",
          value => $connectedusers
      );
    }
  } elsif ($self->mode =~ /^server::database/) {
    $self->analyze_and_check_database_subsystem("Classes::ASE::Component::DatabaseSubsystem");
    $self->reduce_messages_short();
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
          WHERE name = 'check_ase_health_thresholds'
      };
    } else {
      $find_sql = q{
          SELECT name FROM sysobjects
          WHERE name = 'check_ase_health_thresholds'
      };
    }
    if ($self->{handle}->fetchrow_array($find_sql)) {
      $self->{has_threshold_table} = 'check_ase_health_thresholds';
    } else {
      $self->{has_threshold_table} = undef;
    }
  }
  return $self->{has_threshold_table};
}


