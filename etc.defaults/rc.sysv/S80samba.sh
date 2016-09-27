#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

init_env() {
	PATH="/usr/bin:/bin"
	PATH_LOG="/var/log"

	SZD_PID="/run/samba"
	if [ -e $SZD_PID -a ! -d $SZD_PID ]; then
		rm -f "$SZD_PID"
	fi
	if ! [ -e $SZD_PID ]; then
		mkdir -p "$SZD_PID"
	fi
}
init_lsb_status() { # void
	# XXX these defined in /etc/rc.subr just include to reference

	# According to LSB 3.1 (ISO/IEC 23360:2006), the `status` init-scripts
	# action should return the following exit status codes.
	#
	LSB_STAT_RUNNING=0      # program is running or service is OK
	LSB_STAT_DEAD_FPID=1    # program is dead and /var/run pid file exists
	LSB_STAT_DEAD_FLOCK=2   # program is dead and /var/lock lock file exists
	LSB_STAT_NOT_RUNNING=3  # program is not runnning
	LSB_STAT_UNKNOWN=4      # program or service status is unknown
	# 5-99                  # reserved for future LSB use
	# 100-149               # reserved for distribution use
	# 150-199               # reserved for application use
	# 200-254               # reserved

	# Non-status init-scripts actions should return an exit status of zero if
	# the action was successful. Otherwise, the exit status shall be non-zero.
	#
	LSB_SUCCESS=0           # successful
	LSB_ERR_GENERIC=1       # generic or unspecified error
	LSB_ERR_ARGS=2          # invalid or excess argument(s)
	LSB_ERR_UNIMPLEMENTED=3 # unimplemented feature (for example, `reload`)
	LSB_ERR_PERM=4          # user had insufficient privilege
	LSB_ERR_INSTALLED=5     # program is not installed
	LSB_ERR_CONFIGURED=6    # program is not configured
	LSB_NOT_RUNNING=7       # program is not running
	# 8-99                  # reserved for future LSB use
	# 100-149               # reserved for distribution use
	# 150-199               # reserved for application use
	# 200-254               # reserved
}
source /etc/rc.subr || init_lsb_status

set_smbd_affinity() {
	uname -a | grep -i "qoriq\|evansport\|comcerto2k\|armada375\|monaco" > /dev/null 2>&1
	local support_smb_affinity="$?"

	if [ 0 -eq ${support_smb_affinity} ]; then
		for each_pid in `pidof smbd`; do
			/usr/bin/taskset -p 2 $each_pid > /dev/null 2>&1
		done
	fi
}

# util functions
syslog() { # logger args
	local ret=$?
	logger -p user.err -t $(basename $0)\($$\) "$@"
	return $ret
}
message() { # echo args
	local ret=$?
	echo "$@"
	return $ret
} >&2
warn() { # echo args
	local ret=$?
	local H="[33m" E="[0m"
	echo -en "$H$@" ; echo "$E"
	return $ret
} >&2

