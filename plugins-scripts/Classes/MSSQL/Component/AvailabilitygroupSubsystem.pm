package Classes::MSSQL::Component::AvailabilitygroupSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my ($self) = @_;
  my $sql = undef;
  my $allfilter = sub {
    my ($o) = @_;
    $self->filter_name($o->{name});
  };
  if ($self->mode =~ /server::availabilitygroup::status/) {
    if ($self->version_is_minimum("11.x")) {
      my $columns = [qw(group_id name primary_replica primary_recovery_health_desc
          secondary_recovery_health_desc synchronization_health_desc)];
      my $avgfilter = sub {
        my $o = shift;
        $self->filter_name($o->{name});
      };
      my $sql = q{
        SELECT
          [ag].[group_id],
          [ag].[name],
          [gs].[primary_replica],
          [gs].[primary_recovery_health_desc],
          [gs].[secondary_recovery_health_desc],
          [gs].[synchronization_health_desc]
        FROM
          [master].[sys].[availability_groups]
        AS
          [ag]
        INNER JOIN
          [master].[sys].[dm_hadr_availability_group_states]
        AS
          [gs]
        ON
          [ag].[group_id] = [gs].[group_id]
      };
      my $resql = q{
        select * from [master].[sys].[dm_hadr_availability_replica_states]
      };
      my $recolumns = [qw(replica_id group_id is_local role role_desc operational_state
          operational_state_desc connected_state connected_state_desc recovery_health
          recovery_health_desc synchronization_health synchronization_health_desc
          last_connect_error_number last_connect_error_description
          last_connect_error_timestamp)];
      $self->get_db_tables([
          ['avgroups', $sql, 'Classes::MSSQL::Component::AvailabilitygroupSubsystem::Availabilitygroup', $avgfilter, $columns],
          # vielleicht spaeter mal, um mehr details zu holen
          #['regroups', $resql, 'Classes::MSSQL::Component::AvailabilitygroupSubsystem::Replicastate', $avgfilter, $recolumns],
      ]);
    } else {
      $self->add_ok(sprintf 'your version %s is too old, availability group monitoring is not possible', $self->get_variable('version'));
    }
  }
}


package Classes::MSSQL::Component::AvailabilitygroupSubsystem::Replicastate;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

package Classes::MSSQL::Component::AvailabilitygroupSubsystem::Availabilitygroup;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub check {
  my ($self) = @_;
  if ($self->mode =~ /server::availabilitygroup::status/) {
    $self->add_info(sprintf 'availability group %s has synch. status %s', $self->{name},
        lc $self->{synchronization_health_desc});
    if ($self->{synchronization_health_desc} eq 'HEALTHY') {
      $self->add_ok();
    } elsif ($self->{synchronization_health_desc} eq 'PARTIALLY_HEALTHY') {
      $self->add_warning();
    } elsif ($self->{synchronization_health_desc} eq 'NOT_HEALTHY') {
      $self->add_critical();
    } else {
      $self->add_unknown();
    }
  }
}

