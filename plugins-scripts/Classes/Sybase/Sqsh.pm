package Classes::Sybase::Sqsh;
our @ISA = qw(Classes::Sybase);
use strict;
use File::Basename;

sub create_cmd_line {
  my $self = shift;
  my @args = ();
  if ($self->opts->server) {
    push (@args, sprintf "-S '%s'", $self->opts->server);
  }
  if ($self->opts->hostname) {
    push (@args, sprintf "-H '%s'", $self->opts->server);
    push (@args, sprintf "-p '%s'", $self->opts->port);
  }
  push (@args, sprintf "-U '%s'", $self->opts->username);
  push (@args, sprintf "-P '%s'",
      $self->decode_password($self->opts->password));
  push (@args, sprintf "-i '%s'", $self->{sql_commandfile});
  push (@args, sprintf "-o '%s'", $self->{sql_resultfile});
  if ($self->opts->currentdb) {
    push (@args, sprintf "-D '%s'", $self->opts->currentdb);
  }
  push (@args, sprintf "-h -s '|'");
  $self->{sqsh} = sprintf '"%s" %s', $self->{extcmd}, join(" ", @args);
}

sub check_connect {
  my $self = shift;
  my $stderrvar;
  if (! $self->find_extcmd("sqsh", "SQL_HOME")) {
    $self->add_unknown("sqsh command was not found");
    return;
  }
  $self->create_extcmd_files();
  $self->create_cmd_line();
  eval {
    require DBI;
    use POSIX ':signal_h';
    if ($^O =~ /MSWin/) {
      local $SIG{'ALRM'} = sub {
        die "alrm";
      };
    } else {
      my $mask = POSIX::SigSet->new( SIGALRM );
      my $action = POSIX::SigAction->new(
          sub { die "alrm"; }, $mask
      );
      my $oldaction = POSIX::SigAction->new();
      sigaction(SIGALRM ,$action ,$oldaction );
    }
    alarm($self->opts->timeout - 1); # 1 second before the global unknown timeout
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    my $answer = $self->fetchrow_array(q{
        SELECT 'schnorch'
    });
    die unless defined $answer and $answer eq 'schnorch';
    $self->{tac} = Time::HiRes::time();
    *STDERR = *SAVEERR;
  };
  if ($@) {
    if ($@ =~ /alrm/) {
      $self->add_critical(
          sprintf "connection could not be established within %s seconds",
          $self->opts->timeout);
    } else {
      $self->add_critical($@);
    }
  } elsif ($stderrvar && $stderrvar =~ /can't change context to database/) {
    $self->add_critical($stderrvar);
  }
}

sub write_extcmd_file {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $self->{sql_commandfile}";
  printf CMDCMD "%s\n", $sql;
  printf CMDCMD "go\n";
  close CMDCMD;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my @row = ();
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($self->{sqsh});
  my $exit_output = `$self->{sqsh}`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->add_warning($stderrvar);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    @row = map { convert_scientific_numbers($_) }
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\|/, (split(/\n/, $output))[0]);
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  my $errvar = "";
  my $stderrvar = "";
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    $self->debug(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    if ($sql =~ /^\s*dbcc /im) {
      # dbcc schreibt auf stdout. Die Ausgabe muss daher
      # mit einem eigenen Handler aufgefangen werden.
      $Monitoring::GLPlugin::DB::session->{syb_err_handler} = sub {
        my($err, $sev, $state, $line, $server,
            $proc, $msg, $sql, $err_type) = @_;
        push(@{$rows}, $msg);
        return 0;
      };
    }
    $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    if ($sql !~ /^\s*dbcc /im) {
      $rows = $sth->fetchall_arrayref();
    }
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  };
  *STDERR = *SAVEERR;
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
    $rows = [];
  } elsif ($stderrvar || $errvar) {
    $errvar = join("\n", (split(/\n/, $errvar), $stderrvar));
    $self->debug(sprintf "stderr %s", $errvar) ;
    $self->add_warning($errvar);
  }
  return @{$rows};
}

sub exec_sp_1hash {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  eval {
    $self->debug(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    do {
      while (my $href = $sth->fetchrow_hashref()) {
        foreach (keys %{$href}) {
          push(@{$rows}, [ $_, $href->{$_} ]);
        }
      }
    } while ($sth->{syb_more_results});
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
    $rows = [];
  }
  return @{$rows};
}

sub add_dbi_funcs {
  my $self = shift;
  $self->SUPER::add_dbi_funcs();
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::fetchall_array'} = \&{"Classes::Sybase::Sqsh::fetchall_array"};
    *{'Monitoring::GLPlugin::DB::fetchrow_array'} = \&{"Classes::Sybase::Sqsh::fetchrow_array"};
    *{'Monitoring::GLPlugin::DB::execute'} = \&{"Classes::Sybase::Sqsh::execute"};
  }
}