is_alive() { # <pid> [proc name]
	local pid=${1:?"error params"}
	local procname="$2"

	if [ ! -r "/proc" -o -z "${procname:-}" ]; then
		kill -0 "$pid" 2>/dev/null
	else
		bin_file=`readlink "/proc/$pid/exe"`
		[ x"$(basename "$bin_file")" = x"$procname" ]
	fi
}
is_any_running() {
	local i=
	for i in "$@"; do
		if pidof $i >/dev/null; then
			return 0
		fi
	done
	return 1
}
check_domain_migrate() {
	local UPDATE=1
	#DSM 4.2 -> 4.3 migrate domain user/group related data base
	if [ ! -e /usr/syno/etc/private/.db.domain_user -o ! -e /usr/syno/etc/private/.db.domain_group ]; then
		UPDATE=0
	fi

	#DSM 5.2 --> 6.0 add domain user/group full db
	/bin/ls /usr/syno/etc/private/.db.domain_user_full.* /usr/syno/etc/private/.db.domain_group_full.* > /dev/null 2>&1
	if [ $UPDATE -eq 1 -a $? -ne 0 ]; then
		UPDATE=0
	fi

	return $UPDATE
}
proc_ppid() {
	local pid=$1;
	local ppid="";
	if [ -z $pid ]; then
		pid=$$;
	fi
	if [ -f "/proc/$pid/status" ]; then
		echo `grep "PPid" /proc/$pid/status | cut -d: -f2`
	else
		return 1;
	fi
}
proc_info() { # <proc name> [pid file]
	local procname=${1:?"error params"}
	local pidfile=${2:-"$SZD_PID/$procname.pid"}

	local pid= running= i=
	if [ -r "$pidfile" ]; then
		pid=`cat "$pidfile"`
		if is_alive "$pid" "$procname"; then
			running="R"
		fi
	fi
	if pidof "$procname" >/dev/null; then
		running=${running:-"?"}
	else
		running="-"
	fi

	if [ ! "$_proc_info_header_dumped" ]; then
		printf "%-15s %-7s %4s  other pids\n" "procname" "pidfile" "stat"
		_proc_info_header_dumped=y
	fi

	printf "%-15s %-7s %4s  " "$procname" "$pid" "$running"
	for i in `pidof "$procname"`; do
		[ "$i" -eq "$pid" ] && continue

		echo -n "$i("`proc_ppid "$i"`") "
	done
	echo ""
}
proc_stop() {
	local procname=${1:?"error params"}
	local pidfile=${2:-"$SZD_PID/$procname.pid"}

	message -n "stop $procname ... "

	if ! pidof "$procname" >/dev/null; then
		message "not running"
		return ${LSB_NOT_RUNNING:-7}
	fi

	if ! [ -f "$pidfile" ]; then
		warn "no pid file, but process exist"
	fi
	/sbin/stop $procname
}
proc_wait_stop() {
	local procname=${1:?"error params"}
	local retry=10
	local d1=`date +%s`

	while [ $retry -gt 0 ] && pidof "$procname" >/dev/null; do
		sleep 1
		retry=$((retry-1))
	done

	local d2=`date +%s`

	if pidof "$procname" >/dev/null; then
		killall -9 "$procname"
		warn "$procname still running, wait $((d2 - d1)) sec, force kill"
	else
		message "$procname stoped ($((d2 - d1)) sec)" 
	fi
}
proc_signal() { # <signal> <proc name>
	local sig=${1:?"error params"}
	local procname=${2:?"error params"}
	local pidfile=${3:-"$SZD_PID/$procname.pid"}

	if [ -f "$pidfile" ]; then
		local pid=`cat "$pidfile"`
		if ! kill -$sig $pid; then
			warn "dead pid file"
		fi
	fi
}
get_first_volume()
{
	local VPATH=""
	VPATH=`/usr/syno/bin/servicetool --get-alive-volume`
	if [ "$?" = "0" ]; then
		VPATH="/var/lib/samba"
	fi
	echo $VPATH
}

# lsb util functions
lsb_status() { # <proc name> [pid file]
	local procname=${1:?"error params"}
	local pidfile=${2:-"$SZD_PID/$procname.pid"}

	if [ -f "$pidfile" ]; then
		local pid=`cat "$pidfile"`
		if is_alive "$pid" "$procname"; then
			printf "%-15s %s\n" "$procname:" running
			return ${LSB_STAT_RUNNING:-0}
		else
			warn "dead pid file: $pidfile"
			printf "%-15s %s\n" "$procname:" stopped
			return ${LSB_STAT_DEAD_FPID:-1}
		fi
	fi

	printf "%-15s %s\n" "$procname:" stopped
	return ${LSB_STAT_NOT_RUNNING:-3}
}

