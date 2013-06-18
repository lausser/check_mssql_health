PLUGIN=check_mssql_health

docs: dedoc endoc
	$(RM) $(PLUGIN).html
	printf "<!-- [lang_de] -->\n\n" >> $(PLUGIN).html
	cat $(PLUGIN).de.html >> $(PLUGIN).html
	printf "<!-- [/lang_de][lang_en] -->\n\n" >> $(PLUGIN).html
	cat $(PLUGIN).en.html >> $(PLUGIN).html
	printf "<!-- [/lang_en] -->\n\n" >> $(PLUGIN).html
	sed -ri '/col width/d' $(PLUGIN).html
	unix2dos $(PLUGIN).html

dedoc:
	asciidoc --unsafe --no-header-footer -a max-width=800 $(PLUGIN).de.txt

endoc:
	asciidoc --unsafe --no-header-footer -a max-width=800 $(PLUGIN).en.txt

clean:
	$(RM) $(PLUGIN).html
	$(RM) $(PLUGIN).en.html
	$(RM) $(PLUGIN).de.html
