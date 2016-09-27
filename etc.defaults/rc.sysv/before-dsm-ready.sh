#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.
dump_sas_disk_map()
{
	supportSAS=`/bin/get_key_value /etc.defaults/synoinfo.conf supportsas`
	if [ "xyes" == "x${supportSAS}" -o "xYES" == "x${supportSAS}" ]; then
		sleep 15
		/usr/syno/bin/synoenc --dump_enc_disk /tmp/sasdiskmaps
		cat /tmp/sasdiskmaps >> /var/log/messages
	fi
}

usage() {
	cat << EOF
Usage: $(basename $0) [start]
EOF
}

start()
{
	if [ "yes" = "`/bin/get_key_value /etc/synoinfo.conf runha`" ] &&
		[ "Passive" = "`/usr/syno/synoha/sbin/synoha --local-role`" ]; then
		return
	fi

	if [ -x /usr/syno/bin/synofstool ]; then
		/usr/syno/bin/synofstool --dump-fscache &
	fi

	dump_sas_disk_map &

	#Change permission of /dev/fuse
	if [ -e "/dev/fuse" ]; then
		/bin/chown root:users /dev/fuse
		/bin/chmod 0666 /dev/fuse
	fi

	# the file was touched in /etc/rc
	if [ -f /tmp/.ImproperShutdown ]; then
		/usr/syno/bin/synologset1 sys warn 0x11100001
		/usr/syno/bin/synonotify ImproperShutdown
		rm -f /tmp/.ImproperShutdown
	fi

	if [ -f /.updater ] || [ -f /var/.UpgradeBootup ]; then
		/usr/syno/bin/synoselfcheck -o "dsmupdate_$(date "+%Y%m%d_%H%M%S").result" dsm full &
	elif [ -f /var/.SmallupdateBootup ]; then
		/usr/syno/bin/synoselfcheck -o "smallupdate_$(date "+%Y%m%d_%H%M%S").result" dsm full &
	fi

	#Remove updater and version files for first-bootup of upgrade
	rm -f /.updater
	rm -f /var/.UpgradeBootup
	rm -f /var/.SmallupdateBootup

	# clean up migrate backup file
	rm -rf /.syno/update_bkp/
}

case "$1" in
	start) start;;
	*) usage >&2; exit 1;;
esac