# smb util functions
smb_is_enabled() { # <void>
	/usr/syno/sbin/synoservice --is-enable samba > /dev/null
	[ $? = 1 ]
}
smb_remove_share_tdbs() {
	# those tdb will be used by nmbd, smbd, winbindd
	rm -f /run/samba/messages.tdb /run/samba/serverid.tdb
}
smb_remove_smbd_temp_tdbs() {
	rm -f /run/samba/brlock.tdb /run/samba/connections.tdb \
		/run/samba/login_cache.tdb "/var/cache/samba/printing/*.tdb" \
		/run/samba/sessionid.tdb /run/samba/locking.tdb \
		/run/samba/unexpected.tdb /run/samba/deferred_open.tdb \
		/var/cache/samba/notify_onelevel.tdb
}
smb_remove_winbindd_temp_tdbs() {
	#We default enable winbindd offline logon
	#so we cannot remove winbindd_cache.tdb when restart winbindd.
	#The netsamlogon_cache.tdb may be cannot be delete for auth. 
	#But netsamlogon_cache.tdb has too much cache issue.

	local cache_size=`/usr/bin/du -L /var/lib/samba/winbindd_cache.tdb 2> /dev/null | cut -f1`
	if [ "$cache_size" -gt 204800 ]; then
		#when cache size too large, we should clear it before starting winbindd
		rm -f `/usr/bin/realpath /var/lib/samba/winbindd_cache.tdb`
	fi
	rm -f /var/cache/samba/winbindd_cache.tdb* /var/lib/samba/winbindd_cache.tdb*
}
smb_remove_smbd_winbindd_share_tdbs() {
	if is_any_running smbd winbindd; then
		return 1
	fi
	rm -f /var/cache/samba/netsamlogon_cache.tdb /run/samba/gencache_notrans.tdb \
		  /run/samba/gencache.tdb /var/lib/samba/group_mapping.tdb
}
smb_remove_temp_tdbs() { # <void>
	if is_any_running smbd nmbd winbindd; then
		return 1
	fi

	message "remove temp tdbs"

	smb_remove_smbd_temp_tdbs
	smb_remove_winbindd_temp_tdbs
	smb_remove_smbd_winbindd_share_tdbs
	smb_remove_share_tdbs
}
smb_check_tdb() { # <tdb file>
	local tdbfile=${1:?"error param"}
	local backup=/usr/bin/tdbbackup

	message -n "check tdb: $tdbfile ... "

	if [ -f "$tdbfile" ]; then
		if $backup -v "$tdbfile" >/dev/null 2>&1; then
			# tdb is good make another backup
			mv -f "$tdbfile.bkp" "$tdbfile.bkp.old"
			if $backup -s ".bkp" "$tdbfile" >/dev/null 2>&1; then
				message "done"
				rm -f "$tdbfile.bkp.old"
			else
				warn "backup failed"
				mv -f "$tdbfile.bkp.old" "$tdbfile.bkp"
			fi
		elif [ -f "$tdbfile.bkp" ]; then
			warn "corrupt, restore"
			if ! $backup -v -s ".bkp" "$tdbfile" >/dev/null; then
				warn "restore failed, remove it"
				rm -f "$tdbfile"
			fi
		else
			warn "corrupt, remove it"
			rm -f "$tdbfile"
		fi
	elif [ -f "$tdbfile.bkp" ];then
		warn "lost, use backup tdb"
		if ! $backup -v -s ".bkp" "$tdbfile" > /dev/null; then
			warn "restore failed"
		fi
	else
		message "not exist"
	fi

	return 0
}

smb_prestart_smbd() {
	local smbspool=/var/spool/samba i=
	local printer_tdbs="ntprinters.tdb ntforms.tdb ntdrivers.tdb"

	# FIXME remove smbspool
	[ -d "$smbspool" ] && rm -f "$smbspool/*"

	# check private dir
	smb_check_tdb /etc/samba/private/secrets.tdb

	# check smb tdb
	for i in account_policy.tdb share_info.tdb registry.tdb; do
		smb_check_tdb /var/lib/samba/$i
	done
}

