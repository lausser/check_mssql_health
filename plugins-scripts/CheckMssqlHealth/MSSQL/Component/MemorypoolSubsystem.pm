package Classes::MSSQL::Component::MemorypoolSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::memorypool::lock/) {
    my $columns = ['name'];
    my @locks = $self->get_instance_names('SQLServer:Locks');
    @locks = map {
      "'".$_."'";
    } map {
      s/\s*$//g; $_;
    } map {
      $_->[0];
    } @locks;
    $sql = join(" UNION ALL ", map { "SELECT ".$_ } @locks);
    $self->get_db_tables([
        ['locks', $sql, 'Classes::MSSQL::Component::MemorypoolSubsystem::Lock', sub { my $o = shift; $self->filter_name($o->{name}) }, $columns],
    ]);      
  } elsif ($self->mode =~ /server::memorypool::buffercache/) {
    $self->analyze_and_check_buffercache_subsystem("Classes::MSSQL::Component::MemorypoolSubsystem::Buffercache");
  }
}

sub check {
  my $self = shift;
  $self->add_info('checking memorypools');
  if ($self->mode =~ /server::memorypool::lock::listlocks$/) {
    foreach (@{$self->{locks}}) {
      printf "%s\n", $_->{name};
    }
    $self->add_ok("have fun");
  } else {
    $self->SUPER::check();
  }
}

