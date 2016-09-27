#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

IET_PID="/var/run/iscsi_trgt.pid"
IET_PROC="/proc/net/iet/volume"

ISCSITRGT_LOCK="/tmp/S78iscsitrg.lock"

. /etc.defaults/rc.subr

iscsitrg_type()
{
	KERNEL_VCODE=`KernelVersionCode $(KernelVersion)`
	if [ "${KERNEL_VCODE}" -ge "$(KernelVersionCode "3")" ]; then
		ISCSITRGT_TYPE=`/bin/get_key_value /etc.defaults/synoinfo.conf iscsi_target_type`
	else
		ISCSITRGT_TYPE=`/bin/get_key_value /etc/synoinfo.conf iscsi_target_type`
		if [ "xiet" != "x${ISCSITRGT_TYPE}" ] && [ "xlio" != "x${ISCSITRGT_TYPE}" ] && [ "xlio4x" != "x${ISCSITRGT_TYPE}" ]; then
			ISCSITRGT_TYPE=`/bin/get_key_value /etc.defaults/synoinfo.conf iscsi_target_type`
		fi
	fi
	echo ${ISCSITRGT_TYPE}
}

ISCSITRGT_TYPE=`iscsitrg_type`

## IET - iSCSI Enterprise Target
iet_status()
{
	RCMsg "Checking iSCSI Enterprise Target" \
	[ "x`/sbin/lsmod | /bin/grep iscsi_trgt | /usr/bin/awk '{ if ($1 == "iscsi_trgt") print $1 }'`" != "x" ]
	if [ "$?" -ne "0" ]; then
		echo "-1"
	fi

	RCMsg "Checking iSCSI Enterprise Target Daemon" \
	[ "x`/bin/ps -e -o pid,command | /bin/grep ietd | /bin/grep -v grep | /usr/bin/awk '{ if ($2 == "/sbin/ietd") print $2 }'`" != "x" ]
	if [ "$?" -eq "0" ]; then
		echo "0"
	else
		echo "-1"
	fi

}

iet_insmod()
{
	if [ -e $IET_PROC ]; then
		MsgFail "iSCSI kernel modules has been loaded... "
	else
		/sbin/insmod /lib/modules/libcrc32c.ko 1>/dev/null 2>&1
		if [ -f /lib/modules/crc32c.ko ] ; then
			/sbin/insmod /lib/modules/crc32c.ko 1>/dev/null 2>&1
		fi
		/sbin/insmod /lib/modules/iscsi_trgt.ko 1>/dev/null 2>&1
		/usr/sbin/ietd 1>/dev/null 2>&1
		RCMsg "Loading iSCSI kernel modules" [ "$?" -eq "0" ]
	fi
}

iet_rmmod()
{
	# Removing iSCSI Kernel Modules
	/sbin/rmmod iscsi_trgt 2>/dev/null
	if [ -f /lib/modules/crc32c.ko ] ; then
		/sbin/rmmod crc32c 2>/dev/null
	fi
	/sbin/rmmod libcrc32c 2>/dev/null
}

iet_start()
{
	iet_insmod
	/usr/syno/bin/synoiscsiep --startall iscsi > /dev/null 2>&1
	return $LSB_SUCCESS
}

iet_stop()
{
	# Removing iSCSI Target Devices
	/usr/sbin/ietadm --op delete > /dev/null 2>&1 # ietadm does not always provide correct exit values

	RCMsg "Stopping iSCSI Target Daemon" /usr/bin/killall -s TERM ietd
	/bin/rm -f $IET_PID 2> /dev/null # pid file is not removed by iet
	sleep 1

	iet_rmmod

	return $LSB_SUCCESS
}

## LIO - Linux-iSCSI.org
lio_status()
{
	/sbin/lsmod | /bin/grep -q iscsi_target_mod
	if [ "$?" -eq "0" ]; then
		echo "0"
	else
		echo "-1"
	fi
}

lio_insmod()
{
	/usr/syno/bin/synoiscsiep --insmod iscsi > /dev/null 2>&1
}

lio_rmmod()
{
	/usr/syno/bin/synoiscsiep --rmmod iscsi > /dev/null 2>&1
}

