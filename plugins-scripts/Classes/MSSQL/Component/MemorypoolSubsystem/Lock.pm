package Classes::MSSQL::Component::MemorypoolSubsystem::Lock;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub check {
  my $self = shift;
  if ($self->mode =~ /server::memorypool::lock::waits/) {
    $self->get_perf_counters([
        ["waits", "SQLServer:Locks", "Lock Waits/sec", $self->{name}],
    ]);
    return if $self->check_messages();
    my $label = $self->{name}.'_waits_per_sec';
    $self->set_thresholds(
        metric => $label,
        warning => 100, critical => 500
    );
    $self->add_message($self->check_thresholds(
        metric => $label,
        value => $self->{waits_per_sec},
    ), sprintf "%.4f lock waits / sec for %s",
        $self->{waits_per_sec}, $self->{name}
    );
    $self->add_perfdata(
        label => $label,
        value => $self->{waits_per_sec},
    );
  } elsif ($self->mode =~ /^server::memorypool::lock::timeouts/) {
    $self->get_perf_counters([
        ["timeouts", "SQLServer:Locks", "Lock Timeouts/sec", $self->{name}],
    ]);
    return if $self->check_messages();
    my $label = $self->{name}.'_timeouts_per_sec';
    $self->set_thresholds(
        metric => $label,
        warning => 1, critical => 5
    );
    $self->add_message($self->check_thresholds(
        metric => $label,
        value => $self->{timeouts_per_sec},
    ), sprintf "%.4f lock timeouts / sec for %s",
        $self->{timeouts_per_sec}, $self->{name}
    );
    $self->add_perfdata(
        label => $label,
        value => $self->{timeouts_per_sec},
    );
  } elsif ($self->mode =~ /^server::memorypool::lock::deadlocks/) {
    $self->get_perf_counters([
        ["deadlocks", "SQLServer:Locks", "Number of Deadlocks/sec", $self->{name}],
    ]);
    return if $self->check_messages();
    my $label = $self->{name}.'_deadlocks_per_sec';
    $self->set_thresholds(
        metric => $label,
        warning => 1, critical => 5
    );
    $self->add_message($self->check_thresholds(
        metric => $label,
        value => $self->{deadlocks_per_sec},
    ), sprintf "%.4f lock deadlocks / sec for %s",
        $self->{deadlocks_per_sec}, $self->{name}
    );
    $self->add_perfdata(
        label => $label,
        value => $self->{deadlocks_per_sec},
    );
  }
}


