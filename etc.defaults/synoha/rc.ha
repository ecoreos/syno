#!/bin/bash
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

# description: Synology High Availability Package
# processname:
#
### BEGIN INIT INFO
# Provides:
# Required-Start:       $network $syslog
# Required-Stop:        $network $syslog
# Default-Start:
# Default-Stop:
# Short-Description:    Starts and stops Synology High Availability Package
# Description:          Starts and stops Synology High Availability Package
### END INIT INFO

HA_PREFIX="/usr/syno/synoha"
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/syno/sbin:/usr/syno/bin:$HA_PREFIX/sbin:$HA_PREFIX/bin
ROOT_PROFILE=/root/.profile

. /etc.defaults/rc.subr
. $HA_PREFIX/etc.defaults/rc.subr
. $HA_PREFIX/etc.defaults/serv_conf_def.sh

SYNOINFO="/etc/synoinfo.conf"
RUN_HA=`get_key_value $SYNOINFO runha`
SUPPORT_HA=`get_key_value $SYNOINFO support_ha`

HA_INFO=$HA_PREFIX/etc/ha.conf
DRBD_IP0=`get_key_value $HA_INFO drbd_ip0`
DRBD_IP1=`get_key_value $HA_INFO drbd_ip1`
DRBD_IF=`get_key_value $HA_INFO drbd_if`
DRBD_NETMASK=`get_key_value $HA_INFO drbd_netmask`

RC_FLOCK="/tmp/.ha.rc.lock"

SYNO_DRBD_STOPPING="/tmp/.drbd.stopping"
SYNO_DRBD_STOP_CHECK="/tmp/.drbd.stop.check"

# Used in libsynosdk/lib/ha/ha_is_running
# MUST modify that at the same time
# this file is created when rc.ha start, and kept to poweroff/reboot,
# this is for ha disable, after ha disable and before reboot,
# the state should be still in "ha running"
# #146, crash after disable ha
SYNO_HA_RUNNING=$HA_RUNNING
SYNO_HA_NOT_RUNNING=$HA_NOT_RUNNING

SYNO_DRBD_DEMOTE_ERROR=$HA_DRBD_DEMOTE_ERR
SYNO_UNBIND_WITH_REBOOT=$UNBIND_WITH_REBOOT
SYNO_CONF_NOT_EXISTING=$CONF_NOT_EXISTING
SYNO_NO_ACTIVE=$NO_ACTIVE
SYNO_SPLIT_BRAIN=$SPLIT_BRAIN
SYNO_SWITCH_FAIL=$SWITCHOVER_FAIL
SYNO_REMOVED_FROM_HA=$REMOVED_FROM_HA
SYNO_SPACE_NOT_SYNCED=$SPACE_NOT_SYNCED
SYNO_HA_TMP_DIR=$HA_TMP_DIR
SYNO_HA_PREV_ACTIVE=$PREVIOUS_ROLE_ACTIVE
SYNO_HA_PREV_PASSIVE=$PREVIOUS_ROLE_PASSIVE

SYNO_HA_ROLE_ACTIVE=$ROLE_ACTIVE
SYNO_HA_ROLE_PASSIVE=$ROLE_PASSIVE
SYNO_HA_ROLE_PREPARE=$ROLE_PREPARE
SYNO_HA_ROLE_PREACTIVE=$ROLE_PREACTIVE
SYNO_HA_ROLE_UNKNOWN=$ROLE_UNKNOWN
SYNO_HA_UNBINDING=$UNBINDING
SYNO_HA_START_DONE=$RC_HA_START_DONE
FLAG_HA_SXX_ROLE_PREACTIVE=$SXX_ROLE_PREACTIVE
FLAG_HA_SXX_ROLE_PREPASSIVE=$SXX_ROLE_PREPASSIVE
FLAG_HA_HANDLING_TOO_ACTIVE="/tmp/ha/.handling_too_active"
FLAG_HA_REMOTE_SHUTDOWN_FIRST=$REMOTE_SHUTDOWN_FLAG
FLAG_HA_PASSIVE_WAIT_FSCK=$WAIT_FSCK_FLAG

SYNO_PACE_CRM="$HA_PREFIX/var/lib/heartbeat/crm"
SYNO_PACE_HANDLE_AIS="$HA_PREFIX/sbin/handle_ais.sh"
SYNO_PACE_HANDLE_AIS_TMP="/tmp/ha/handle_ais.sh"
SYNO_HA_SYS_REC="$HA_PREFIX/etc.defaults/UtilRec.sh"
SYNO_HA_SYS_REC_TMP="/tmp/ha/UtilRec.sh"

SYNO_HA_CRM_VERIFY="/usr/bin/crm_verify"
SYNO_HA_CIB_XML="$SYNO_PACE_CRM/cib.xml"
SYNO_HA_CIB_REC_XML="/var/log/cluster/.cib.xml.corrupted"

SYNOVSPACE="/usr/syno/bin/synovspace"
SYNOSTGSYSRAID="/usr/syno/sbin/synostgsysraid"
IP2UTIL="ip"

log_err()
{
	if [ -z "${1}" ]; then
		while read line; do
			logger -p user.err -t "rc.ha[$$]" "[HA-ERROR] ${line}"
		done
	else
		logger -p user.err -t "rc.ha[$$]" "[HA-ERROR] ${1}"
	fi
}

log_warn()
{
	if [ -z "${1}" ]; then
		while read line; do
			logger -p user.warning -t "rc.ha[$$]" "[HA-WARN] ${line}"
		done
	else
		logger -p user.warning -t "rc.ha[$$]" "[HA-WARN] ${1}"
	fi
}

log_notice()
{
	if [ -z "${1}" ]; then
		while read line; do
			logger -p user.notice -t "rc.ha[$$]" "[HA-NOTICE] ${line}"
		done
	else
		logger -p user.notice -t "rc.ha[$$]" "[HA-NOTICE] ${1}"
	fi
}

corosync_start()
{
	# already running
	check_alive corosync && return 0

	if [ ! -r "$HA_PREFIX/etc/corosync/corosync.conf" ]; then
		log_err "corosync.conf doesn't exist or is unreadable"
		return 1
	fi

	if ! cp -f $SYNO_PACE_HANDLE_AIS $SYNO_PACE_HANDLE_AIS_TMP &> /dev/null; then
		log_err "copy handle ais file error"
		return 1
	fi

	if ! corosync &> /dev/null; then
		log_err "Failed to execute corosync [errno=$?]"
		return 1
	fi

	# wait for all plugings ready
	sleep 10

	# wait for sync with remote
	#sleep 60
	check_alive corosync
}

