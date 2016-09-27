#!/bin/sh
# Copyright (c) 2000-2012 Synology Inc. All rights reserved.

#1: action
#2: interface name

if [ "" == "$2" ]; then
	return
fi
eth=$2

GC_THRESH1="/proc/sys/net/ipv4/neigh/default/gc_thresh1"
GC_THRESH2="/proc/sys/net/ipv4/neigh/default/gc_thresh2"
GC_THRESH3="/proc/sys/net/ipv4/neigh/default/gc_thresh3"
GC_THRESH1_TMP="/tmp/gc_thresh1"
GC_THRESH2_TMP="/tmp/gc_thresh2"
GC_THRESH3_TMP="/tmp/gc_thresh3"

case "$1" in
	remove)
		ip link set dev $eth arp off
		arp -a -n | while read line; do
			ip=`echo $line | cut -d'(' -f2 | cut -d ')' -f1`
			arp -d $ip -i $eth &> /dev/null
		done
		sleep 1
		if [ -f $GC_THRESH1_TMP ]; then
			echo `cat $GC_THRESH1_TMP` > $GC_THRESH1
		fi
		if [ -f $GC_THRESH2_TMP ]; then
			echo `cat $GC_THRESH2_TMP` > $GC_THRESH2
		fi
		if [ -f $GC_THRESH3_TMP ]; then
			echo `cat $GC_THRESH3_TMP` > $GC_THRESH3
		fi
		ip link set dev $eth arp on
		;;
	scan)
		if [ ! -f $GC_THRESH1_TMP ]; then
			echo `cat $GC_THRESH1` > $GC_THRESH1_TMP
		fi
		if [ ! -f $GC_THRESH2_TMP ]; then
			echo `cat $GC_THRESH2` > $GC_THRESH2_TMP
		fi
		if [ ! -f $GC_THRESH3_TMP ]; then
			echo `cat $GC_THRESH3` > $GC_THRESH3_TMP
		fi
		echo 2048 > $GC_THRESH1
		echo 2048 > $GC_THRESH2
		echo 4096 > $GC_THRESH3

		ping -s 1 -c 3 -W 1 -I $eth -b 255.255.255.255 &> /dev/null &
		sleep 1
		arp -a -n | while read line; do
			ip=`echo $line | cut -d'(' -f2 | cut -d ')' -f1`
			ping -s 1 -c 1 -W 1 -I $eth $ip &> /dev/null &
		done
		;;
	count)
		arp -n -i $eth | grep -v incomplete | wc -l
		;;
esac

