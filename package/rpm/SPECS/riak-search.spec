# _revision, _release, and _version  should be defined on the rpmbuild command
# line like so:
#
# --define "_version 0.9.1" --define "_release 7" \
# --define "_revision 0.9.1-19-abcdef"

%define appname		riaksearch
%define appuser		riak

Name: riak-search
Version: %{_version}
Release: %{_release}%{?dist}
License: Proprietary
Group: Development/Libraries
Source: %{name}-%{_revision}.tar.gz
Source1: riaksearch_init
URL: http://basho.com
Vendor: Basho Technologies
Packager: Basho Technologies <riak-user@lists.basho.com>
BuildRoot: %{_tmppath}/%{name}-%{_revision}-%{release}-root
Summary: Riak Distributed Scaling Search

%description
Riak is a distrubuted data store.

%define riak_lib %{_libdir}/%{appname}
%define init_script %{_sysconfdir}/init.d/%{appname}

%define __prelink_undo_cmd /bin/cat prelink library

%prep
%setup -q -n %{_repo}-%{_revision}
cat > rel/vars.config <<EOF
% app.config
{ring_state_dir, "%{_localstatedir}/lib/%{appname}/ring"}.
{web_ip,       "127.0.0.1"}.
{web_port,     8098}.
{handoff_port, 8099}.
{pb_ip,        "127.0.0.1"}.
{pb_port,      8087}.
{bitcask_data_root, "%{_localstatedir}/lib/%{appname}/bitcask"}.
{merge_index_data_root,  "%{_localstatedir}/lib/%{appname}/merge_index"}.
{analyzer_conns,    50}.
{analyzer_port,     6095}.
{sasl_error_log, "%{_localstatedir}/log/%{appname}/sasl-error.log"}.
{sasl_log_dir, "%{_localstatedir}/log/%{appname}/sasl"}.
{mapred_queue_dir, "%{_localstatedir}/lib/%{appname}/mr_queue"}.
{map_js_vms,   8}.
{reduce_js_vms, 6}.
{hook_js_vms, 2}.
% vm.args
{node,         "riak@127.0.0.1"}.
{crash_dump,   "%{_localstatedir}/log/%{appname}/erl_crash.dump"}.
% bin/riak*
{runner_script_dir,  "/usr/sbin"}.
{runner_base_dir,    "%{riak_lib}"}.
{runner_etc_dir,     "%{_sysconfdir}/%{appname}"}.
{runner_log_dir,     "%{_localstatedir}/log/%{appname}"}.
{pipe_dir,           "%{_localstatedir}/run/%{appname}/"}.
{runner_user,        "%{appuser}"}.
EOF


%build
#mkdir %{appname}
make rel

%install
%define releasepath	%{_builddir}/%{buildsubdir}/rel/%{appname}

mkdir -p %{buildroot}%{_sysconfdir}/%{appname}
mkdir -p %{buildroot}%{riak_lib}
mkdir -p %{buildroot}%{_mandir}/man1
mkdir -p %{buildroot}%{_localstatedir}/lib/%{appname}/bitcask
mkdir -p %{buildroot}%{_localstatedir}/lib/%{appname}/merge_index
mkdir -p %{buildroot}%{_localstatedir}/lib/%{appname}/ring
mkdir -p %{buildroot}%{_localstatedir}/log/%{appname}/sasl
mkdir -p %{buildroot}%{_localstatedir}/run/%{appname}
mkdir -p %{buildroot}%{_localstatedir}/lib/%{name}/mr_queue

#Copy all necessary lib files etc.
cp -r %{releasepath}/lib %{buildroot}%{riak_lib}
cp -r %{releasepath}/erts-* %{buildroot}%{riak_lib}
cp -r %{releasepath}/releases %{buildroot}%{riak_lib}
cp -r $RPM_BUILD_DIR/%{_repo}-%{_revision}/doc/man/man1/*.gz \
		%{buildroot}%{_mandir}/man1
install -p -D -m 0644 \
		%{releasepath}/etc/app.config \
		%{buildroot}%{_sysconfdir}/%{appname}/
install -p -D -m 0644 \
		%{releasepath}/etc/vm.args \
		%{buildroot}%{_sysconfdir}/%{appname}/
install -p -D -m 0755 \
		%{releasepath}/bin/%{appname} \
		%{buildroot}/%{_sbindir}/%{appname}
install -p -D -m 0755 \
		%{releasepath}/bin/%{appname}-admin \
		%{buildroot}/%{_sbindir}/%{appname}-admin
install -p -D -m 0755 \
		%{releasepath}/bin/search-cmd \
		%{buildroot}/%{_sbindir}/search-cmd
install -p -D -m 0755 \
    %{SOURCE1} %{buildroot}/%{init_script}


# Needed to work around check-rpaths which seems to be hardcoded into recent
# RPM releases
export QA_RPATHS=3


%pre
# create riak group only if it doesn't already exist
if ! getent group %{appuser} >/dev/null 2>&1; then
        groupadd -r %{appuser}
fi

# create riak user only if it doesn't already exist
if getent passwd %{appuser} >/dev/null 2>&1; then
	# make sure it has the right home dir if the user already exists
	usermod -d %{_localstatedir}/lib/%{appname} %{appuser}
else
        useradd -r -g %{appuser} --home %{_localstatedir}/lib/%{appname} \
			%{appuser}
        usermod -c "Riak Server" %{appuser}
fi

%files
%defattr(-,riak,riak)
%{_libdir}/*
%dir %{_sysconfdir}/%{appname}
%config(noreplace) %{_sysconfdir}/%{appname}/*
%attr(0755,root,root) %{init_script}
%attr(0755,root,root) %{_sbindir}/%{appname}
%attr(0755,root,root) %{_sbindir}/%{appname}-admin
%attr(0755,root,root) %{_sbindir}/search-cmd
%attr(0644,root,root) %{_mandir}/man1/*
%{_localstatedir}/lib/%{appname}
%{_localstatedir}/log/%{appname}
%{_localstatedir}/run/%{appname}

%clean
rm -rf %{buildroot}

%changelog
* Mon Jul 12 2010 Ryan Tilder <rtilder@basho.com> 0.12.0rc1
- Stop patching scripts since rebar will now templatize files

* Tue May 18 2010 Ryan Tilder <rtilder@basho.com> 112rc3-1
- Tweak for riak-ee

* Wed May 12 2010 Ryan Tilder <rtilder@basho.com> 0.10.1-3
- Tweak how bin/riak, bin/riak-admin, and bin/app.config are being modified
  for packaging

* Wed Mar 24 2010 Ryan Tilder <rtilder@basho.com> 0.9.1-2
- Some simplification and tweaks

* Wed Mar 10 2010 Grant Schofield <grant@basho.com> 0.9.0-1
- First 0.9 build

