#!/bin/sh
# Copyright (c) 2000-2014 Synology Inc. All rights reserved.

# usage, example

action=""
if=""
ip=""
netmask=""
port=5000
protocol="http"
C_PING=/bin/ping
C_TR=/usr/bin/traceroute
C_CAT=/bin/cat
C_RM=/bin/rm
C_WGET=/usr/bin/wget
C_DD=/bin/dd
C_ECHO=/bin/echo
C_MV=/bin/mv
C_IFCON=/sbin/ifconfig
C_SLEEP=/bin/sleep
C_TOUCH=/bin/touch
C_LOGGER=/usr/bin/logger
C_ROUTE=/sbin/route
C_IP=/sbin/ip

ResTimeLimit=2 # ms
speedLimit='50' #50M
speedLimitSecure='25' #25M

TEMPPATH=/tmp
TESTFILE_PATH=/webman/modules/HAManager
TESTFILE_PREFIX=/usr/syno/synoman
TESTFILE=10M

TMPFILE=$TEMPPATH/.HA.CheckHeartbeatLink.tmp
CHECKING_FILE=$TEMPPATH/.HA.CHECK_HEARTBEAT_ENV
RESULT_FILE=$TEMPPATH/ha/HA.Heartbeat.check.result
is_active=
auto_reset=0
cmdline=

log_notice()
{
	$C_LOGGER -p user.notice -t "UtilHeartbeatCheck.sh[$$]" "[HA-NOTICE] ${1:-}"
}

# 0: $1 == $2
# 1: $1 > $2
# 2: $1 < $2
compare()
{
	return `echo $1 $2 | awk '{print ($1 == $2)? 0 : ($1 > $2)? 1 : 2}'`
}

record_header()
{
	$C_ECHO "=======================" >> $RESULT_FILE 2>&1
	$C_ECHO "=="$(date +"%Y/%m/%d %H:%M:%S")"==" >> $RESULT_FILE 2>&1
	$C_ECHO "=======================" >> $RESULT_FILE 2>&1
}

record_content()
{
	local content=$1
	$C_CAT $content >> $RESULT_FILE 2>&1
	$C_ECHO "" >> $RESULT_FILE 2>&1
}

command_exec_to_tmpfile()
{
	local command=$1
	local echovalue=$2

	record_header

	$C_ECHO "$command" > $TMPFILE 2>&1
	if [ $echovalue ] ; then
		$command >> $TMPFILE 2>&1 || (log_notice "$command"; $C_ECHO $echovalue)
	else
		$command >> $TMPFILE 2>&1
	fi

	record_content $TMPFILE
}

# see also HAHeartbeatCheck at synoha/src/lib/ha.cc.
reset_env()
{
	if=$1

	if [ -z $if ] ; then
		$C_ECHO 9
		exit
	fi
	if [ -e $CHECKING_FILE ] ; then
		$C_RM $CHECKING_FILE 2> /tmp/rmfile
		IFEXIST=`/sbin/ip -o -f inet addr show | grep $if:DRBD`
		if [ -n "$IFEXIST" ] ; then
			command_exec_to_tmpfile "$C_IFCON $if:DRBD down" 2
		fi
		if [ -z $is_active ] ; then
			command_exec_to_tmpfile "$C_RM $TESTFILE_PREFIX/$TESTFILE_PATH/$TESTFILE" 3
		fi
		if [ $auto_reset -eq 1 ] ; then
			command_exec_to_tmpfile "/usr/syno/synoha/sbin/synoha --restore-drbd-attr $if"
		fi
		$C_ECHO 1
		/usr/bin/killall `basename $0`
	fi
}

