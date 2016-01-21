package Classes::APS::Component::AlertSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::aps::alert::active/) {
    my $columns = ['node_name', 'component_name', 'component_instance_id',
        'name', 'state', 'severity', 'type', 'status', 'create_time'];
    my $sql = q{
        SELECT 
            NodeName, 
            ComponentName, 
            ComponentInstanceId,
            AlertName,
            AlertState,
            AlertSeverity,
            AlertType,
            AlertStatus,
            CreateTime
        FROM
            SQL_ADMIN.[dbo].current_alerts_dc
        -- WHERE
        --     AlertSeverity <> 'Informational'
        ORDER BY
            CreateTime DESC
    };
    $self->get_db_tables([
        ['alerts', $sql, 'Classes::APS::Component::AlertSubsystem::Alert', sub { my $o = shift; $self->filter_name($o->{name}); }, $columns],
    ]);
  }
}

sub check {
  my $self = shift;
  $self->add_info('checking alerts');
  if ($self->mode =~ /server::aps::alert::active/) {
    $self->set_thresholds(
        metric => 'active_alerts',
        warning => 0,
        critical => 0,
    );
    my @active_alerts = grep { $_->{severity} ne "Informational" } @{$self->{alerts}};
    if (scalar(@active_alerts)) {
      $self->add_message(
          $self->check_thresholds(metric => 'active_alerts', value => scalar(@active_alerts)),
          sprintf '%d active alerts', scalar(@{$self->{alerts}})
      );
      foreach (@active_alerts) {
        $self->add_ok($_->{message});
      }
    } else {
      $self->add_ok("no active alerts");
    }
  } else {
    $self->SUPER::check();
  }
}

package Classes::APS::Component::AlertSubsystem::Alert;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub finish {
  my $self = shift;
  my $columns = ['node_name', 'component_name', 'component_instance_id',
      'name', 'state', 'severity', 'type', 'status', 'create_time'];
  $self->{message} = join(",", map { $self->{$_} } @{$columns});
}

sub check {
  my $self = shift;
  if ($self->{severity} ne "Informational") {
    $self->add_critical($self->{message});
  }
}
