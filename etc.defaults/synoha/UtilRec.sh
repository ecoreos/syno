#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

RECORD_LOG="/var/log/cluster/sysrec.log"
RECORD_LOG_TMP="/tmp/ha/.sysrec.log.tmp"

exec &> $RECORD_LOG_TMP
set -x

date
top -n 2 -b -w 1024
ps auxf
df
free
cat /proc/vmstat
cat /proc/meminfo
cat /proc/interrupts
cat /proc/slabinfo
ifconfig

set +x
exec &> /dev/null
cat $RECORD_LOG_TMP >> $RECORD_LOG
