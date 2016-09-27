#!/bin/sh

runha=`/usr/syno/bin/synogetkeyvalue /etc/synoinfo.conf runha`

if [ "yes" == "${runha}" ]; then
    exit 1
fi

exit 0