corosync_stop()
{
	if check_alive pacemakerd; then
		log_notice "pacemakerd should be stopped first"
		pacemaker_stop
	fi

	corosync-cfgtool -H &> /dev/null &

	# corosync-cfgtool may hang too
	wait_for "! check_alive corosync" 60
	wait_for "! check_alive corosync-cfgtool" 60

	if check_alive corosync-cfgtool; then
		/usr/bin/killall -s TERM corosync-cfgtool &> /dev/null
		/usr/bin/killall -s KILL corosync-cfgtool &> /dev/null
	fi

	# kill corosync in reverse order
	for id in `/bin/pidof corosync | tr -s ' ' '\n' | sort -nr`; do
		kill_proc_id $id corosync
	done

	rm -f $SYNO_PACE_HANDLE_AIS_TMP
}

python_check()
{
	PY_PATH="/usr/lib/python2.7/"
	PY_PASS="true"
	# the import command of synocrm is reference from crm command
	local item=0
	eval a$item=\"\"

	item=$(($item + 1))
	eval a$item=\"from synocrm import main\"

	item=$(($item + 1))
	eval a$item=\"from cts import CTS\"

	item=$(($item + 1))
	eval a$item=\"from distutils import version\"

	item=$(($item + 1))
	eval a$item=\"from distutils import sysconfig\"

	log_notice "check python start"

	local i
	local err
	for i in `seq 0 1 $item` ; do
		eval python -c \"\$a$i\" &>/dev/null
		if [ "$?" != "0" ]; then
			eval python -c \"\$a$i\" 2>&1 | log_err
			eval err=\"\$a$i\"
			log_err "check \"$err\" failed"
			PY_PASS=
			break
		fi
	done

	if [ -z "$PY_PASS" ]; then
		log_err "detect python failed, cleanup"
		find $PY_PATH | grep -e "\.pyc$" -e "\.pyo$" | xargs -r rm
	else
		log_notice "check python pass"
	fi

	log_notice "python path:"
	python -c "import sys; print sys.path" 2>&1 | log_notice
}

check_cib_and_record()
{
	local CIB_FAIL=`$SYNO_HA_CRM_VERIFY -x $SYNO_HA_CIB_XML 2>&1`
	if [ -n "$CIB_FAIL" ]; then
		local last_cib_record_file=`ls -t ${SYNO_PACE_CRM}/cib-*.raw | head -n 1`

		log_err "Failed to verify ${SYNO_HA_CIB_XML}, recover from known good version"
		mv $SYNO_HA_CIB_XML $SYNO_HA_CIB_REC_XML &> /dev/null
		cp $last_cib_record_file $SYNO_HA_CIB_XML &> /dev/null
	fi
}

pacemaker_start()
{
	if [ -f "$SYNO_HA_CIB_XML" ]; then
		log_notice "start cib check"
		check_cib_and_record
	fi

	# Pacemaker is already running

	check_alive crmd && return 0

	# Pacemaker depends on Corosync
	check_alive corosync || corosync_start

	python_check

	if ! pacemakerd &> /dev/null; then
		log_err "Failed to execute pacemakerd [errno=$?]"
	fi

	# pacemaker will fork children in the following sequence:
	# stonithd -> cib -> lrmd -> attrd -> pengine -> crmd
	wait_for "check_alive crmd" 30

	check_alive crmd
}

pacemaker_stop()
{
	pacemakerd -S &> /dev/null &

	# pacemakerd takes a short time to terminate all children in reverse order.
	wait_for "! check_alive pacemakerd" 60

	for proc in pacemakerd stonithd cib lrmd attrd pengine crmd; do
		if check_alive $proc; then
			/usr/bin/killall -s KILL $proc &> /dev/null
		fi
	done
}

drbd_node_gen()
{
	local _i=

	for _i in $(/usr/bin/seq 0 127); do
		[ -b /dev/drbd$_i ] || mknod -m 0660 /dev/drbd$_i b 147 $_i
	done
}

drbd_start()
{
	while [ -f $SYNO_DRBD_STOPPING ]; do
		sleep 2
	done

	if [ -d /initrd ]; then
		drbd_node_gen
	fi

	# insert modules, must in order: loop->cn->hmac->libcrc32->drbd
	loop_node_gen
	SYNOLoadModules loop
	SYNOLoadModules cn hmac libcrc32c
	SYNOCheckModule drbd || insmod /lib/modules/drbd.ko

	add_drbdip_to_drbdif
	add_hbip_to_hosts

	if [ "$1" != "setup" ]; then
		log_notice "vspace stage-load before ha"
		$SYNOVSPACE -stage-load before ha
		synodrbd --drbd-start-exist &> /dev/null
	fi

	return 0
}

drbd_stop()
{
	touch $SYNO_DRBD_STOPPING
	touch $SYNO_DRBD_STOP_CHECK

	{
	synodrbd --drbd-stop-all &> /dev/null

	$DRBDADM secondary all &> /dev/null
	$DRBDADM down all &> /dev/null

	log_notice "losetup before unload loop module (should be empty!)"
	log_notice "$(/sbin/losetup -a)"
	# remove loop devices used by drbd: loop.vg1-volume_2, loop.md2...
	for i in $(ls /dev/loop.* 2>/dev/null); do /sbin/losetup -d $i; done;

	# SYNOUnloadMoules would remove them in reverse order
	#SYNOUnloadModules cn hmac libcrc32c drbd
	SYNOUnloadModules drbd
	SYNOUnloadModules loop
	rm -f $SYNO_DRBD_STOP_CHECK
	}&

	local retry=0
	while [ 1 ]; do
		if [ ! -f $SYNO_DRBD_STOP_CHECK ]; then
			break
		fi
		if [ $retry -gt 180 ]; then
			log_err "wait drbd stop timeout"
			break
		fi
		sleep 1
		retry=`expr $retry + 1`
	done

	NOW_DRBD_IF=`$IP2UTIL -o -f inet addr show | grep DRBD \
		| cut -d ' ' -f2 | grep -v '^ipsec[0-9][0-9]*$'`
	ifconfig ${NOW_DRBD_IF:-eth0}:DRBD down &> /dev/null
	remove_hbip_from_hosts
	rm -f $SYNO_DRBD_STOPPING

	return 0
}

check_hostname_original()
{
	# DSM#68958 - ensure hostname reset to original
	local origin_hostname_file=$CRM_HOSTNAME_ORIGINAL
	local origin_hostname=`cat $origin_hostname_file`
	local hostname_uname=`uname -n`
	local hostname_lnx=`cat /etc/hostname`

	if [ -z "$origin_hostname_file" ] || [ ! -f "$origin_hostname_file" ]; then
		log_err "error: failed to get original hostname from: ${origin_hostname_file}."
		return
	fi

	if [ -z "$origin_hostname" ]; then
		log_err "error: empty original hostname"
		return
	fi

	if [ "$origin_hostname" != "$hostname_uname" -o "$origin_hostname" != "$hostname_lnx" ]; then
		log_err "warning: force set origin hostname again[$hostname_uname,$hostname_lnx]"
		hostname $origin_hostname
		echo "$origin_hostname" > /etc/hostname
		log_err "set hostname to [`uname -n`,`cat /etc/hostname`]"
		synoservice --reload syslog-ng
	fi
}

