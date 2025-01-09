package Classes::Sybase::DBI;
our @ISA = qw(Classes::Sybase Monitoring::GLPlugin::DB::DBI);
use strict;
use File::Basename;

sub check_connect {
  my ($self) = @_;
  my $stderrvar;
  my $dbi_options = { RaiseError => 1, AutoCommit => $self->opts->commit, PrintError => 1 };
  my $dsn = "DBI:Sybase:";
  my $dbname;
  if ($self->opts->hostname) {
    $dsn .= sprintf ";host=%s", $self->opts->hostname;
    $dsn .= sprintf ";port=%s", $self->opts->port;
  } else {
    $dsn .= sprintf ";server=%s", $self->opts->server;
  }
  $dsn .= ";encryptPassword=1";
  if ($self->opts->currentdb) {
    # Falls ein Bindestrich, Punkt, Untersrich oder Leerzeichen im Namen enthalten ist, füge den Namen in Anführungszeichen hinzu, andernfalls direkt
    if (index($self->opts->currentdb, "-") != -1 
    || index($self->opts->currentdb, ".") != -1 
    || index($self->opts->currentdb, "_") != -1 
    || index($self->opts->currentdb, " ") != -1) {
        $dbname = sprintf "\"%s\"", $self->opts->currentdb;
    } else {
        $dbname = sprintf "%s", $self->opts->currentdb;
    }
}
  if (basename($0) =~ /_sybase_/) {
    $dbi_options->{syb_chained_txn} = 1;
    $dsn .= sprintf ";tdsLevel=CS_TDS_42";
  }
  $self->set_variable("dsn", $dsn);
  eval {
    require DBI;
    $self->set_timeout_alarm($self->opts->timeout - 1, sub {
      die "alrm";
    });
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    if ($self->{handle} = DBI->connect(
        $dsn,
        $self->opts->username,
        $self->opts->password,
        $dbi_options)) {
      $Monitoring::GLPlugin::DB::session = $self->{handle};
      if ($self->opts->currentdb) {
        $self->{handle}->do("USE " . $dbname);
      }

      
    }
    $self->{tac} = Time::HiRes::time();
    $Monitoring::GLPlugin::DB::session->{syb_flush_finish} = 1;
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
  } elsif (! $self->{handle}) {
    $self->add_critical("no connection");
  } else {
    $self->set_timeout_alarm($self->opts->timeout - ($self->{tac} - $self->{tic}));
  }
}

sub fetchrow_array {
  my ($self, $sql, @arguments) = @_;
  my @row = ();
  my $errvar = "";
  my $stderrvar = "";
  $self->set_variable("verbosity", 2);
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    if ($self->get_variable("dsn") =~ /tdsLevel/) {
      # better install a handler here. otherwise the plugin output is
      # unreadable when errors occur
      $Monitoring::GLPlugin::DB::session->{syb_err_handler} = sub {
        my($err, $sev, $state, $line, $server,
            $proc, $msg, $sql, $err_type) = @_;
        $errvar = join("\n", (split(/\n/, $errvar), $msg));
        return 0;
      };
    }
    $self->debug(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    my $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments) || die DBI::errstr();
    } else {
      $sth->execute() || die DBI::errstr();
    }
    if (lc $sql =~ /^\s*(exec |sp_)/ || $sql =~ /^\s*exec sp/im) {
      # flatten the result sets
      do {
        while (my $aref = $sth->fetchrow_arrayref()) {
          push(@row, @{$aref});
        }
      } while ($sth->{syb_more_results});
    } else {
      @row = $sth->fetchrow_array();
    }
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
    $sth->finish();
  };
  *STDERR = *SAVEERR;
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
  } elsif ($stderrvar || $errvar) {
    $errvar = join("\n", (split(/\n/, $errvar), $stderrvar));
    $self->debug(sprintf "stderr %s", $errvar) ;
    $self->add_warning($errvar);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my ($self, $sql, @arguments) = @_;
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
    my $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    if ($sql !~ /^\s*dbcc /im) {
      $rows = $sth->fetchall_arrayref();
    }
    $sth->finish();
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
  my ($self, $sql, @arguments) = @_;
  my $rows = undef;
  my $stderrvar;
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    $self->debug(sprintf "EXEC\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    my $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
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
    $sth->finish();
  };
  *STDERR = *SAVEERR;
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
    $rows = [];
  } elsif ($stderrvar) {
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->add_warning($stderrvar);
    $rows = [];
  }
  return @{$rows};
}

sub execute {
  my ($self, $sql, @arguments) = @_;
  my $errvar = "";
  my $stderrvar = "";
  $Monitoring::GLPlugin::DB::session->{syb_err_handler} = sub {
    # exec sometimes a status code which, if not caught by this handler,
    # is output to stderr. So even if the procedure was run correctly
    # there may be a warning
    my($err, $sev, $state, $line, $server,
        $proc, $msg, $sql, $err_type) = @_;
    $errvar = join("\n", (split(/\n/, $errvar), $msg));
    return 0;
  };
  *SAVEERR = *STDERR;
  open ERR ,'>',\$stderrvar;
  *STDERR = *ERR;
  eval {
    $self->debug(sprintf "EXEC\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    my $sth = $Monitoring::GLPlugin::DB::session->prepare($sql);
    $sth->execute();
    $sth->finish();
  };
  *STDERR = *SAVEERR;
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
  } elsif ($stderrvar || $errvar) {
    $errvar = join("\n", (split(/\n/, $errvar), $stderrvar));
    $self->debug(sprintf "stderr %s", $errvar) ;
    $self->add_warning($errvar);
  }
}


sub add_dbi_funcs {
  my $self = shift;
  $self->SUPER::add_dbi_funcs();
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::fetchall_array'} = \&{"Classes::Sybase::DBI::fetchall_array"};
    *{'Monitoring::GLPlugin::DB::fetchrow_array'} = \&{"Classes::Sybase::DBI::fetchrow_array"};
    *{'Monitoring::GLPlugin::DB::exec_sp_1hash'} = \&{"Classes::Sybase::DBI::exec_sp_1hash"};
    *{'Monitoring::GLPlugin::DB::execute'} = \&{"Classes::Sybase::DBI::execute"};
  }
}

