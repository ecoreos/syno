#!/bin/sh
#
# Usage:
#        handler_sb.sh safemode [ --boot ]
#			After 5.0 hotfix 1, SHA support safemode to handle split-brain
#
#        handler_sb.sh unbind
#
# return 1: error, unbind local
#        2: standby failed
#
# vim:ft=sh


HA_PREFIX=/usr/syno/synoha

. $HA_PREFIX/etc.defaults/rc.subr
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/syno/sbin:/usr/syno/bin:/usr/local/sbin:/usr/local/bin:/usr/syno/synoha/sbin

SYNO_HA_SAFEMODE=$HA_SAFEMODE_INFO
SYNO_HA_PREV_ACTIVE=$PREVIOUS_ROLE_ACTIVE
SYNO_HA_PREV_PASSIVE=$PREVIOUS_ROLE_PASSIVE
SYNO_HA_ORIGINAL_HOSTNAME_FILE=$CRM_HOSTNAME_ORIGINAL
SB_FLOCK='/tmp/.ha.handler_sb.lock'
SYNOVSPACE="/usr/syno/bin/synovspace"
SYNO_HA_PING=$HA_PING_SERVER

lock()
{
	if [ -f "$SB_FLOCK" ]; then
		local prev_lock=`cat $SB_FLOCK`
		synoha_log "SB: handler_sb.sh lock ($1) failed, pervious lock pid:$prev_lock"
		return $LSB_ERR_GENERIC
	fi

	trap '/bin/rm "$SB_FLOCK" &> /dev/null' INT TERM EXIT ABRT
	echo "$$ $1" > "$SB_FLOCK"
	return $LSB_SUCCESS
}

unlock()
{
	/bin/rm "$SB_FLOCK" &> /dev/null
}

Unbind()
{
	synoha_log "SB: Split brain handler failed: $1"
	$SYNOHA_BIN --handle-sb &
	exit 1
}

ClearHAStates()
{
	synoha_log notice "SB: Clear HA status"
	crm resource cleanup DRBD          &> /dev/null
	crm -F node clearstate $LOCAL_HOST &> /dev/null
}

send_cib_info()
{
	while :; do
		[ -f "$SYNO_HA_SAFEMODE" ] || exit 0

		if ! /bin/ps auxw | grep "synoha --cib-hdinfo-set" | grep -v grep &> /dev/null ; then
			$SYNOHA_BIN --cib-hdinfo-set
		fi
		if ! /bin/ps auxw | grep "synoha --cib-mdinfo-set" | grep -v grep &> /dev/null ; then
			$SYNOHA_BIN --cib-mdinfo-set
		fi
		if ! /bin/ps auxw | grep "synoha --cib-nodeinfo-set" | grep -v grep &> /dev/null ; then
			$SYNOHA_BIN --cib-nodeinfo-set
		fi
		if ! /bin/ps auxw | grep "synoha --cib-ifinfo-set" | grep -v grep &> /dev/null ; then
			$SYNOHA_BIN --cib-ifinfo-set
		fi
		sleep 30
	done
}

standby_and_set_constraint()
{
	local constraint_t="<constraints><rsc_location id='RULE_SB_%s' node='%s' rsc='DUMMY_START' score='-INFINITY'/></constraints>"
	local standby_t="<instance_attributes id='nodes-%s'><nvpair id='nodes-%s-standby' name='standby' value='on'/></instance_attributes>"
	for h in "$NODE_HOST0" "$NODE_HOST1"; do
		# when bootup, only set constraint & standby to LOCAL_HOST
		[ "--boot" == "$hasReboot" -a "$LOCAL_HOST" != "$h" ] && continue

		local cons=`printf "$constraint_t" $h $h`
		cibadmin -Mc --xml-text "$cons"

		local stby=`printf "$standby_t" $h $h`
		cibadmin -Mc --xml-text "$stby"
	done
}