check_syslog_status()
{
	# DSM#69334 - ensure syslog-ng is running
	synoservice --is-enabled syslog-ng
	local enabled=$?
	synoservice --status syslog-ng
	local status=$?

	if [ 1 -ne $enabled ]; then
		touch "/var/log/ha.detect.syslog-ng.not.enabled"
		synoservice --start syslog-ng
		sleep 5
		log_err "syslog-ng is not enabled, enable it"
		synoservice --status syslog-ng
		status=$?
	fi
	if [ 0 -ne $status ]; then
		touch "/var/log/ha.detect.syslog-ng.not.running"
		synoservice --restart syslog-ng
		sleep 5
		log_err "syslog-ng is not ready, force start again"
	fi
}

# For all other init-scripts actions, the init script shall return an exit
# status of zero if the action was successful. Otherwise, the exit status
# shall be non-zero, as defined below. In addition to straightforward success
# , the following situations are also to be considered successful:
#
# - restarting a service (instead of reloading it) with the force-reload argument
# - running `start` on a service already running
# - running `stop` on a service already stopped or not running
# - running `restart` on a service already stopped or not running
# - running `try-restart` on a service already stopped or not running
#
# In case of an error while processing any init-script action except for
# `status`, the init script shall print an error message and exit with a
# non-zero code:
#
# 0             successful
# 1             generic or unspecified error
# 2             invalid or excess argument(s)
# 3             unimplemented feature (for example, `reload`)
# 4             user had insufficient privilege
# 5             program is not installed
# 6             program is not configured
# 7             program is not running
# 8-99          reserved for future LSB use
# 100-149       reserved for distribution use
# 150-199       reserved for application use
# 200-254       reserved
start()
{
	local PREFIX="/usr/syno/synoha"

	log_warn "rc.ha_start begin"

	if ! check_alive $SYNOHA_MON_MD0; then
		log_notice "Run daemon $SYNOHA_MON_MD0"
		$SYNOHA_MON_MD0 & > /dev/null
	fi

	if ! cp -f $SYNO_HA_SYS_REC $SYNO_HA_SYS_REC_TMP &> /dev/null; then
		log_err "copy UtilRec file error"
	elif ! check_alive $SYNOHA_REC_SYS; then
		log_notice "Run daemon $SYNOHA_REC_SYS"
		$SYNOHA_REC_SYS & > /dev/null
	fi

	mkdir -p /var/run/ha
	mkdir -p /var/lib/ha
	mkdir -p /var/lib/ha/sync
	rm -f $FLAG_DRBD_DISCARD_MYDATA
	rm -f $HA_PREFIX/var/log/cluster/ais.action
	rm -f $SYNO_HA_START_DONE
	synoha --mkdir-ha-folder

	if [ -e $SYNO_HA_UNBINDING ]; then
		# unbind local if last unbind-local failed
		log_err "Last unbind-local failed. unbind-local again"
		rm -f $SYNO_HA_UNBINDING
		unlock
		synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$SYNO_CONF_NOT_EXISTING" &> /dev/null &
		# wait reboot after unbind local
		sleep 300
		unlock
		reboot -f
	fi

	log_notice "check conf file"
	if [ "$1" != "setup" ] && ! synoha --check-conf-file &> /dev/null; then
		# unbind local if necessary conf files not exist
		log_err "Necessary conf files not existing. unbind-local"
		unlock
		synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$SYNO_CONF_NOT_EXISTING" &> /dev/null &
		# wait reboot after unbind local
		sleep 300
		unlock
		reboot -f
	fi

	log_notice "set hostname from `uname -n`"
	synoha --set-hostname-original

	check_hostname_original
	check_syslog_status

	log_notice "orig hostname: `uname -n`"
	synoha --gen-hostname-file-tmp

	synoha --remove-wrong-vg

	rm -f "$SYNO_HA_NOT_RUNNING"
	touch "$SYNO_HA_RUNNING"

	if [ "$1" == "setup" ]; then
		diskDev="`synodiskport -internal`"
		diskDev="$diskDev `synodiskport -esata`"
		diskDev="$diskDev `synodiskport -eunit`"
		diskDev="$diskDev `synodiskport -cache`"
		echo $diskDev | tr ' ' '\n' | xargs -n 1 -I DEV sh -c "echo deadline > /sys/block/DEV/queue/scheduler"
	fi

	if [ -f "$SYNO_DRBD_DEMOTE_ERROR" ]; then
		# just a log now,
		# if remote is active, passive will discard my data
		log_err "Drbd demote error ever."

		# unbind local if drbd demote error because split brain will occur
		#log_err "Drbd demote error. unbind-local"
		rm -f $SYNO_DRBD_DEMOTE_ERROR
		#unlock
		#synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$SYNO_SWITCH_FAIL" &> /dev/null &
		# wait reboot after unbind local
		#sleep 300
		#unlock
		#reboot -f
	fi

	if [ -f "$SYNO_HA_UPG" ]; then
		log_notice "ha upgrade after boot"

		# unload which is loaded by prepare-for-upg
		$HA_PREFIX/etc.defaults/rc.volume stop
		$SYNOVSPACE -stage-unload equal ha
		$DRBDADM secondary all &> /dev/null
		$DRBDADM down all &> /dev/null
		drbd_stop

		$SYNOVSPACE -stage-unload after ha
		synoha --upg-after-boot &
	fi

	if [ "$1" != "setup" ]; then
		log_notice "start service ha must"
		RCMsg "Starting essential services" \
		StartServicesHA MUST
	fi

	if [ "$1" = "setup" ]; then
		log_notice "Setup ha, skip check if in ha"
	elif [ -f "$SYNO_HA_UPG" ] && $SYNOHA_BIN --upg-is-active &> /dev/null; then
		log_notice "Upgrading active, skip check if in ha"
	elif [ -f "$SYNO_HA_UPG" ] && [ ! -f $UPGRADE_FROM_VERSION_AFTER_6_0_BETA_2 ]; then
		log_notice "Upgrading passive from 5.2, skip check if in ha"
	else
		if [ -f "$SYNO_HA_UPG" ]; then
			synoha --isolate-restore
			sleep 5
		fi
		log_notice "check if in ha"
		local retry=0
		# try to check if in ha
		while [ 1 ];
		do
			if ! synoha --is-in-ha &> /dev/null; then
				# unbind local if not in ha
				log_err "This node is not in HA cluster. unbind-local"
				unlock
				synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$SYNO_REMOVED_FROM_HA" &> /dev/null &
				# wait reboot after unbind local
				sleep 300
				unlock
				reboot -f
			fi

			# check more times to make sure
			if [ $retry -gt 2 ]; then
				log_notice "check if in ha end"
				break
			fi
			sleep 3
			retry=`expr $retry + 1`
		done

		if [ -f "$SYNO_HA_UPG" ]; then
			synoha --isolate-apply
		fi
	fi

	# dump disk info after drbd sync
	synoha --dump-disk-info

	synoha --clean-state

	# standby always, although "rc.ha stop" will standby it
	# but it maybe keep last state after abnormal power off
	log_notice "standby local"
	if [ -f "$SYNO_PACE_CRM/cib.xml" ] ; then
		rm -f $SYNO_PACE_CRM/cib.xml.sig
		local _old="\"nodes-$LOCAL_HOST-standby\" name=\"standby\" value=\"off\""
		local _new="\"nodes-$LOCAL_HOST-standby\" name=\"standby\" value=\"on\""
		sed "s/$_old/$_new/g" "$SYNO_PACE_CRM/cib.xml" > "$SYNO_PACE_CRM/cib.xml.new"
		mv $SYNO_PACE_CRM/cib.xml.new $SYNO_PACE_CRM/cib.xml
	fi

	# TODO: Only copy cached items
	grep -v corosync_key $HA_INFO > $HA_TMP_INFO

	log_notice "start drbd"
	RCMsg "Starting drbd" \
	drbd_start $1

	log_notice "start corosync"
	RCMsg "Starting corosync" \
	corosync_start

	log_notice "start pacemakerd"
	RCMsg "Starting pacemakerd" \
	pacemaker_start

	rm -fr $SYNO_HA_NOT_RUNNING

	# run online background because it will block (~120s) if peer is not online
	{
		local BOOT_FROM_SAFEMODE=false
		if [ "$1" != "setup" ]; then
			log_notice "wake remote"
			synoha --wake-remote &
			# must run safemode just after pacemaker_start
			if [ -f "$SYNO_HA_SAFEMODE" ]; then
				BOOT_FROM_SAFEMODE=true
				if [ -f $SYNO_HA_PREV_ACTIVE ]; then
					log_warn "SB: Local become active"
					synoha --remove-local-constraint

					# restore user settings
					ha_safemode_restore_user_settings

					rm -f $SYNO_HA_SAFEMODE
					rm -rf $HA_SAFEMODE_DIR
					log_warn "SB: end of safemode (active)"
				elif [ -f "$SYNO_HA_PREV_PASSIVE" ]; then
					log_warn "SB: Local become passive"
					rm -f $SYNO_HA_SAFEMODE
					rm -rf $HA_SAFEMODE_DIR
					log_warn "SB: end of safemode (passive)"
				else
					if `synoha --check-remote-in-safemode | grep -iqE "(true)|(unknown)"`; then
						log_warn "SB: HA Safemode! Skip to check remote"
						$HA_PREFIX/sbin/handler_sb.sh safemode --boot
						exit $?
					else
						log_warn "SB: Warning: Remote should be active, Local become passive"
						touch "$SYNO_HA_PREV_PASSIVE"
					fi
				fi
			fi # split brain booting section

			log_notice "wait local online"
			local cntWaitOnline=0
			while [ 1 ]; do
				if synoha --local-status | cut -d':' -f2 | grep -q "$SYNO_HA_STATUS_ONLINE"; then
					log_notice "local online"
					break
				fi
				if synoha --local-status | cut -d':' -f2 | grep -q "$SYNO_HA_STATUS_WARNING_ONLINE"; then
					log_notice "local standby"
					break
				fi
				cntWaitOnline=`expr $cntWaitOnline + 1`
				if [ $cntWaitOnline -ge 30 ]; then
					log_err "wait local online timeout `synoha --local-status`"
					break
				fi
				sleep 2
			done

			sleep 10

			log_notice "check role"
			# wait remote if previous role is passive
			local cntWaitActive=0
			if [ -f "$SYNO_HA_UPG" ] ; then
				log_notice "Upgrading! Skip to check remote active."
			elif [ -f $SYNO_HA_PREV_ACTIVE ] ; then
				# prev role active, skip wait
				log_notice "prev role active. remote `synoha --remote-role` local `synoha --local-role`"
			elif [ -f $SYNO_HA_PREV_PASSIVE ]; then
				log_notice "prev role passive. remote `synoha --remote-role` local `synoha --local-role`"
				local waitActiveSleep=30
				local maxWaitActive=$(( $MAX_HA_PASSIVE_ONLY / $waitActiveSleep ))
				while :; do
					local localRole=`synoha --local-role`
					local remoteRole=`synoha --remote-role`
					if [ "$SYNO_HA_ROLE_ACTIVE" == "$remoteRole" ]; then
						log_notice "remote active."
						break
					fi
					# if local is active automatically after boot, then we can skip the wait too
					if [ "$SYNO_HA_ROLE_ACTIVE" == "$localRole" ]; then
						log_notice "local active."
						break
					fi
					if [ "$SYNO_HA_ROLE_PREACTIVE" == "$localRole" ]; then
						log_notice "local preactive."
						break
					fi
					if synoha --remote-has-constraint; then
						if ! $BOOT_FROM_SAFEMODE; then
							log_notice "remote has constraint."
							break
						else
							log_notice "remote has constraint (safemode)."
						fi
					fi
					if synoha --remote-has-failed-crm-op; then
						log_notice "remote has failed crm operation"
						break;
					fi
					cntWaitActive=`expr $cntWaitActive + 1`
					if [ $cntWaitActive -ge $maxWaitActive ]; then
						if [ -f "$SZF_HA_IN_UPS_SAFEMODE" ]; then
							log_notice "Enter UPS safemode"
							enter_ups_safemode
							exit
						fi

						if [ -f $FLAG_HA_PASSIVE_WAIT_FSCK ]; then
							log_notice "wait remote active file system checking, shutdown passive now."
						elif $BOOT_FROM_SAFEMODE; then
							log_err "can't wait remote become active after safemode, shutdown now"
							touch $SYNO_HA_SAFEMODE
						else
							log_err "wait remote active timeout, remote $remoteRole local $localRole, poweroff"
							synoha --notify passive-timeout $LOCAL_HOST $REMOTE_HOST &> /dev/null &
						fi
						sync
						synoha --poweroff-ds &> /dev/null &
						sleep 300
						poweroff -f
					fi
					sleep $waitActiveSleep
				done
			else
				# no prev_active and no prev_passive
				# abnormal shutdown?! sleep a random time
				log_notice "prev role unknown."
				if synoha --remote-role | grep -q $SYNO_HA_ROLE_ACTIVE; then
					log_notice "remote active."
				elif synoha --local-role | grep -q $SYNO_HA_ROLE_ACTIVE; then
					log_notice "local active."
				elif synoha --local-role | grep -q $SYNO_HA_ROLE_PREACTIVE; then
					log_notice "local preactive."
				elif synoha --remote-has-constraint; then
					log_notice "remote passive."
				elif synoha --remote-has-failed-crm-op; then
					log_notice "remote has failed crm operation"
				else
					local rand=$(( $RANDOM % 120 ))
					log_notice "prev role unknown, sleep $rand"
					sleep $rand
				fi
			fi

			log_notice "wait remote prepare finish"
			# wait remote not prepare, maybe remote is starting to active (may take 5 min)
			local cntWaitPrepare=0
			local waitPrepareSleep=30
			local maxWaitPrepare=$(( $MAX_HA_SERV_START_FAST_SEC / $waitPrepareSleep ))
			while [ ! -f $SYNO_HA_PREV_ACTIVE ]; do
				if [ -f "$SYNO_HA_UPG" ] ; then
					log_notice "Upgrading!Skip to check remote prepare."
					break
				fi
				if synoha --remote-role | grep -v -q -e "$SYNO_HA_ROLE_PREPARE" -e "$SYNO_HA_ROLE_PREACTIVE"; then
					log_notice "remote `synoha --remote-role`"
					break
				fi
				cntWaitPrepare=`expr $cntWaitPrepare + 1`
				if [ $cntWaitPrepare -ge $maxWaitPrepare ]; then
					log_err "wait remote prepare finish timeout `synoha --remote-role`"
					break
				fi
				sleep $waitPrepareSleep
			done

			# remote unknown, need to record more info
			if synoha --remote-role | grep -q "$SYNO_HA_ROLE_UNKNOWN"; then
				corosync-cpgtool | log_notice
				crm_mon -S | log_notice
				log_notice "local hostname: `hostname`"
				if [ ! -f "$SYNO_HA_UPG" ] ; then
					rm -rf /var/lib/ha/bad /var/lib/ha/bad.tgz
					/usr/syno/bin/synomsg_collector2 /var/lib/ha/bad &> /dev/null
					rm -f /var/lib/ha/bad/var/log/ha.last.debug.dat
					/usr/bin/tar czhf /var/lib/ha/bad.tgz /var/lib/ha/bad &> /dev/null
					rm -rf /var/lib/ha/bad
				fi
			fi

			rm -f $SYNO_HA_PREV_ACTIVE
			rm -f $SYNO_HA_PREV_PASSIVE
			rm -f $SZF_HA_IN_UPS_SAFEMODE

			# discard my data if remote is active
			remoteRole=`synoha --remote-role`
			if [ "$SYNO_HA_ROLE_ACTIVE" == "$remoteRole" ]; then
				log_notice "check if sync active"
				synodrbd --check-if-sync-active &> /dev/null
				log_notice "discard my data"
				touch $FLAG_DRBD_DISCARD_MYDATA
				synodrbd --check-if-discard &> /dev/null
				UnpinCache
			fi

			# standby again to prevent cib xml confuse
			log_notice "crm standby"
			if synoha --local-status | cut -d':' -f2 | grep -q "$SYNO_HA_STATUS_WARNING_ONLINE"; then
				synoha --standby-local
			fi

			# before online, check the pacemaker and corosync process again
			for proc in pacemakerd stonithd cib lrmd attrd pengine crmd corosync; do
				if ! check_alive $proc; then
					log_err "$proc is not running, reboot"
					unlock
					reboot &
					sleep $MAX_HA_SERV_STOP_SEC
					unlock
					reboot -f
				fi
			done

			if [ -f "$SYNO_HA_UPG" ]; then
				synoha --remove-local-constraint
				if synoha --upg-is-active; then
					synoha --upg-crm-conf
				fi
			fi

			if [ ! -f "$FLAG_DRBD_DISCARD_MYDATA" ]; then
				# self should be active
				synoha --crm-clean-state &> /dev/null
			fi

			log_notice "crm online"
			# Wait ready and online myself
			sleep 10
			synoha --online &> /dev/null

			log_notice "check crm done"
			synoha --wait-crm-done
			if ! synoha --local-role | grep -q $SYNO_HA_ROLE_ACTIVE; then
				rm -f $FLAG_HA_SXX_ROLE_PREACTIVE
				touch $FLAG_HA_SXX_ROLE_PREPASSIVE
				# role is decided, resume hotplugd on passive
				synoservice --resume-by-reason hotplugd ha-passive
				# active will call "StartServicesHA DONE" in ocf_wrapper_serv:start
				StartServicesHA DONE
			fi

			if synoha --local-role | grep -q $SYNO_HA_ROLE_ACTIVE; then
				if $BOOT_FROM_SAFEMODE; then
					log_notice "SB: clean constraint RULE_SB (passive)"
					crm configure delete RULE_SB_$REMOTE_HOST 2>&1 | log_notice
					for i in `seq 1 100`; do
						if cibadmin -Q --xpath '//rsc_location[@id="'RULE_SB_$REMOTE_HOST'"]' &> /dev/null; then
							if [ $i -ge 100 ]; then
								log_err "SB: Failed to clean constraint RULE_SB (passive)"
							else
								log_notice "SB: Failed to clean constraint RULE_SB (passive). Try again: $i"
								sleep 1
								crm configure delete RULE_SB_$REMOTE_HOST 2>&1 | log_notice
							fi
						else
							break
						fi
					done
				fi
				log_notice "check space sync"
				synodrbd --check-space-sync &> /dev/null
				log_notice "check memory size"
				synoha --check-memsize-when-cache-exist &> /dev/null
				log_notice "check flashcache setting"
				synoha --check-flashcache-sysctl &> /dev/null
			elif synoha --local-role | grep -q $SYNO_HA_ROLE_PASSIVE; then
				$SYNOSTGSYSRAID --sync &
			fi
		fi

		if [ "x$REMOTE_HOST" != "x" ]; then
			crm_node --node="$REMOTE_HOST" --mesg="$SZ_HA_NODE_ONLINE$LOCAL_HOST"
		fi

		log_notice "wake remote"
		synoha --wake-remote &

		touch $SYNO_HA_START_DONE
		log_warn "rc.ha_start end"

		if [ "$1" == "setup" ]; then
			log_notice "setup ha, skip msg collector"
		else
		{
			# synomsg_collector will call rc.ha again, so let it run in background
			# from #55141, synomsg_collector2 will collect log to a directory
			sleep 10
			rm -rf "$SYNO_HA_LAST_DEBUG_DAT" "${SYNO_HA_LAST_DEBUG_DAT}.dir"
			/usr/syno/bin/synomsg_collector2 "${SYNO_HA_LAST_DEBUG_DAT}.dir" &> /dev/null
			/usr/bin/tar czhf "$SYNO_HA_LAST_DEBUG_DAT" "${SYNO_HA_LAST_DEBUG_DAT}.dir" &> /dev/null
			rm -rf "${SYNO_HA_LAST_DEBUG_DAT}.dir"
		}&
		fi
	}&

	# ATTENTION!! make sure the following code will run immediately WITH crm online
	# NOT run AFTER crm online

}
wait_remote_shutdown()
{
	log_notice "wait remote shutdown"
	retry=0
	until synoha --remote-status | grep offline;
	do
		if [ $retry -gt $MAX_HA_SERV_STOP_SEC ]; then
			log_err "wait remote shutdown finish timeout"
			break
		fi
		sleep 1
		retry=`expr $retry + 1`
	done
}
send_shutdown_flag()
{
	if ! $SYNOHA_BIN --check-ha-is-binding; then
		log_notice "send shutdown flag"
		for i in `seq 1 1 5`
		do
			synoha --send-shutdown-flag
			sleep 2
		done
	fi
}
handle_manually_reboot_sametime_active()
{
	if [ -f "$FLAG_HA_REMOTE_SHUTDOWN_FIRST" ]; then
		wait_remote_shutdown
		log_notice "set prev role active"
		touch $SYNO_HA_PREV_ACTIVE
	else
		send_shutdown_flag
		if [ -f "$FLAG_HA_REMOTE_SHUTDOWN_FIRST" ]; then
			wait_remote_shutdown
			log_notice "set prev role active"
			touch $SYNO_HA_PREV_ACTIVE
		else
			log_notice "set prev role passive"
			touch $SYNO_HA_PREV_PASSIVE
		fi
	fi
}
handle_manually_reboot_sametime_passive()
{
	if [ -f "$FLAG_HA_REMOTE_SHUTDOWN_FIRST" ]; then
		log_notice "set prev role active"
		touch $SYNO_HA_PREV_ACTIVE
	else
		send_shutdown_flag
		log_notice "set prev role passive"
		touch $SYNO_HA_PREV_PASSIVE
	fi
}
stop()
{
	rm -f $FLAG_DRBD_DISCARD_MYDATA
	if [ ! -f "$SYNO_DRBD_DEMOTE_ERROR" -a ! -f "$SYNO_HA_SAFEMODE" -a ! -f "$SYNO_HA_PING" ]; then
		log_warn "rc.ha_stop begin"

		log_notice "local role.`synoha --local-role`"
		log_notice "local status.`synoha --local-status`"

		if synoha --local-role | grep -q $SYNO_HA_ROLE_PREPARE; then
		if synoha --local-status | cut -d':' -f2 | synohagrep $SYNO_HA_STATUS_ONLINE -q; then
			log_notice "wait local prepare finish"
			retry=0
			while [ 1 ]; do
				if ! synoha --local-role | grep -q $SYNO_HA_ROLE_PREPARE; then
					log_notice "local prepare done,`synoha --local-role` now."
					break
				fi
				if synoha --local-has-failed-crm-op ; then
					log_notice "Detect failed operation, standby local now."
					log_notice "Remote role: `synoha --remote-role`"
					synoha --standby-local
				fi
				if [ $retry -gt $MAX_HA_SERV_START_FAST_SEC ]; then
					log_err "wait local prepare finish timeout"
					break
				fi
				sleep 1
				retry=`expr $retry + 1`
			done
		fi
		fi

		if synoha --local-role | grep -q $SYNO_HA_ROLE_ACTIVE; then
			if [ -f $SZF_HA_IN_UPS_SAFEMODE ]; then
				log_notice "set prev role passive"
				touch $SYNO_HA_PREV_PASSIVE
			elif synoha --remote-role | grep -q $SYNO_HA_ROLE_PASSIVE; then
				if synoha --remote-has-constraint; then
					log_notice "set prev role active"
					touch $SYNO_HA_PREV_ACTIVE
				elif synobootseq --is-safe-shutdown &>/dev/null ; then
					log_notice "set prev role active"
					touch $SYNO_HA_PREV_ACTIVE
				else
					handle_manually_reboot_sametime_active
				fi
			else
				log_notice "set prev role active"
				touch $SYNO_HA_PREV_ACTIVE
			fi
		else
			handle_manually_reboot_sametime_passive
		fi

		synoha --dump-disk-info

		log_notice "standby local"
		# Standby myself to make all services/drbd down
		synoha --standby-local

		# finish standby, last chance let remote enter UPS safemode
		# (only active run upsmon)
		if [ ! -f $SZF_HA_IN_UPS_SAFEMODE ] && synobootseq --is-safe-shutdown &>/dev/null ; then
			passive_enter_ups_safemode
		fi
	fi

	if [ -f "$SYNO_HA_SAFEMODE" ]; then
		# Make all shares read-write
		synoha --unlock-shares

		/etc.defaults/rc.volume stop
		log_notice "vspace all-unload"
		$SYNOVSPACE -all-unload

		if [ -e $SYNO_HA_UNBINDING ]; then
			ha_safemode_restore_user_settings
			rm -f $SYNO_HA_SAFEMODE
			rm -rf $HA_SAFEMODE_DIR
		fi
	fi

	if [ ! -f "$SYNO_DRBD_DEMOTE_ERROR" ]; then
		log_notice "stop pacemakerd"
		RCMsg "Stopping pacemakerd" \
		pacemaker_stop

		log_notice "stop corosync"
		RCMsg "Stopping corosync" \
		corosync_stop

		log_notice "stop drbd"
		RCMsg "Stopping drbd" \
		drbd_stop
	fi

	log_notice "set host name from `uname -n`"
	synoha --set-hostname-original
	log_notice "orig hostname: `uname -n`"

	log_warn "rc.ha_stop end"
}

