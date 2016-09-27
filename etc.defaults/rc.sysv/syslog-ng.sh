#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

BIN_FLOCK=/usr/bin/flock
SBIN_INITCTL=/sbin/initctl
LOCK_FILE=/var/run/syslog-ng.lock


case "$1" in
	reload)
		if [ ! -e "${BIN_FLOCK}" ]; then
			logger -p user.err "${BIN_FLOCK} is not found..."
			exit 1
		fi
		if [ ! -e "${SBIN_INITCTL}" ]; then
			logger -p user.err "${SBIN_INITCTL} is not found..."
			exit 1
		fi
		ret=`/usr/syno/sbin/synoservicectl --status syslog-ng`
		if [ 0 != $? ]; then
			logger -p user.err "Job syslog-ng is not running, skip reload service action"
			exit 1
		fi

		"${BIN_FLOCK}" -x "${LOCK_FILE}" "${SBIN_INITCTL}" reload syslog-ng
		if [ -f /var/packages/LogCenter/enabled ]; then
			"${BIN_FLOCK}" -x "${LOCK_FILE}" "${SBIN_INITCTL}" restart pkg-LogCenter-syslog
		fi
		;;
	*)
		echo "Usage $0 { reload }"
		exit 1
		;;
esac
exit 0
