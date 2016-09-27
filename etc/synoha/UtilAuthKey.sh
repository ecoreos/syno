#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

SYNOHA_BIN="/usr/syno/synoha/sbin/synoha"
SYNO_HA_AUTH_KEY="/tmp/ha/.ha_auth_key"

case "$1" in
	start)
		{
		while :;
		do
			if [ ! -f "$SYNO_HA_AUTH_KEY" ]; then
				exit 0
			fi
			$SYNOHA_BIN --auth-key `cat $SYNO_HA_AUTH_KEY`
			sleep 60
		done
		}&
		;;
	stop)
		rm -f $SYNO_HA_AUTH_KEY
		;;
esac

