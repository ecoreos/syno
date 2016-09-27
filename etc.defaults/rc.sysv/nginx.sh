#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

SZD_SERVICES_TMP_NGINX="/var/services/tmp/nginx"

case "$1" in
	'reload')
		if ! /usr/syno/sbin/synoservicectl --status nginx > /dev/null 2>&1; then
			exit 0
		fi

		[ ! -d "$SZD_SERVICES_TMP_NGINX" ] && /bin/mkdir -p "$SZD_SERVICES_TMP_NGINX" || true

		if ! /usr/syno/bin/synow3tool --deploy-hup; then
			/bin/logger -p user.err -t "$(/bin/basename "$0")" "Cannot reload nginx service"
			exit 1
		fi

		/usr/sbin/start alias-register || true

		/usr/sbin/reload nginx
		;;
	*)
		echo "Usage $0 { reload }"
		exit 1
		;;
esac