start_handle_sb()
{
	local hasReboot=$1

	# prevent multiple handle_sb
	if [ "--boot" != "$hasReboot" ]; then
		[ -f "$SYNO_HA_SAFEMODE" ] && exit 0
	fi

	{
		synoha_log warning "SB: Split brain handler"

		[ -n "$NODE_HOST0" ] || Unbind "host0 missing"
		[ -n "$NODE_HOST1" ] || Unbind "host1 missing"

		mkdir -p $HA_SAFEMODE_DIR
		touch $SYNO_HA_SAFEMODE

		synoha --notify safe-mode &> /dev/null

		[ "--boot" != "$hasReboot" ] && synoha --save-ha-state-time split-brain &> /dev/null

		rm -f "$SYNO_HA_PREV_ACTIVE"
		rm -f "$SYNO_HA_PREV_PASSIVE"

		/bin/ps auxw | grep -v grep | grep "wait-then-online" | awk '{print $2}' | xargs -r kill

		[ "--boot" != "$hasReboot" ] && synoha --remote-run-safemode

		standby_and_set_constraint

		synoha_log warning "SB: Split brain handler done"

		local IP_managed=`crm_resource --resource IP --get-parameter is-managed --meta 2>/dev/null`
		if [ "false" == "$IP_managed" ]; then
			crm_resource --resource IP --set-parameter is-managed --meta --parameter-value true
		fi

		_check_standby()
		{
			local _dummy_start_location="`crm_resource --resource DUMMY_START --locate`"
			local _infoset_location="`crm_resource --resource INFO_SET --locate`"
			local _drbd_location="`crm_resource --resource DRBD --locate`"
			local _checkpointlast_location="`crm_resource --resource CHECKPOINT_LAST --locate`"
			local _confsync_location="`crm_resource --resource CONF_SYNC --locate`"
			local _all_location="$_dummy_start_location $_infoset_location $_drbd_location $_checkpointlast_location $_confsync_location"

			local _localhost_stby=`echo "$_all_location" | grep $LOCAL_HOST`
			local _host0_stby=`echo "$_all_location" | grep $NODE_HOST0`
			local _host1_stby=`echo "$_all_location" | grep $NODE_HOST1`

			if [ "--boot" == "$hasReboot" ]; then
				# only wait for local standby after reboot
				[ -z "$_localhost_stby" ]
			else
				[ -z "$_host0_stby" -a -z "$_host1_stby" ]
			fi

			local _ret=$?

			if [ 0 -ne $_ret ]; then
				standby_and_set_constraint
			fi

			return $_ret
		}

		local _sleep_sec=5
		if ! HASleepFor _check_standby $MAX_HA_SERV_STOP_SEC $_sleep_sec &> /dev/null ; then
				synoha_log "SB: Standby failed, force reboot"
				crm_mon -n -1 | synoha_log notice
				ClearHAStates
				/sbin/reboot -f
				exit 2
		fi

		ClearHAStates

		# Backup user settings
		ha_safemode_backup_user_settings

		# Load all volumes as read-only
		synoha_log notice "vspace all-load"
		$SYNOVSPACE -all-load
		/usr/syno/cfgen/s00_synocheckfstab
		awk '$1 ~ /\/dev\/drbd/ {$4="ro,"$4} {print}' /etc/fstab > /etc/fstab.ro
		mv /etc/fstab.ro /etc/fstab
		/etc.defaults/rc.volume start &> /dev/null

		# Make all shares read-only
		synoha --lock-shares

		# Remove all sessions
		rm -f /usr/syno/etc/private/session/current.users.access.time/*

		# Start rsync daemon
		$RSYNC_PROG $HA_RSYNC_OPTION

		# Keep required services
		synoha_log notice "Pause all services by reason ha-split-brain except those in ha-safe-mode"
		$SYNOSERVICECFG_BIN --pause-all ha-split-brain ha-safe-mode
		synoha_log notice "Resume all services paused by reason ha-passive"
		$SYNOSERVICECFG_BIN --resume-all ha-passive
		synoha_log notice "Start ssh-shell"
		$SYNOSERVICECFG_BIN --start ssh-shell

		/usr/syno/bin/synobootseq --set-boot-done
		send_cib_info &

		# Retreive local shares list
		/usr/syno/bin/synowebapi --exec api=SYNO.Core.Share method=list version=1 2> /dev/null | \
			/bin/jq -c 'if .success == true then .data.shares | map({"name": (.vol_path+"/"+.name)}) else [] end' > "${HA_SAFEMODE_DIR}shares.`cat $CRM_HOSTNAME_ORIGINAL`"

		synoha_log warning "SB: enter SHA safemode"
	}&

} # end of start_handle_sb()

standby_both()
{
	local standby_t="<instance_attributes id='nodes-%s'><nvpair id='nodes-%s-standby' name='standby' value='on'/></instance_attributes>"
	for h in "$NODE_HOST0" "$NODE_HOST1"; do
		local stby=`printf "$standby_t" $h $h`
		cibadmin -Mc --xml-text "$stby"
	done
}

start_handle_ping()
{
	local count=60

	# prevent multiple handle_ping
	[ -f "$SYNO_HA_PING" ] && exit 0

	{
	touch $SYNO_HA_PING

	standby_both

	_check_standby()
	{
		local _dummy_start_location="`crm_resource --resource DUMMY_START --locate`"
		local _infoset_location="`crm_resource --resource INFO_SET --locate`"
		local _drbd_location="`crm_resource --resource DRBD --locate`"
		local _checkpointlast_location="`crm_resource --resource CHECKPOINT_LAST --locate`"
		local _confsync_location="`crm_resource --resource CONF_SYNC --locate`"
		local _all_location="$_dummy_start_location $_infoset_location $_drbd_location $_checkpointlast_location $_confsync_location"

		local _host0_stby=`echo "$_all_location" | grep $NODE_HOST0`
		local _host1_stby=`echo "$_all_location" | grep $NODE_HOST1`

		[ -z "$_host0_stby" -a -z "$_host1_stby" ]
		local _ret=$?

		if [ 0 -ne $_ret ]; then
			standby_both
		fi

		return $_ret
	}

	local _sleep_sec=5
	if ! HASleepFor _check_standby $MAX_HA_SERV_STOP_SEC $_sleep_sec &> /dev/null ; then
		synoha_log "SB: Standby failed, entering safe mode, instead"
		start_handle_sb
		exit $?
	fi

	rm -f $CIB_INFO_NODE_REMOTE

	while [ ! -f $CIB_INFO_NODE_REMOTE ]; do
		if [ $count -le 0 ]; then
			synoha_log err "Failed to retrieve remote's bumped_admin_epoch, entering safemode"
			start_handle_sb
			exit $?
		fi
		if ! /bin/ps auxw | grep "synoha --cib-nodeinfo-set" | grep -v grep &> /dev/null ; then
			$SYNOHA_BIN --cib-nodeinfo-set
		fi
		count=$(($count - 1))
		sleep 1
	done

	remote_has_bumped_admin_epoch="`get_key_value $CIB_INFO_NODE_REMOTE NODE_BUMPED_ADMIN_EPOCH`"
	local_has_bumped_admin_epoch="no"
	if [ -f $FLAG_HA_HAS_BUMPED_UP_ADMIN_EPOCH ]; then
		local_has_bumped_admin_epoch="yes"
	fi
	if [ "$remote_has_bumped_admin_epoch" = "$local_has_bumped_admin_epoch" ]; then
		synoha_log warning "Both remote and local have same admin_epoch, entering safe mode"
		start_handle_sb
	elif [ "yes" = "$remote_has_bumped_admin_epoch" ]; then
		synoha_log warning "Remote has bumped admin_epoch, let's be passive"
		touch $PREVIOUS_ROLE_PASSIVE
		/sbin/reboot
	else
		synoha_log warning "Local has bumped admin_epoch, let's be active"
		touch $PREVIOUS_ROLE_ACTIVE
		/sbin/reboot
	fi
	}&
} # end of start_handle_ping()

lock $1 || exit $?

[ -e $HA_PREFIX/etc/ha.conf ] || Unbind "ha.conf missing"

action=$1; shift
case "$action" in
	pingserver)
		start_handle_ping
		;;
	safemode)
		start_handle_sb "$@"
		;;
	unbind)
		Unbind
		;;
	*)
		exit $LSB_ERR_ARGS
esac

exit $?

