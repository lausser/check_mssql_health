package Classes::MSSQL::Component::MemorypoolSubsystem::Buffercache;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  if ($self->mode =~ /server::memorypool::buffercache::hitratio/) {
    # https://social.msdn.microsoft.com/Forums/sqlserver/en-US/263e847a-fd9d-4fbf-a8f0-2aed9565aca1/buffer-hit-ratio-over-100?forum=sqldatabaseengine
    $self->get_perf_counters([
        ['cnthitratio', 'SQLServer:Buffer Manager', 'Buffer cache hit ratio'],
        ['cnthitratiobase', 'SQLServer:Buffer Manager', 'Buffer cache hit ratio base'],
    ]);
    my $sql = q{
        SELECT
            (a.cntr_value * 1.0 / b.cntr_value) * 100.0 AS BufferCacheHitRatio
        FROM
            sys.dm_os_performance_counters  a
        JOIN  (
            SELECT
                cntr_value, OBJECT_NAME 
            FROM
                sys.dm_os_performance_counters  
            WHERE
                counter_name = 'Buffer cache hit ratio base'
            AND
                object_name = 'SQLServer:Buffer Manager'
        ) b
        ON
            a.OBJECT_NAME = b.OBJECT_NAME
        WHERE
            a.counter_name = 'Buffer cache hit ratio'
        AND
            a.OBJECT_NAME = 'SQLServer:Buffer Manager'
    };
    my $instance = $self->get_variable("servicename");
    $sql =~ s/SQLServer/$instance/g;
    $self->{buffer_cache_hit_ratio} = $self->fetchrow_array($sql);
    $self->protect_value('buffer_cache_hit_ratio', 'buffer_cache_hit_ratio', 'percent');
  } elsif ($self->mode =~ /server::memorypool::buffercache::lazywrites/) {
    $self->get_perf_counters([
        ['lazy_writes', 'SQLServer:Buffer Manager', 'Lazy writes/sec'],
    ]);
    # -> lazy_writes_per_sec
  } elsif ($self->mode =~ /server::memorypool::buffercache::pagelifeexpectancy/) {
    $self->get_perf_counters([
        ['page_life_expectancy', 'SQLServer:Buffer Manager', 'Page life expectancy'],
    ]);
  } elsif ($self->mode =~ /server::memorypool::buffercache::freeliststalls/) {
    $self->get_perf_counters([
        ['free_list_stalls', 'SQLServer:Buffer Manager', 'Free list stalls/sec'],
    ]);
  } elsif ($self->mode =~ /server::memorypool::buffercache::checkpointpages/) {
    $self->get_perf_counters([
        ['checkpoint_pages', 'SQLServer:Buffer Manager', 'Checkpoint pages/sec'],
    ]);
  }
}

sub check {
  my $self = shift;
  return if $self->check_messages();
  if ($self->mode =~ /server::memorypool::buffercache::hitratio/) {
    $self->set_thresholds(
        warning => '90:', critical => '80:'
    );
    $self->add_message(
        $self->check_thresholds($self->{buffer_cache_hit_ratio}),
        sprintf "buffer cache hit ratio is %.2f%%", $self->{buffer_cache_hit_ratio}
    );
    $self->add_perfdata(
        label => 'buffer_cache_hit_ratio',
        value => $self->{buffer_cache_hit_ratio},
        uom => '%',
    );
  } elsif ($self->mode =~ /server::memorypool::buffercache::lazywrites/) {
    $self->set_thresholds(
        warning => 20, critical => 40,
    );
    $self->add_message(
        $self->check_thresholds($self->{lazy_writes_per_sec}),
        sprintf "%.2f lazy writes per second", $self->{lazy_writes_per_sec}
    );
    $self->add_perfdata(
        label => 'lazy_writes_per_sec',
        value => $self->{lazy_writes_per_sec},
    );
  } elsif ($self->mode =~ /server::memorypool::buffercache::pagelifeexpectancy/) {
    $self->set_thresholds(
        warning => '300:', critical => '180:',
    );
    $self->add_message(
        $self->check_thresholds($self->{page_life_expectancy}),
        sprintf "page life expectancy is %d seconds", $self->{page_life_expectancy}
    );
    $self->add_perfdata(
        label => 'page_life_expectancy',
        value => $self->{page_life_expectancy},
    );
  } elsif ($self->mode =~ /server::memorypool::buffercache::freeliststalls/) {
    $self->set_thresholds(
        warning => '4', critical => '10',
    );
    $self->add_message(
        $self->check_thresholds($self->{free_list_stalls_per_sec}),
        sprintf "%.2f free list stalls per second", $self->{free_list_stalls_per_sec}
    );
    $self->add_perfdata(
        label => 'free_list_stalls_per_sec',
        value => $self->{free_list_stalls_per_sec},
    );
  } elsif ($self->mode =~ /server::memorypool::buffercache::checkpointpages/) {
    $self->set_thresholds(
        warning => '100', critical => '500',
    );
    $self->add_message(
        $self->check_thresholds($self->{checkpoint_pages_per_sec}),
        sprintf "%.2f pages flushed per second", $self->{checkpoint_pages_per_sec}
    );
    $self->add_perfdata(
        label => 'checkpoint_pages_per_sec',
        value => $self->{checkpoint_pages_per_sec},
    );
  }
}


