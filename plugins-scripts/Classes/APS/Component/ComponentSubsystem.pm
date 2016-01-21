package Classes::APS::Component::ComponentSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::aps::component::failed/) {
    my $columns = ['node_name', 'name', 'instance_id',
        'property_name', 'property_value', 'update_time'];
    my $sql = q{
        SELECT
            NodeName,
            ComponentName,
            ComponentInstanceId,
            ComponentPropertyName,
            ComponentPropertyValue,
            UpdateTime
        FROM
            SQL_ADMIN.[dbo].status_components_dc
        WHERE
            ComponentPropertyValue NOT IN ('OK','UNKNOWN')
        ORDER BY
            ComponentName desc";
    };
    $self->get_db_tables([
        ['components', $sql, 'Classes::APS::Component::ComponentSubsystem::Component', sub { my $o = shift; $self->filter_name($o->{name}); }, $columns],
    ]);
  }
}

sub check {
  my $self = shift;
  $self->add_info('checking components');
  if ($self->mode =~ /server::aps::component::failed/) {
    if (@{$self->{components}}) {
      $self->add_critical(
        sprintf '%d failed components', scalar(@{$self->{components}})
      );
      $self->SUPER::check();
    } else {
      $self->add_ok("no failed components");
    }
  } else {
    $self->SUPER::check();
  }
}

package Classes::APS::Component::ComponentSubsystem::Component;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub finish {
  my $self = shift;
  my $columns = ['node_name', 'name', 'instance_id',
      'property_name', 'property_value', 'update_time'];
  $self->{message} = join(",", map { $self->{$_} } @{$columns});
}

sub check {
  my $self = shift;
  if ($self->{property_value} !~ /^(OK|UNKNOWN)$/) {
    $self->add_critical($self->{message});
  }
}

