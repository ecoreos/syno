#!/bin/sh
# Copyright (c) 2000-2013 Synology Inc. All rights reserved.

synobios=`get_key_value /etc.defaults/synoinfo.conf synobios`
if [ "xyes" == "x`get_key_value /etc/synoinfo.conf usbstation`" -o "kvmx64" == "$synobios" -o "dockerx64" == "$synobios" ]; then
	sed -i '/syno_disk_health_record/d' /etc/crontab
	exit
fi

ct=`grep -c syno_disk_health_record /etc/crontab`
if [ $ct -eq 0 ]; then
	echo -e "0\t0\t1\t*\t*\troot\t/usr/syno/bin/syno_disk_health_record" >> /etc/crontab
fi

m1=`cat /usr/syno/etc/disk_health_record_time | awk '{print $2}'`
y1=`cat /usr/syno/etc/disk_health_record_time | awk '{print $5}'`
m2=`date | awk '{print $2}'`
y2=`date | awk '{print $6}'`
if [ "$m1" != "$m2" -o "$y1" != "$y2" ]; then
	/usr/syno/bin/syno_disk_health_record
fi