# see also HAHeartbeatCheck at synoha/src/lib/ha.cc.
prepare_env()
{
	if=$1
	ip=$2
	netmask=$3

	$C_RM $RESULT_FILE
	if [ -z $netmask ] ; then
		echo 9
		exit
	fi
	$C_TOUCH $CHECKING_FILE
	command_exec_to_tmpfile "$C_IFCON $if:DRBD $ip netmask $netmask" 3
	if [ -z $is_active ] ; then
		command_exec_to_tmpfile "$C_DD if=/dev/zero of=$TEMPPATH/$TESTFILE bs=1M count=10" 4
		command_exec_to_tmpfile "$C_MV $TEMPPATH/$TESTFILE $TESTFILE_PREFIX/$TESTFILE_PATH/$TESTFILE" 5
	fi
	$C_ECHO 1
	auto_reset=1

	{
		# Heartbeat check will change mtu (including interface up/down), and drbd ip&route is set after mtu change;
		# but sometimes, change mtu (interface up/down) will clean the drbd route for remote (169.254.1.0)
		# if there are 2 interfaces with ip 169.254.x.x, the heartbeat check will fail.
		# This job is killed by reset_env later.
		while :; do
			$C_IP -o -f inet addr show | grep -q DRBD
			if [ "0" == "$?" ]; then
				$C_ROUTE | grep 169.254.1.0 | grep -q 255.255.255.252
				if [ "0" != "$?" ]; then
					$C_ROUTE add -net 169.254.1.0 netmask 255.255.255.252 dev $if
				fi
			fi
			sleep 1
		done
	}&

	# sleep 60 and reset
	{
		$C_SLEEP 60 && reset_env
	}&
}

action=$1; shift
case "$action" in
	prepare_active)
		is_active=1
		prepare_env $@
		;;
	reset_active)
		is_active=1
		reset_env $@
		;;
	prepare_passive)
		prepare_env $@
		exit
		;;
	reset_passive)
		reset_env $@
		exit
		;;
	check)
		if=$1
		ip=$2
		port=$3
		protocol=$4
		if [ -z $if ] ; then
			$C_ECHO 9
			exit
		fi

		# Makesure the network environment is ready for the following tests.
		for i in `seq 1 1 10`
		do
			command_exec_to_tmpfile "$C_PING $ip -s 9000 -I $if -c 1 -W 1"
			lossRate=`$C_CAT $TMPFILE | grep packets | cut -d" " -f 6`
			$C_RM $TMPFILE

			if [ "$lossRate" == "0%" ]; then
				break;
			fi

			if [ 10 -eq $i ]; then
				$C_ECHO "2"
				exit;
			fi

			# sleep for 1 sec for each iteration to prevent all
			# iterations get "Destination Host Unreachable" result
			# which will report result immediately rather than
			# wait for the timeout we set (1 sec)
			$C_SLEEP 1
		done

		cmdline="$C_PING $ip -s 9000 -I $if -c 5 -W 1"
		command_exec_to_tmpfile "$cmdline"
		ttl=`$C_CAT $TMPFILE | grep ttl -m 1 | cut -d " " -f 6 | cut -d"=" -f 2`
		resTime=`$C_CAT $TMPFILE | grep "\/avg\/" | cut -d"/" -f 5`
		lossRate=`$C_CAT $TMPFILE | grep packets | cut -d" " -f 6`
		$C_RM $TMPFILE

		if [ "$lossRate" == "100%" ]; then
			log_notice "$cmdline"
			$C_ECHO "2"
			exit;
		fi
		if [ "$lossRate" != "0%" ]; then
			log_notice "$cmdline"
			$C_ECHO "3"
			exit;
		fi
		if [ $ttl -ne 64 ] ; then
			log_notice "$cmdline"
			$C_ECHO "4"
			exit;
		fi
		compare $resTime $ResTimeLimit
		if [ "$?" == "1" ] ; then
			log_notice "$cmdline"
			$C_ECHO "5"
			exit;
		fi

#		echo "TTL: $ttl \nResTime: $resTime \nLossRate: $lossRate" > /tmp/.checkResultXHeartBeat
		for times in `seq 1 10` #1 2 3 4 5 6 7 8 9 10
		do
			#2014-05-12 18:45:41 (108 MB/s) - '10M' saved [10485760/10485760]
			cmdline="$C_WGET --tries=1 --timeout=1 --no-proxy --no-check-certificate --delete-after $protocol://$ip:${port}${TESTFILE_PATH}/$TESTFILE"
			command_exec_to_tmpfile "$cmdline"
			speed=`$C_CAT $TMPFILE | grep saved | cut -d"(" -f 2 | cut -d" " -f 1`
#			echo "Speed: $speed" >> /tmp/.checkResultXHeartBeat
			if [ -z $speed ] ; then
				log_notice "$cmdline"
				$C_ECHO "6"
				break;
			fi

			if [ "https" = "$protocol" ]; then
				compare $speed $speedLimitSecure
			else
				compare $speed $speedLimit
			fi
			if [ "$?" == "1" ] ; then
				break;
			fi

			if [ "$times" == "10" ] ; then
				log_notice "$cmdline"
				$C_ECHO "7"
				break;
			fi
		done

		$C_ECHO "1";

		;;
esac

