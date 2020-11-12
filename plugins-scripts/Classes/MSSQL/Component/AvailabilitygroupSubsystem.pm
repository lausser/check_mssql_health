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
      my $avgfilter = sub {
        my $o = shift;
        $self->filter_name($o->{name});
      };
      my $columnsag = [qw(server_name group_id name
          primary_replica primary_recovery_health_desc
          secondary_recovery_health_desc synchronization_health_desc
      )];
      # returns 1 line with availability group
      my $sqlag = q{
        SELECT
          @@ServerName,
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
      my $columnsrs = [qw(server_name group_id name database_name
          synchronization_state_desc replica_id group_database_id
      )];
      # returns n lines with availability group +
      #   database (probably always the same, i never saw different records) +
      #   replica_id (which is unique), so name+replica_id are unique here
      my $sqlrs = q{
        SELECT
          @@ServerName,
          [ag].[group_id],
          [ag].[name],
          [db].[name] AS Databasename,
          [rs].[synchronization_state_desc],
          [rs].[replica_id],
          [rs].[group_database_id]
        FROM [master].[sys].[availability_groups] AS [ag]
        INNER JOIN [master].[sys].[dm_hadr_availability_group_states] AS [gs] ON [ag].[group_id] = [gs].[group_id]
        INNER JOIN [master].[sys].[dm_hadr_database_replica_states] AS [rs] ON [ag].[group_id] = [rs].[group_id]
        INNER JOIN [master].[sys].[databases] AS [db] ON [rs].[database_id] = [db].[database_id]
      };

      $self->get_db_tables([
          ['avgroups', $sqlag, 'Classes::MSSQL::Component::AvailabilitygroupSubsystem::Availabilitygroup', $avgfilter, $columnsag],
          ['replicas', $sqlrs, 'Monitoring::GLPlugin::DB::TableItem', $avgfilter, $columnsrs],
      ]);
      foreach my $avgroup (@{$self->{avgroups}}) {
        foreach my $replica (@{$self->{replicas}}) {
          if ($avgroup->{name} eq $replica->{name}) {
            push(@{$avgroup->{replicas}}, $replica);
          }
        }
      }
      delete $self->{replicas};
    }
  }
}

sub check {
  my ($self) = @_;
  if ($self->mode =~ /server::availabilitygroup::status/) {
    if ($self->version_is_minimum("11.x")) {
      if (! scalar(@{$self->{avgroups}})) {
        $self->add_ok("no availability groups found");
      } else {
        foreach (@{$self->{avgroups}}) {
          $_->check();
        }
      }
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

sub finish {
  my ($self) = @_;
  $self->{replicas} = [];
}

sub check {
  my ($self) = @_;
  if ($self->mode =~ /server::availabilitygroup::status/) {
    $self->add_info(
        sprintf 'availability group %s synchronization is %s',
        $self->{name}, lc $self->{synchronization_health_desc}
    );
    if (lc $self->{server_name} ne lc $self->{primary_replica}) {
      $self->add_ok(sprintf 'this is is a secondary replica of group %s. for a reliable status you have to ask the primary replica',
          $self->{name});
    } elsif ($self->{synchronization_health_desc} eq 'HEALTHY') {
      my $nok = scalar(grep { $_->{synchronization_state_desc} !~ /^SYNCHRONIZ/ } @{$self->{replicas}});
      if (! $nok) {
        $self->add_ok();
      } else {
        foreach my $replica (@{$self->{replicas}}) {
          if ($replica->{synchronization_state_desc} ne 'SYNCHRONIZING' &&
              $replica->{synchronization_state_desc} ne 'SYNCHRONIZED') {
            $self->add_info(sprintf 'replica %s@%s has synchronization state %s',
                $replica->{replica_id}, $self->{name},
                lc $replica->{synchronization_state_desc}
            );
            $self->add_critical();
          }
        }
      }
    } elsif ($self->{synchronization_health_desc} eq 'PARTIALLY_HEALTHY') {
      $self->add_warning();
    } elsif ($self->{synchronization_health_desc} eq 'NOT_HEALTHY') {
      $self->add_critical();
    } else {
      $self->add_unknown();
    }
  }
}