smb_poststart_smbd() {
	{
	/bin/sleep 1
	set_smbd_affinity
} &
}

smb_poststop_smbd() {
	local retry=10
	while [ $retry -gt 0 ] && pidof "smbd" >/dev/null; do
		sleep 1
		retry=$((retry-1))
	done
	smb_remove_smbd_temp_tdbs
	smb_remove_smbd_winbindd_share_tdbs
	proc_wait_stop smbd
}

smb_prestart_nmbd() {
	/usr/syno/bin/synobootseq --is-ready >/dev/null 2>&1
	if [ "$?" != "0" ]; then
		/usr/syno/sbin/synowin -checkwins
	fi
}

smb_prestart_winbindd() {
	smb_check_tdb /var/lib/samba/winbindd_idmap.tdb
	local szd_volume=`get_first_volume`
	if [ "x$szd_volume" != "x" ]; then
		local winbindcache="$szd_volume/winbindd_cache.tdb"
		if ! [ -e /usr/syno/etc/private/.db.domain_user -o -e /usr/syno/etc/private/.db.domain_group ]; then
			#no user/group db means joining new domain --> remove old winbindd_cache.tdb
			rm -f "$winbindcache"
		fi

		touch "$winbindcache"
		#samba3 winbindd_cache use cache_dir
		ln -s "$winbindcache" /var/cache/samba/winbindd_cache.tdb
		#samba4 winbindd_cache use stat_dir
		ln -s "$winbindcache" /var/lib/samba/winbindd_cache.tdb
	fi
	check_domain_migrate
	if [ $? -eq 0 ]; then
		touch "/tmp/domain_updating"
	fi
}

smb_poststart_winbindd() {
	check_domain_migrate
	if [ $? -eq 0 ]; then
		#wait winbindd ready
		{
			local retry=10
			/bin/sleep 5
			/usr/syno/sbin/synowin -updateDomain > /dev/null
			#wait for building the domain user/group db
			while [ $retry -gt 0 ]; do
				sleep 1;
				retry=$((retry-1))
				check_domain_migrate
				if [ $? -ne 0 ]; then
					break;
				fi
			done
			rm "/tmp/domain_updating"
		}&
	else
		if [ -e "/tmp/domain_updating" ]; then
			rm "/tmp/domain_updating"
		fi
	fi

}

smb_poststop_winbindd() {
	local retry=10
	while [ $retry -gt 0 ] && pidof "winbindd" >/dev/null; do
		sleep 1
		retry=$((retry-1))
	done
	smb_remove_winbindd_temp_tdbs
	smb_remove_smbd_winbindd_share_tdbs
	proc_wait_stop winbindd
	rm -f /usr/syno/etc/private/winbind_domain_list*
}

smb_start_nmbd() {
	message -n "start nmbd ... "

	if pidof nmbd >/dev/null; then
		warn "nmbd is running: `pidof nmbd`"
		return 1
	fi

	if /sbin/start nmbd > /dev/null 2>&1; then
		message "ok"
		return 0
	else
		warn "failed"
		return 1
	fi
}
smb_start_winbindd() {
	local log=
	message "start winbindd ... "


	if pidof winbindd >/dev/null; then
		warn "winbindd is running: `pidof winbindd`"
		return 1
	fi

	if /sbin/start winbindd > /dev/null 2>&1; then
		message "done"
		return 0
	else
		warn "failed"
		return 1
	fi
}
smb_start_smbd() {
	local smbspool=/var/spool/samba i=
	message "start smbd ... "


	if pidof smbd >/dev/null; then
		warn "smbd is running: `pidof smbd`"
		return 1
	fi

	if /sbin/start smbd > /dev/null 2>&1; then
		message "done"
		return 0
	else
		warn "failed"
		return 1
	fi
}

