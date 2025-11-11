libexec_SCRIPTS=check_mssql_health
GL_MODULES=\
  ../GLPlugin/lib/Monitoring/GLPlugin/Commandline/Extraopts.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/Commandline/Getopt.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/Commandline.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/Item.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/TableItem.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/DB.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/DB/DBI.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/DB/CSF.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/DB/Item.pm \
  ../GLPlugin/lib/Monitoring/GLPlugin/DB/TableItem.pm
EXTRA_MODULES=\
  CheckMssqlHealth/MSSQL/Component/AvailabilitygroupSubsystem.pm \
  CheckMssqlHealth/MSSQL/Component/DatabaseSubsystem.pm \
  CheckMssqlHealth/MSSQL/Component/MemorypoolSubsystem/Buffercache.pm \
  CheckMssqlHealth/MSSQL/Component/MemorypoolSubsystem/Lock.pm \
  CheckMssqlHealth/MSSQL/Component/MemorypoolSubsystem.pm \
  CheckMssqlHealth/MSSQL/Component/JobSubsystem.pm \
  CheckMssqlHealth/MSSQL/SqlRelay.pm \
  CheckMssqlHealth/MSSQL/Sqsh.pm \
  CheckMssqlHealth/MSSQL/DBI.pm \
  CheckMssqlHealth/MSSQL.pm \
  CheckMssqlHealth/ASE/Component/DatabaseSubsystem.pm \
  CheckMssqlHealth/ASE/SqlRelay.pm \
  CheckMssqlHealth/ASE/Sqsh.pm \
  CheckMssqlHealth/ASE/DBI.pm \
  CheckMssqlHealth/ASE.pm \
  CheckMssqlHealth/APS/Component/ComponentSubsystem.pm \
  CheckMssqlHealth/APS/Component/DiskSubsystem.pm \
  CheckMssqlHealth/APS/Component/AlertSubsystem.pm \
  CheckMssqlHealth/APS/SqlRelay.pm \
  CheckMssqlHealth/APS/Sqsh.pm \
  CheckMssqlHealth/APS/DBI.pm \
  CheckMssqlHealth/APS.pm \
  CheckMssqlHealth/Sybase/SqlRelay.pm \
  CheckMssqlHealth/Sybase/Sqsh.pm \
  CheckMssqlHealth/Sybase/DBI.pm \
  CheckMssqlHealth/Sybase.pm \
  CheckMssqlHealth/Device.pm


SED=/bin/sed
GREP=/bin/grep
CAT=/bin/cat
ECHO=/bin/echo
if DISABLE_STANDALONE
STANDALONE = no
else
STANDALONE = yes
endif

SUFFIXES = .pl .pm .sh

VPATH=$(top_srcdir) $(top_srcdir)/plugins-scripts $(top_srcdir)/plugins-scripts/t

EXTRA_DIST=$(libexec_SCRIPTS).pl $(EXTRA_MODULES) $(GL_MODULES)

CLEANFILES=$(libexec_SCRIPTS)

AM_INSTALL_PROGRAM_FLAGS=@INSTALL_OPTS@

.pm :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

.pl :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

.sh :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

$(libexec_SCRIPTS) : $(EXTRA_DIST)
	$(ECHO) "#! #PERL# -w" | $(AWK) -f ./subst > $@
	$(ECHO) "# nagios: -epn" >> $@
	$(ECHO) >> $@
	if [ "${STANDALONE}" == "yes" ]; then \
		$(ECHO) i am standalone; \
		for m in ${GL_MODULES}; do \
			$(SED) -e 's/^1;//g' < $$m | $(SED) -e '/^__END__/,$$d' | $(SED) -e '/^__PACKAGE__/,$$d' | $(AWK) -f ./subst >> $@; \
		done \
	fi
	for m in ${EXTRA_MODULES}; do \
		$(SED) -e 's/^1;//g' < $$m | $(SED) -e '/^__END__/,$$d' | $(AWK) -f ./subst >> $@; \
	done
	$(ECHO) "package main;" >> $@
	$(CAT) $(libexec_SCRIPTS).pl | $(AWK) -f ./subst >> $@
	chmod +x $@