# According to LSB 3.1 (ISO/IEC 23360:2006), if the `status` action is
# requested, the init scripts will return the following exit status codes.
#
# 0             program is running or service is OK
# 1             program is dead and /var/run pid file exists
# 2             program is dead and /var/lock lock file exists
# 3             program is not runnning
# 4             program or service status is unknown
# 5-99          reserved for future LSB use
# 100-149       reserved for distribution use
# 150-199       reserved for application use
# 200-254       reserved
status()
{
	RCMsg "Checking status of essential services" \
	$HA_PREFIX/etc/serv_conf_must.sh status

	RCMsg "Chenking status of drbd" \
	[ -f /proc/drbd ]

	RCMsg "Checking status of corosync" \
	check_alive corosync

	RCMsg "Checking status of pacemakerd" \
	check_alive pacemakerd

	# return status of crmd because it depends on pacemakerd and corosync
	if check_alive crmd; then
		return $LSB_STAT_RUNNING
	else
		return $LSB_ERR_GENERIC
	fi
}

restart()
{
	stop
	start
}

lock()
{
	# skip lock actions
	case "$1" in
		bump-cib-epoch)
		return $LSB_SUCCESS
		;;
		set-disk-io-scheduler-to-deadline)
		return $LSB_SUCCESS
		;;
	esac

	if [ -f "$RC_FLOCK" ]; then
		local prev_lock=`cat $RC_FLOCK`
		log_err "rc.ha lock ($1) failed, pervious lock pid:$prev_lock"
		return $LSB_ERR_GENERIC
	fi

	trap '/bin/rm "$RC_FLOCK" &> /dev/null' INT TERM EXIT ABRT
	echo "$$ $1" > "$RC_FLOCK"
	return $LSB_SUCCESS
}