# actions
usage() { # void
	local H="[1m"
	local E="[0m"
	cat <<EOF
Usage: `basename $0` <actions>
Actions:
 $H start$E [options]            start samba by runkey in synoinfo.conf with
                             options.
 $H stop$E                       stop samba daemons
 $H restart$E                    restart service. equal to stop && start
 $H reload,hup$E                 reload config smb.conf
 $H force-reload$E               
 $H status$E                     show running status for samba daemon
 $H info$E                       show detail informations
 $H -h,--help,usage$E            show this help message
EOF
}
start() { # [options]
	local opt OPTARG OPTIND smb_opts="-D $@"
	if ! smb_is_enabled; then
		warn "samba is not configured for running"
		return ${LSB_ERR_CONFIGURED:-6}
	fi

	smb_remove_temp_tdbs
	
	smb_start_nmbd $smb_opts

	local security=`get_key_value /etc/samba/smb.conf security`
	case $security in
		domain|ads) smb_start_winbindd $smb_opts;;
	esac

	smb_start_smbd $smb_opts
}
stop() { # [options]
	local smb_running nmbd_running winbindd_running

	proc_stop smbd
	if [ $? -ne ${LSB_NOT_RUNNING:-7} ]; then
		proc_wait_stop smbd &
	fi

	proc_stop winbindd
	if [ $? -ne ${LSB_NOT_RUNNING:-7} ]; then
		proc_wait_stop winbindd &
	fi

	proc_stop nmbd
	if [ $? -ne ${LSB_NOT_RUNNING:-7} ]; then
		proc_wait_stop nmbd &
	fi

	wait
	smb_remove_temp_tdbs
}
status() { # void
	lsb_status nmbd
	lsb_status winbindd
	lsb_status smbd
	local ret=$?
	return $ret
}
restart() { # <void>
	stop
	start "$@"
}
reload() {
	proc_signal hup nmbd
	proc_signal hup winbindd
	proc_signal hup smbd
}

info() { # <void>
	if mount | grep -q "smb"; then
		echo mount
	else
		echo not mount
	fi
	echo ====== proc info ======
	proc_info smbd
	proc_info nmbd
	proc_info winbindd

	echo ====== smbstatus ======
	/usr/bin/smbstatus -d 0

	echo ====== tdbs ======
	echo `find /run /var/cache/samba /usr/syno/etc/ -name "*.tdb"`

	#file_dump /etc/resolv.conf
	#file_dump /usr/syno/etc/smb.conf "workgroup"
	#file_dump /var/log/winlock.state
	#file_dump /usr/syno/etc/private/workgroup
}

init_env
if [ $# -eq 0 ]; then
	action=status
else
	action=$1
	shift
fi

# dispatch actions
case $action in
	start|stop|status|usage|restart|reload)
		$action "$@"
		;;
	hup)
		reload "$@"
		;;
	force-reload)
		exit ${LSB_ERR_UNIMPLEMENTED:-3}
		;;
	-h|--help)
		usage "$@"
		;;
# for debugging
	info)
		$action "$@"
		;;
	test_*)
		local fn=${action#test_}
		$fn "$@"
		;;
	prestart_smbd)
		smb_prestart_smbd
		;;
	poststart_smbd)
		smb_poststart_smbd
		;;
	poststop_smbd)
		smb_poststop_smbd
		;;
	prestart_nmbd)
		smb_prestart_nmbd
		;;
	poststop_nmbd)
		proc_wait_stop nmbd
		;;
	prestart_winbindd)
		smb_prestart_winbindd
		;;
	poststart_winbindd)
		smb_poststart_winbindd
		;;
	poststop_winbindd)
		smb_poststop_winbindd
		;;
	*)
		usage "$@" >&2
		exit ${LSB_ERR_ARGS:-2}
		;;
esac
