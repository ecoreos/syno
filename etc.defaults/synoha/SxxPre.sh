#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

HA_PREFIX="/usr/syno/synoha"

. $HA_PREFIX/etc.defaults/rc.subr

FLAG_HA_PASSIVE_IS_BINDING=$PASSIVE_IS_BINDING

case "$1" in
	start)
		synoha_log notice "SxxPre start"
		rm -f $FLAG_HA_SXX_ROLE_PREPASSIVE
		touch $FLAG_HA_SXX_ROLE_PREACTIVE

		# check and re-gen user/group db in /run/synosdk/
		/usr/syno/cfgen/s30_synocheckuser
		/usr/syno/cfgen/s42_synocheckgrp

		$SYNOHA_BIN --update-hotspare-conf

		# update scheduler conf and db in /tmp
		/sbin/start synoscheduler

		# update synoproxy.conf in /tmp by rm it
		rm -f /tmp/synoproxy.conf

		# HA #1892, pgsql migration will take a long time
		if [ -f "$SYNO_HA_UPG" ]; then
			if ! $SYNOHA_BIN --upg-is-active ; then
				synoservice --pause-by-reason pgsql ha-upg
			fi
		fi

		if [ -f "$SYNO_HA_AUTH_KEY" ]; then
			# Set auth key continues, stop process when "serv_done..."
			$SYNO_HA_AUTH_KEY_SH start
		fi

		synoservice --resume-all ha-passive
		;;
	stop)
		synoha_log notice "SxxPre stop"
		rm -f $FLAG_HA_SXX_ROLE_PREACTIVE
		touch $FLAG_HA_SXX_ROLE_PREPASSIVE

		if [ -f "$SYNO_HA_UPG" ]; then
			if $SYNOHA_BIN --upg-is-active ; then
				# start upgrade, active go here to skip pause some services
				synoservice --pause-all ha-passive ha-keep-session
			else
				# after passive reboot, passive go here to become passive
				synoservice --pause-all ha-passive ha-on-passive
			fi

			if ! $SYNOHA_BIN --upg-is-active ; then
				# HA #1892, pgsql migration will take a long time
				synoservice --resume-by-reason pgsql ha-upg
			fi
		elif $SYNOHA_BIN --check-ha-is-binding; then
			# binding
			if [ -f $FLAG_HA_PASSIVE_IS_BINDING ]; then
				synoservice --pause-all ha-passive ha-on-passive
			else
				synoservice --pause-all ha-passive ha-keep-session
			fi
			# Don't forget etc/rc
			synoservice --pause-by-reason synowifid ha-not-support
			synoservice --pause-by-reason bluetoothd ha-not-support
			synoservice --pause-by-reason btacd ha-not-support
		elif [ -e $ROLE_ACTIVE_WHEN_UNBINDING_HA ]; then
			# for active server during unbinding HA progress
			synoservice --pause-all ha-passive ha-keep-session
		else
			# switch over
			synoservice --pause-all ha-passive ha-on-passive
			pause_level_2_services
		fi

		if [ -e $ROLE_ACTIVE_WHEN_UNBINDING_HA ]; then
			$SYNOHA_BIN --set-vaai-default
		fi

		{
			# even remove usb called at SxxPost stop
			# usb ups may be plugged between SxxPost ~ Dummy stop
			# following stop ups after Dummy stop before become passive
			if ! synobootseq --is-safe-shutdown &>/dev/null ; then
				. /usr/syno/bin/synoupscommon
				HA_ROLE_PREACTIVE=$ROLE_PREACTIVE
				while [ "$HA_ROLE_PREACTIVE" == "`$SYNOHA_BIN --local-role`" ]; do sleep 3 ; done
				StopUps log
			fi
		}&
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