unlock()
{
	/bin/rm "$RC_FLOCK" &> /dev/null
}

add_path()
{
	if ! `grep -q $HA_PREFIX $ROOT_PROFILE` ; then
		echo "export PATH=\$PATH:$PATH" >> $ROOT_PROFILE
	fi
}

remove_path()
{
	grep -v $HA_PREFIX $ROOT_PROFILE > $ROOT_PROFILE.tmp
	if [ -s $ROOT_PROFILE.tmp ] ; then
		mv $ROOT_PROFILE.tmp $ROOT_PROFILE
	fi
}

allservices_stop()
{
	StopServiceHA
}

allservices_start()
{
	StartServicesHA START
	StartServicesHA MUST
	StartServicesHA BASE
	StartServicesHA 3RD
	StartServicesHA DONE
}

# $1 is the temprary directory which save the collect logs
# $2 is the serian number to support reentrant

get_ha_debug_info_pre()
{
	local _SN=$2
	local _SYNO_HA_DEBUG_DAT=${SYNO_HA_DEBUG_DAT}.$_SN
	local _SYNO_HA_DEBUG_DAT_DONE=${SYNO_HA_DEBUG_DAT_DONE}.$_SN
	local _dir=
	if [ "$1" = "" ]; then
		_dir=/tmp/ha_debug_info/
	else
		_dir="$1/ha/"
	fi

	rm -fr $_dir

	[ "$SUPPORT_HA" = "yes" ] || exit $LSB_ERR_GENERIC
	[ "$RUN_HA" = "yes" ] || exit $LSB_ERR_GENERIC

	mkdir -p $_dir
	local isActive=`synoha --local-role | grep $SYNO_HA_ROLE_ACTIVE`
	local hasRemote=$(HAHasRemote)
	if [ -n "$isActive" -a -n "$hasRemote" ]; then
		if [ "x$REMOTE_HOST" != "x" ]; then
			$RSYNC_PROG $HA_RSYNC_OPTION &
			rm -f $_SYNO_HA_DEBUG_DAT
			rm -f $_SYNO_HA_DEBUG_DAT_DONE
			crm_node --node="$REMOTE_HOST" --mesg="${SYNO_HA_MESG_REQ_AIS_HEADER}$_SN"
		fi
	fi
}

