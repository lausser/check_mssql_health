#! /usr/bin/perl -w -I ..

use strict;
use Test::More;

BEGIN {
    package Monitoring::GLPlugin::DB::Item;
    sub import { }
    package Monitoring::GLPlugin::DB::TableItem;
    sub import { }
}

use lib 'plugins-scripts';
use CheckMssqlHealth::MSSQL::Component::JobSubsystem;

{
    package CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job;
    use strict;
    no warnings 'redefine';
    *Monitoring::GLPlugin::DB::TableItem::check = sub { };
    sub new { bless { mode => $_[1], name => $_[2], nextrundatetime => $_[3], lastrundatetime => $_[4], lastrunstatus => $_[5], lastrunstatusmessage => $_[6], lastrundurationseconds => $_[7] }, $_[0] }
    sub mode { $_[0]->{mode} }
    sub add_ok { $_[0]->{result} = ['OK', $_[1]] }
    sub add_warning { $_[0]->{result} = ['WARNING', $_[1]] }
    sub add_critical { $_[0]->{result} = ['CRITICAL', $_[1]] }
    sub add_info { }
    sub is_likely_dst_switch_week { 0 }
    sub protect_value { }
    sub set_thresholds { }
    sub check_thresholds { 'OK' }
    sub add_message { $_[0]->{result} = [$_[1], $_[2]] }
    sub add_perfdata { }
}

sub check_result {
    my ($job) = @_;
    $job->check();
    return $job->{result};
}

sub format_nextrun {
    my ($epoch) = @_;
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($epoch);
    my $ampm = 'AM';
    if ($hour >= 12) {
        $ampm = 'PM';
        $hour -= 12;
    }
    $hour = 12 if $hour == 0;
    return sprintf('%s %2d %4d %02d:%02d%s', $months[$mon], $mday, $year + 1900, $hour, $min, $ampm);
}

plan tests => 6;

is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'failed-job', undef, 'Jul 13 2026 11:53AM', 'Failed', 'boom', 0)), ['CRITICAL', 'failed-job failed at Jul 13 2026 11:53AM: boom'], 'failed job is critical');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'retry-job', undef, 'Jul 13 2026 11:53AM', 'Retry', 'again', 0)), ['WARNING', 'retry-job Retry: again'], 'retry job is warning');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'canceled-job', undef, 'Jul 13 2026 11:53AM', 'Canceled', 'stop', 0)), ['WARNING', 'canceled-job Canceled: stop'], 'canceled job is warning');

my $future = time() + 86400;
my $past = time() - 86400;
my $future_text = format_nextrun($future);
my $past_text = format_nextrun($past);

is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never-run-future', $future_text, undef, undef, undef, 0)), ['OK', 'never-run-future did never run'], 'future never-run job stays ok');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'never-run-past', $past_text, undef, undef, undef, 0)), ['WARNING', "never-run-past did never run and is overdue since $past_text"], 'past never-run job warns');
is_deeply(check_result(CheckMssqlHealth::MSSQL::Component::JobSubsystem::Job->new('server::jobs::failed', 'succeeded-job', undef, 'Jul 13 2026 11:53AM', 'Succeeded', 'fine', 75)), ['OK', 'job succeeded-job ran for 75 seconds (started Jul 13 2026 11:53AM)'], 'succeeded job follows runtime path');