lio_start()
{
	if [ "$(lio_status)" -eq "0" ]; then
		return $LSB_SUCCESS
	fi

	RCMsg "Running lunbackup garbage collection" \
	/usr/syno/bin/synolunbkp --gc

	/usr/syno/bin/synoiscsiep --startall iscsi > /dev/null 2>&1

	return $LSB_SUCCESS
}

lio_stop()
{
	/usr/syno/bin/synoiscsiep --stopall iscsi
	if [ "$?" -ne "0" ]; then
		MsgFail "Stopping iSCSI LIO targets"
	else
		lio_rmmod
	fi

	if [ "yes" == "$(/usr/syno/bin/synogetkeyvalue /etc/synoinfo.conf runha)" ]; then
		/usr/syno/bin/synoiscsiep --stopall tcm
		/usr/syno/bin/synoiscsiep --rmmod tcm
	fi

	#check the consistent between files and configs
	/usr/syno/bin/synocheckiscsitrg > /dev/null 2>&1

	return $LSB_SUCCESS
}

## iSCSI target rc generic interface
iscsitrg_start()
{
	if [ "x${ISCSITRGT_TYPE}" = "xiet" ]; then
		iet_start
	else
		lio_start
	fi

	/sbin/initctl emit --no-wait syno.iscsi.ready
}

iscsitrg_stop()
{
	if [ "x${ISCSITRGT_TYPE}" = "xiet" ]; then
		iet_stop
	else
		# Since synoservice won\'t let upstart do its job by placing override files,
		# we have to do this manually.
		/sbin/initctl stop iscsi_pluginengined
		lio_stop
	fi
}

iscsitrg_restart()
{
	if [ "x${ISCSITRGT_TYPE}" = "xiet" ]; then
		iet_stop
		iet_start
	else
		lio_stop
		lio_start
	fi
}

iscsitrg_status()
{
	local status="-1"
	if [ "x${ISCSITRGT_TYPE}" = "xiet" ]; then
		status="$(iet_status)"
	else
		status="$(lio_status)"
	fi

	if [ "$status" -eq "0" ]; then
		RCMsg "iSCSI Service: running."
		return $LSB_STAT_RUNNING
	fi

	local targetcount=`synoiscsiep --target_cnt`

	if [ "$targetcount" -eq "0" ]; then
		RCMsg "iSCSI Service: stopped."
		# service framework is about to support enabled-but-not-running state,
		# but now we still need to pretend we are running for now.
		return $LSB_STAT_RUNNING
		#return $LSB_STAT_NOT_RUNNING
	fi

	return $LSB_STAT_NOT_RUNNING
}

iscsitrg_insmod()
{
	if [ "x${ISCSITRGT_TYPE}" = "xiet" ]; then
		iet_insmod
	else
		lio_insmod
	fi
}

check_support()
{
	local iscsitrg_support=`/bin/get_key_value /etc.defaults/synoinfo.conf support_iscsi_target`
	case "${iscsitrg_support}" in
		[Yy][Ee][Ss])
			return $LSB_SUCCESS
			;;
		*)
			RCMsg "iSCSI target is not supported."
			return $LSB_ERR_CONFIGURED
			;;
	esac
}

iscsitrg_unlock()
{
	/bin/rm "${ISCSITRGT_LOCK}"
}

iscsitrg_lock_trap_unset()
{
	trap - INT TERM EXIT ABRT
}

iscsitrg_lock_trap_set()
{
	trap 'iscsitrg_unlock' INT TERM EXIT ABRT
}

iscsitrg_lock()
{
	if [ -f ${ISCSITRGT_LOCK} ]; then
		MsgWarn "$0 is working?"
		return 1
	fi

	iscsitrg_lock_trap_set

	echo $$ > ${ISCSITRGT_LOCK}
	return 0
}

[ "$#" -ne "0" ] && ! check_support && exit $?

iscsitrg_lock

lock_result=$?
[ "${lock_result}" -eq "1" ] && exit $LSB_STAT_RUNNING

case $1 in
	start)
		iscsitrg_start
		;;
	stop)
		iscsitrg_stop
		;;
	restart)
		iscsitrg_restart
		;;
	status)
		iscsitrg_status
		;;
	insmod)
		iscsitrg_insmod
		;;
	*)
		echo "Usage: `/usr/bin/basename $0` {start|stop|restart|status}"
		exit 1
esac

exit $?