get_ha_debug_info_post()
{
	local _SN=$2
	local _SYNO_HA_DEBUG_DAT=${SYNO_HA_DEBUG_DAT}.$_SN
	local _SYNO_HA_DEBUG_DAT_DONE=${SYNO_HA_DEBUG_DAT_DONE}.$_SN
	local _dir=
	if [ "$1" = "" ]; then
		_dir=/tmp/ha_debug_info/
	else
		_dir="$1/ha/"
	fi

	[ "$SUPPORT_HA" = "yes" ] || exit $LSB_ERR_GENERIC
	[ "$RUN_HA" = "yes" ] || exit $LSB_ERR_GENERIC

	local isActive=`synoha --local-role | grep $SYNO_HA_ROLE_ACTIVE`
	local hasRemote=$(HAHasRemote)
	if [ -n "$isActive" -a -n "$hasRemote" ]; then
		if [ "x$REMOTE_HOST" != "x" ]; then
			retry=0
			while [ 1 ]; do
				hasRemote=$(HAHasRemote)
				if [ -f $_SYNO_HA_DEBUG_DAT_DONE ]; then
					break
				fi
				if [ -z "$hasRemote" ]; then
					log_notice "remote not online"
					break
				fi
				if [ $retry -gt 200 ]; then
					log_err "wait remote debug dat timeout"
					break
				fi
				sleep 3
				retry=`expr $retry + 1`
			done
			[ -f "$_SYNO_HA_DEBUG_DAT" ] && mv $_SYNO_HA_DEBUG_DAT $_dir/passive_debug.dat
			pid=`cat "$RSYNC_PID"`
			kill_proc_id "$pid" rsync
			rm ${RSYNC_PID} &> /dev/null
		fi
	fi

	cat /proc/drbd > $_dir/proc.drbd
	crm_mon -1 > $_dir/crm.status
	crm configure show > $_dir/crm.configure
	cp $HA_PREFIX/etc.defaults/drbd.d/global_common.conf $_dir
	cp $HA_PREFIX/etc/corosync/corosync.conf $_dir
	cp $HA_PREFIX/etc/drbd.d/*.res $_dir
	cp $HA_PREFIX/etc/ha.conf $_dir
	cp $HA_PREFIX/etc/serv.mon.conf $_dir
	cp -r /var/lib/ha/* $_dir
	ls -l /tmp/ha > $_dir/tmp.ha.ls
	corosync-cfgtool -s > $_dir/corosync-cfgtool
	corosync-cpgtool > $_dir/corosync-cpgtool
	corosync-objctl > $_dir/corosync-objctl

	rm -f $_SYNO_HA_DEBUG_DAT
	rm -f $_SYNO_HA_DEBUG_DAT_DONE
}

send_debug_dat()
{
	local _SN=$1
	local _SYNO_HA_DEBUG_DAT=${SYNO_HA_DEBUG_DAT}.$_SN
	local remote_ip=""
	if [ "x$LOCAL_HOST" == "x$NODE_HOST0" ]; then
		remote_ip=$DRBD_IP1
	else
		remote_ip=$DRBD_IP0
	fi
	$RSYNC_PROG --port=$RSYNC_PORT -ltsR --password-file="$RSYNC_PW_FILE" $_SYNO_HA_DEBUG_DAT root@$remote_ip::synoha_root
	crm_node --node="$REMOTE_HOST" --mesg="${SYNO_HA_MESG_RES_AIS_HEADER}${_SN}"
}

oom_adj_setup()
{
	local OOM_SCORE_ADJ="/proc/$$/oom_score_adj"
	local OOM_SCORE_ADJ_VALUE=$OOM_SCORE_VAL
	local OOM_ADJ="/proc/$$/oom_adj"
	local OOM_ADJ_VALUE=$OOM_VAL

	log_notice "set HA oom"

	if [ -f $OOM_SCORE_ADJ ]; then
		echo $OOM_SCORE_ADJ_VALUE > $OOM_SCORE_ADJ && return
	else
		echo $OOM_ADJ_VALUE > $OOM_ADJ && return
	fi

	log_err "set HA oom failed"
}

[ "$SUPPORT_HA" = "yes" ] || exit $LSB_ERR_GENERIC

lock $1 || exit $?
mkdir $SYNO_HA_TMP_DIR &> /dev/null

action=$1; shift

oom_adj_setup

case "$action" in
	start)
		rm -f $SYNO_HA_STOPPED
		add_path
		start "$@"
		;;
	stop)
		if [ -f "$SYNO_HA_STOPPED" -o -f "$SYNO_HA_STOPPING" ]; then
			exit 0
		fi
		touch $SYNO_HA_STOPPING
		stop "$@"
		remove_path
		touch $SYNO_HA_STOPPED
		rm $SYNO_HA_STOPPING
		;;
	status)
		status
		;;
	restart|reload|force-reload)
		restart
		;;
	start-*)
		RCMsg "Starting ${action##start-}" \
		${action##start-}_start "$@"
		;;
	stop-*)
		RCMsg "Stopping ${action##stop-}" \
		${action##stop-}_stop "$@"
		;;
	prepare-for-upg)
		if [ ! -f $SYNO_HA_UPG ]; then
			exit $LSB_SUCCESS
		fi
		log_warn "ha prepare for upg"

		if [ -f $UPGRADE_FROM_VERSION_AFTER_6_0_BETA_2 ] && ! $SYNOHA_BIN --upg-is-active &> /dev/null; then
			$SYNOHA_BIN --isolate-apply
		fi

		# remember to unload these in "start"
		$SYNOVSPACE -stage-load before ha
		drbd_start

		$DRBDADM new-resource all              2>&1 | log_notice
		$DRBDADM sh-new-minor all              2>&1 | log_notice
		$DRBDADM attach all                    2>&1 | log_notice
		$DRBDADM secondary all                 2>&1 | log_notice
		$DRBDADM connect --discard-my-data all 2>&1 | log_notice

		# wait 3*10 sec to detect remote drbd role
		retry=0
		remote_primary=""
		while :; do
			peer_get_line=`$DRBDSETUP sh-status all | grep "\<_peer\>" | cut -d '=' -f 2 | grep -E 'Primary|Secondary' | wc -l`
			if [ $peer_get_line -gt 0 ]; then
				remote_primary="true"
				log_err "drbd detected remote primaries"
				break;
			fi
			[ $retry -eq 10 ] && break	# 3*10 sec
			retry=`expr $retry + 1`
			sleep 3
		done

		if [ -z "$remote_primary" ]; then
			drbd_primary_msg="`$DRBDADM primary all 2>&1`"
			drbd_primary_ret=$?
			log_notice ${drbd_primary_msg}
			[ $drbd_primary_ret -eq 11 ] && remote_primary="true" && log_err "drbd detected multiple primaries"
		fi

		if [ -n "$remote_primary" ]; then
			log_err "Upgrade after active reboot, split brain"
			synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$SYNO_SPLIT_BRAIN" &> /dev/null &
			sleep 300
			unlock
			reboot -f
		fi
		$SYNOVSPACE -stage-load equal ha
		$HA_PREFIX/etc.defaults/rc.volume start
		;;
	kill-all-process-except-ha)
		skip="reboot syno_poweroff_task corosync pacemakerd stonithd cib lrmd attrd pengine crmd rc.ha drbdadm drbdsetup"
		skip+=" ha.cgi udevd init"
		{
			kill_many_processes "$skip"
		}&
		;;
	update-etc-hosts)
		add_haip_to_hosts
		add_hbip_to_hosts
		;;
	handle-too-active)
		# must modify pacemaker-1.x/pengine/native.c in the same time!
		unlock
		# Just disable too-active handling for now
		exit 0
		if [ -f "$FLAG_HA_HANDLING_TOO_ACTIVE" ]; then
			exit 0
		fi
		touch $FLAG_HA_HANDLING_TOO_ACTIVE
		handle_too_active "too_active"
		rm $FLAG_HA_HANDLING_TOO_ACTIVE
		;;
	bump-cib-epoch)
		# must modify corosync-1.x/exec/totemsrp.c in the same time!
		unlock
		if [ ! -f "$FLAG_HA_HAS_BUMPED_UP_ADMIN_EPOCH" ]; then
			if [ -f "$FLAG_HA_SXX_ROLE_PREPASSIVE" ]; then
				touch ${FLAG_HA_HAS_BUMPED_UP_ADMIN_EPOCH}.pre;
				# increment admin_epoch in Checkpoint_last promotion
			else
				touch $FLAG_HA_HAS_BUMPED_UP_ADMIN_EPOCH
				bump_admin_epoch
			fi
		fi

		# set constraint on passive server at first to prevent unwanted promotion
		if [ -f "$FLAG_HA_SXX_ROLE_PREPASSIVE" ]; then
			set_ping_server_constraint $LOCAL_HOST
			# I can see ping server
			if $SYNOHA_BIN --check-connectivity `get_ping_server`; then
				unset_ping_server_constraint
			fi
			# active does nothing even though it can't see ping server
		fi
		;;
	get-ha-debug-info-pre)
		# this function is called by synomsg_collector2
		unlock
		get_ha_debug_info_pre "$@"
		;;
	get-ha-debug-info-post)
		# this function is called by synomsg_collector2
		unlock
		get_ha_debug_info_post "$@"
		;;
	send-debug-dat)
		unlock
		send_debug_dat "$@"
		;;
	add-drbdip)
		add_drbdip_to_drbdif
		;;
	hotplug-usb-ups)
		unlock
		ups_sh="$@"
		HA_LOCAL_ROLE=`synoha --local-role`
		if [ "$SYNO_HA_ROLE_ACTIVE" == "$HA_LOCAL_ROLE" -o "$SYNO_HA_ROLE_PREACTIVE" == "$HA_LOCAL_ROLE" ]; then
			log_notice "hotplug usb ups: $ups_sh"
			$ups_sh
		else
			log_notice "ups can't run on passive mode"
		fi
		;;
	ups-safemode)
		unlock
		passive_enter_ups_safemode
		;;
	ups-restart)
		unlock
		log_notice "wake remote"
		synoha --wake-remote
		;;
	set-disk-io-scheduler-to-deadline)
		unlock
		echo deadline > /sys/block/$@/queue/scheduler
		;;
	set-services-done)
		unlock
		StartServicesHA DONE
		;;
	*)
		echo "usage: $0 {start|stop|restart|status}"
		exit $LSB_ERR_ARGS
		;;
esac

exit $?

# vim:ft=sh
