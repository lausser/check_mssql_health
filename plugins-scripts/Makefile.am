libexec_SCRIPTS=check_mssql_health
GL_MODULES=\
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
  Classes/MSSQL/Component/AvailabilitygroupSubsystem.pm \
  Classes/MSSQL/Component/DatabaseSubsystem.pm \
  Classes/MSSQL/Component/MemorypoolSubsystem/Buffercache.pm \
  Classes/MSSQL/Component/MemorypoolSubsystem/Lock.pm \
  Classes/MSSQL/Component/MemorypoolSubsystem.pm \
  Classes/MSSQL/Component/JobSubsystem.pm \
  Classes/MSSQL/SqlRelay.pm \
  Classes/MSSQL/Sqsh.pm \
  Classes/MSSQL/DBI.pm \
  Classes/MSSQL.pm \
  Classes/ASE/Component/DatabaseSubsystem.pm \
  Classes/ASE/SqlRelay.pm \
  Classes/ASE/Sqsh.pm \
  Classes/ASE/DBI.pm \
  Classes/ASE.pm \
  Classes/APS/Component/ComponentSubsystem.pm \
  Classes/APS/Component/DiskSubsystem.pm \
  Classes/APS/Component/AlertSubsystem.pm \
  Classes/APS/SqlRelay.pm \
  Classes/APS/Sqsh.pm \
  Classes/APS/DBI.pm \
  Classes/APS.pm \
  Classes/Sybase/SqlRelay.pm \
  Classes/Sybase/Sqsh.pm \
  Classes/Sybase/DBI.pm \
  Classes/Sybase.pm \
  Classes/Device.pm


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

