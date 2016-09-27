#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

HA_PREFIX="/usr/syno/synoha"
PIDFILE="/var/run/ntpd_ha_client.pid"
NTPD_BIN="/usr/sbin/ntpd"
NTPCONF="/tmp/ntp_ha_client.conf"
HA_INFO=$HA_PREFIX/etc/ha.conf
DRBD_IF=`get_key_value $HA_INFO drbd_if`
HA_IF_MAIN=`get_key_value $HA_INFO ha_if_main`

. $HA_PREFIX/etc.defaults/rc.subr

start_()
{
	rm -f $NTPCONF
	local _remote_drbdip=`$SYNOHA_BIN --remote-drbdip`
	local _remote_ip=`$SYNOHA_BIN --remote-ip`
	local _local_drbdip=""
	[ "169.254.1.1" == "$_remote_drbdip" ] && _local_drbdip="169.254.1.2" || _local_drbdip="169.254.1.1"

	cat > $NTPCONF <<EOF
server $_remote_drbdip prefer
server $_remote_ip
restrict default ignore
restrict -6 default ignore
restrict 127.0.0.1
restrict $_remote_drbdip
restrict $_remote_ip
interface ignore wildcard
interface listen $DRBD_IF
interface listen $_local_drbdip
interface listen $HA_IF_MAIN
EOF
	$NTPD_BIN -p $PIDFILE -c $NTPCONF -g -4 -u ntp:ntp
}

stop_()
{
	if [ -f $PIDFILE ]; then
		local _pid
		_pid=`cat $PIDFILE`
		if [ "x$_pid" != "x" ] ; then
			kill $_pid
		fi
		rm -f $NTPCONF
		rm -f $PIDFILE
	fi
}

case "$1" in
	start)
		stop_
		start_
		;;
	stop)
		stop_
		;;
	restart)
		stop_
		start_
		;;
	*)
		echo "Usage: $0 { start | stop | restart}"
		;;
esac
exit $?

