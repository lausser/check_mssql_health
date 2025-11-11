package Classes::APS::Disk::DiskSubsystem;
our @ISA = qw(Monitoring::GLPlugin::DB::Item);
use strict;

sub init {
  my $self = shift;
  my $sql = undef;
  if ($self->mode =~ /server::aps::disk::free/) {
    $self->override_opt("units", "%") if ! $self->opts->units;
    my $columns = ['node_name', 'name', 'size_mb',
        'free_space_mb', 'space_utilized_mb', 'free_space_pct'];
    my $sql = q{
        SELECT
            NodeName,
            VolumeName,
            VolumeSizeMB,
            FreeSpaceMB,
            SpaceUtilized,
            FreeSpaceMBPct
        FROM
            SQL_ADMIN.[dbo].disk_space
        ORDER BY
            NodeName, VolumeName DESC";
    };
    $self->get_db_tables([
        ['disks', $sql, 'Classes::APS::Disk::DiskSubsystem::Disk', sub { my $o = shift; $self->filter_name($o->{name}); }, $columns],
    ]);
  }
}


package Classes::APS::Disk::DiskSubsystem::Disk;
our @ISA = qw(Monitoring::GLPlugin::DB::TableItem);
use strict;

sub finish {
  my $self = shift;
  $self->{name} = $self->{node_name}.'_'.$self->{name};
  $self->{name} = lc $self->{name};
  my $factor = 1; # MB
  if ($self->opts->units ne "%") {
    if (uc $self->opts->units eq "GB") {
      $factor = 1024;
    } elsif (uc $self->opts->units eq "MB") {
      $factor = 1;
    } elsif (uc $self->opts->units eq "KB") {
      $factor = 1 / 1024;
    }
  }
  $self->{size} = $self->{size_mb} / $factor;
  $self->{free_space} = $self->{free_space_mb} / $factor;
  $self->{space_utilized} = $self->{space_utilized_mb} / $factor;
}

sub check {
  my $self = shift;
  my $warning_units;
  my $critical_units;
  my $warning_pct;
  my $critical_pct;
  my $metric_units = $self->{name}.'_free';
  my $metric_pct = $self->{name}.'_free_pct';
  if ($self->opts->units eq "%") {
    $self->set_thresholds(metric => $metric_pct, warning => "10:", critical => "5:");
    ($warning_pct, $critical_pct) = ($self->get_thresholds(metric => $metric_pct));
    ($warning_units, $critical_units) = map {
        $_ =~ s/://g; ($_ * $self->{size} / 100).":";
    } map { my $tmp = $_; $tmp; } ($warning_pct, $critical_pct); # sonst schnippelt der von den originalen den : weg
    $self->set_thresholds(metric => $metric_units, warning => $warning_units, critical => $critical_units);
    $self->add_message($self->check_thresholds(metric => $metric_pct, value => $self->{free_space_pct}),
        sprintf("disk %s has %.2f%s free space left", $self->{name}, $self->{free_space_pct}, $self->opts->units));
  } else {
    $self->set_thresholds(metric => $metric_units, warning => "5:", critical => "10:");
    ($warning_units, $critical_units) = ($self->get_thresholds(metric => $metric_units));
    ($warning_pct, $critical_pct) = map {
        $_ =~ s/://g; (100 * $_ / $self->{size}).":";
    } map { my $tmp = $_; $tmp; } ($warning_units, $critical_units);
    $self->set_thresholds(metric => $metric_pct, warning => $warning_pct, critical => $critical_pct);
    $self->add_message($self->check_thresholds(metric => $metric_units, value => $self->{free_space}),
        sprintf("disk %s has %.2f%s free space left", $self->{name}, $self->{free_space}, $self->opts->units));
  }
  $self->add_perfdata(
      label => $metric_pct,
      value => $self->{free_space_pct},
      places => 2,
      uom => '%',
      warning => $warning_pct,
      critical => $critical_pct,
  );
  $self->add_perfdata(
      label => $metric_units,
      value => $self->{free_space},
      uom => $self->opts->units eq "%" ? "MB" : $self->opts->units,
      places => 2,
      warning => $warning_units,
      critical => $critical_units,
      min => 0,
      max => $self->{size},
  );
}

