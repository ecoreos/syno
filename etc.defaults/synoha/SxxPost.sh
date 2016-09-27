#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

HA_PREFIX="/usr/syno/synoha"
UDEVADM="/usr/bin/udevadm"
UPS_SH="/usr/syno/etc/rc.sysv/ups-usb.sh"

. $HA_PREFIX/etc.defaults/rc.subr

case "$1" in
	start)
		synoha_log notice "SxxPost start"
		#/etc.defaults/scanusbdev should be called after start hotplug
		# <HA> #1268 - Add usb device again
		# <HA> #2029 - use udev instead
		for p in /sys/bus/usb/devices/usb*; do
			PARENT=/`readlink $p | sed 's#\.\./##g'`
			$UDEVADM trigger --action=add --parent-match=$PARENT --subsystem-match=block
			$UDEVADM trigger --action=add --parent-match=$PARENT --sysname-match=lp*
		done
		[ -z "`pidof upsmon`" ] && $UPS_SH start &
		;;
	stop)
		synoha_log notice "SxxPost stop"
		# <HA Manager> #653 - call synovpnclient shutdown before stop
		# to prevent vpn reconnect on active, and allow vpn reconnect on passive
		ServiceScript="/usr/syno/etc/synovpnclient/scripts/synovpnclient.sh"
		hasScript=$?
		if [ "0" == $hasScript ]; then
			synoha_log notice "shutdown $ServiceScript..."
			$ServiceScript shutdown
		fi
		for p in /sys/bus/usb/devices/usb*; do
			PARENT=/`readlink $p | sed 's#\.\./##g'`
			$UDEVADM trigger --action=remove --parent-match=$PARENT
		done
		;;
	restart)
		stop
		start
		;;
	status)
		;;
	*)
		echo "Usages: $0 [start|stop|restart|status]"
		;;
esac
exit $?

