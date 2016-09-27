#!/bin/sh

SupportDualhead=`/bin/get_key_value /etc.defaults/synoinfo.conf support_dual_head`
if [ "yes" == "$SupportDualhead" ]; then
	local_role=`/usr/syno/synoaha/bin/synoaha --get-local-role`
	active=`/usr/syno/synoaha/bin/synoahastr --role-active`
	if [ "$active" != "$local_role" ]; then
		exit 0
	fi
fi

/usr/syno/sbin/synosharesnaptool is-restore-running

if [ $? -ne 0 ]; then
	exit 1
fi

exit 0
