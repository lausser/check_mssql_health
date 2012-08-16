%define debug_package %{nil}

Summary:	Nagios plugins to check the status of MS-SQL Servers
Name:		check_mssql_health
Version:	1.5.10
Release:	1%{?dist}
License:	GPLv2+
Group:		Applications/System
URL:		http://labs.consol.de/lang/en/nagios/check_mssql_health/
Source0:	http://labs.consol.de/download/shinken-nagios-plugins/check_mssql_health-%{version}.tar.gz
Requires:	perl-Nagios-Plugin
Requires:	perl-DBD-Sybase
BuildRequires:	automake
BuildRoot:	%{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)


%description
check_mssql_health is a plugin, which is used to monitor different parameters of a MS SQL server.

%prep
%setup -T -b0 

%build
aclocal
autoconf
automake
./configure --libexecdir=%{_libdir}/nagios/plugins/ --libdir=%{_libdir}
make 


%install
make install DESTDIR="%{buildroot}"

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
%doc README COPYING
%{_libdir}/nagios/plugins/check_mssql_health

%changelog
* Thu Aug 16 2012 Pall Sigurdsson <palli@opensource.is> 1.5.10-1
- Initial packaging
