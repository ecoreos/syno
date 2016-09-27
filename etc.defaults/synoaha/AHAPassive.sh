#!/bin/sh

SYNOBOOT3_WRITE_CYCLE_TIME=$((1 * 24 * 60 * 60))    # seconds
SYNOBOOT3_LIMIT_WRITE_COUNT=$((2 * 1024 * 1024))    # bytes
SYNOBOOT3_MOUNT_POINT=`/usr/syno/synoaha/bin/synoahastr --synoboot3-mount-point`

write_log()
{
	target_dir=$1
	log_dir=$2
	if [ "" = "$target_dir" ]; then
		echo "Wrong target path: $target_dir"
		exit 1
	fi

	log_file=`/bin/ls "$target_dir" | /usr/bin/sort -r`
	for file in $log_file; do
		file_size=0
		file_path="$target_dir/$file"
		if [ ! -f $file_path ]; then
			continue
		fi
		file_size=`/bin/ls -al $file_path | awk '{print $5}'`
		synoboot3_write_count=`cat /sys/fs/ext4/synoboot3/session_write_kbytes` # kbytes
		synoboot3_write_count=$(($synoboot3_write_count * 1024)) # bytes
		file2synoboot3=`/bin/echo $file | sed 's/.[0-9]//g'` # ex. message.1 => message
		synoboot3_log_path="$SYNOBOOT3_MOUNT_POINT/$log_dir/$file2synoboot3"
		if [ `expr $synoboot3_write_count + $file_size` -ge $SYNOBOOT3_LIMIT_WRITE_COUNT ]; then
			continue
		fi
		cat $file_path >> $synoboot3_log_path
		# clean log
		cat /dev/null > $file_path
	done
}

write_log_to_synoboot3()
{
	write_log /var/log log
	/bin/rm /var/log/*.[1-9] &>/dev/null
	write_log /var/log/synolog log/synolog
	/bin/rm /var/log/synolog/*.[1-9] &>/dev/null
	# rotate the log in synoboot3
	/usr/bin/logrotate /usr/syno/synoaha/etc/AHALogrotateBoot3.conf
}

monitor_synoboot3()
{
	count=0
	while [ 1 ]; do
		write_log_to_synoboot3
		sleep 3600
		count=`expr $count + 3600`
		if [ $count -ge $SYNOBOOT3_WRITE_CYCLE_TIME ]; then
			count=0
			# remount synoboot3 to update session_write_kbytes
			umount $SYNOBOOT3_MOUNT_POINT
			/usr/syno/synoaha/bin/synoaha --mount-synoboot3 $SYNOBOOT3_MOUNT_POINT
		fi
	done
}

monitor_var_log_rotate()
{
	while [ 1 ]; do
		/usr/bin/logrotate /usr/syno/synoaha/etc/AHALogrotate.conf
		sleep 10
	done
}

wait_hdd_ready()
{
	# Get the sas address of host sas controller
	host_sas_addr=`cat /sys/class/scsi_host/host0/host_sas_address`
	# Remove prefix 0x
	host_sas_addr="${host_sas_addr#0x}"

	# Maximum delay time: 200s
	delay_limit=200
	total_delay=0

	while [ $total_delay -lt $delay_limit ]
	do
		# Count numbers of attached PHYs
		phy_count_total=0
		for i in /sys/class/sas_device/expander-*
		do
			sas_addr=`cat $i/sas_address`
			phy_enum=`$EXEC_BINARY /usr/syno/bin/synoses --phy_enum $sas_addr`
			phy_count=`echo "$phy_enum" | cut -d " " -f3 | grep -c 1`

			# Don't count the upper link PHYs which are connected to the host
			phys_attached_host=`echo "$phy_enum" | grep -c $host_sas_addr`
			phy_count=$(($phy_count-$phys_attached_host))

			phy_count_total=$(($phy_count_total+$phy_count))
		done

		# Count numbers of block device sasX
		hdd_count=`ls /sys/block/ | grep -c sas*`
		hdd_dev_count=`ls /dev/ | grep "^sas" | grep -c -v p`

		if [ $hdd_count -lt $phy_count_total -o $hdd_dev_count -lt $phy_count_total ]; then
			echo "======== Wait HDD Ready (block: $hdd_count, dev node: $hdd_dev_count, total: $phy_count_total) ========"
			sleep 5

			total_delay=$(($total_delay+5))
		else
			echo "======== All HDD Ready ($hdd_count, $hdd_dev_count, $phy_count_total) ========="
			break
		fi
	done
}

action=$1;
shift

case "$action" in
	monitor_synoboot3)
		monitor_synoboot3
		;;
	monitor_var_log_rotate)
		monitor_var_log_rotate
		;;
	write_log_to_synoboot3)
		write_log_to_synoboot3
		;;
	wait_hdd_ready)
		wait_hdd_ready
		;;
	*)
		exit 1
		;;
esac
