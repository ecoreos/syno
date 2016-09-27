#!/bin/sh

HA_PREFIX="/usr/syno/synoha"
HA_BIN=$HA_PREFIX"/sbin/synoha"

. $HA_PREFIX/etc.defaults/rc.subr

SZ_REBOOT=$AIS_REBOOT
SZ_SYNOLOG_REQ=$AIS_SYNOLOG_REQ
SZ_SYNOLOG_RESP=$AIS_SYNOLOG_RESP
SZ_INFOSET_REQ=$AIS_INFOSET_REQ
SZ_PASSIVE_MAC=$AIS_PASSIVE_MAC
SZ_RUN_SSHD=$AIS_RUN_SSHD
SZ_STOP_SSHD=$AIS_STOP_SSHD
SZ_RUN_SAFEMODE=$AIS_RUN_SAFEMODE
SZ_CHK_SAFEMODE=$AIS_CHECK_SAFEMODE
SZ_CHK_SAFEMODE_REPLY=$AIS_CHECK_SAFEMODE_REPLY
SZ_CHK_SAFEMODE_REPLY_TRUE="${SZ_CHK_SAFEMODE_REPLY}_true__"
SZ_CHK_SAFEMODE_REPLY_FALSE="${SZ_CHK_SAFEMODE_REPLY}_false_"
SZ_DO_SCRUBBING=$AIS_DO_SCRUBBING
SZ_CANCEL_SCRUBBING=$AIS_CANCEL_SCRUBBING
SZ_SB_SET_ROLE=$AIS_SB_SET_ROLE
SZ_CHANGE_DSM_VERSION=$AIS_CHANGE_DSM_VERSION
SZ_TOUCH_SHUTDOWN_FLAG=$AIS_TOUCH_SHUTDOWN_FLAG
SZ_TOUCH_WAIT_FSCK_FLAG=$AIS_TOUCH_WAIT_FSCK_FLAG
SZ_SYNOLOG_REMOTE=$AIS_SYNOLOG_REMOTE

SYNO_UNBIND_WITH_REBOOT=$UNBIND_WITH_REBOOT
SYNO_HA_ROLE_ACTIVE=$ROLE_ACTIVE

SZF_SYNO_VERSION_DEF="/etc.defaults/VERSION"
SZF_SYNO_VERSION_DEF_TMP="${SZF_SYNO_VERSION_DEF}.tmp"
SZF_REMOTE_SHUTDOWN_FLAG=$REMOTE_SHUTDOWN_FLAG
SZF_WAIT_FSCK_FLAG=$WAIT_FSCK_FLAG
SZF_HA_STATUS_RECORD=$HA_STATUS_RECORD

log()
{
	echo "[$(/bin/date +%c)] $@" >> $HA_PREFIX/var/log/cluster/ais.action
}

if [ $# != 1 ] || [ "/tmp/.ais." != "`echo $1 | head -c 10`" ]; then
	log "unknown file:" $@
	exit 1
fi

# $1 is a tmp file (name)
# first line is the message/header/command, others are the file content (if any)
# 1-8 bytes: header
header=`head -c 8 $1`

case "$header" in
	"STRUCT  ")
		log "[STRUCT] $1"
		{
			$HA_PREFIX/sbin/synodrbd --handle-ais-msg $1
			rm -f $1
		}&
		;;
#todo: handle reboot by cgi or something
	$SZ_REBOOT)
		log "[Reboot]"
		{
			sleep 3
			$HA_PREFIX/etc.defaults/rc.ha stop
			reboot
			rm -f $1
		}&
		;;
#todo: handle poweroff by cgi or something
	$SYNO_HA_AIS_POWEROFF)
		log "[Poweroff]"
		{
			sleep 3
			$HA_BIN --poweroff-ds
			rm -f $1
		}&
		;;
	$SZ_SYNOLOG_REQ)
		#log "[LogReq]"
		{
			$HA_BIN --receive-synolog-info $1
			rm -f $1
		}&
		;;
	$SZ_DO_SCRUBBING)
		{
			data=`cat $1`
			$HA_BIN --receive-do-scrubbing $data
			rm -f $1
		}&
		;;
	$SZ_CANCEL_SCRUBBING)
		{
			data=`cat $1`
			$HA_BIN --receive-cancel-scrubbing $data
			rm -f $1
		}&
		;;
	$SZ_SYNOLOG_RESP)
		#log "[LogResp]"
		SZF_HA_TMP_SYNOLOG_RESP=$HA_LOG_RESP_RESULT
		echo `head -c 16 $1 | cut -b 9-16` > $SZF_HA_TMP_SYNOLOG_RESP
		rm -f $1
		;;
	$SZ_INFOSET_REQ)
		#log "[InfosetReq]"
		{
			$HA_BIN --receive-infoset $1
			rm -f $1
		}&
		;;
	"UNBIND  ")
		log "[Unbind]"
		{
			sleep 3
			unbind_type=`cat $1 | cut -b 9-1024`
			$HA_PREFIX/sbin/synoha --unbind-local $SYNO_UNBIND_WITH_REBOOT "$unbind_type" &> /dev/null &
			# wait reboot after unbind local
			sleep 300
			reboot -f
			rm -f $1
		}&
		;;
	"UB_REMOT")
		log "[Unbind Remote]"
		{
			$HA_PREFIX/sbin/synoha --unbind-remote &
		}&
		;;
	"SAVE_KEY")
		log "[Save_key]"
		{
			cat $1 > $SYNO_HA_AUTH_KEY
			$HA_PREFIX/sbin/synoha --auth-key `cat $1`
			rm -f $1
		}&
		;;
	"SHUTBEEP")
		log "[Shut_Beep]"
		{
			$HA_PREFIX/sbin/synoha --stop-beep
			rm -f $1
		}&
		;;
	"CONF_CHG")
		log "[SYNOINFO_CHANGE]"
		{
			$HA_PREFIX/sbin/synoha --signal-scemd synoinfo-change
			rm -f $1
		}&
		;;
	"FENCING ")
		{
			action=`head -c 16 $1 | cut -b 9-16`
			log "[FENCING] $action"
			case "$action" in
				"TRYFENCE")
					handle_too_active "$action"
					;;
				"DONE    ")
					touch $FLAG_HA_REMOTE_IS_FENCED
					;;
				*)
					synoha_log "unknown action: ${action}."
					;;
			esac
			rm -f $1
		}&
		;;
	"UPGRADE ")
		# the same as ha_upgrade.cc
		# MUST change them both
		log "[Upgrade]"
		SZF_HA_UPG_INFO=$HA_UPGRADE_INFO
		SZF_HA_UPG_INFO_TMP="$SZF_HA_UPG_INFO.tmp"
		SZF_HA_REMOTE_UPG=$HA_REMOTE_UPGRADE
		SZF_HA_REMOTE_UPG_TMP="$SZF_HA_REMOTE_UPG.tmp"
		SZK_HA_UPG_PROGRESS="progress"
		# Reference the struct HA_AIS_UPG_HEADER with member "mark", "cmd", and "data"
		cmd=`head -c 16 $1 | cut -b 9-16`
		data=`cat $1 | cut -b 17-80`
		case "$cmd" in
			"DONE_ACT"|"FAIL_ACT")
				log "[upg result $cmd]"
				if [ "$cmd" == "ERR_PASS" -a "$data" != "" ]; then
					echo "$data" > "/tmp/update.progress"
				fi
				sed "/$SZK_HA_UPG_PROGRESS/d" $SZF_HA_UPG_INFO > $SZF_HA_UPG_INFO_TMP
				if [ -s $SZF_HA_UPG_INFO_TMP ]; then
					echo "$SZK_HA_UPG_PROGRESS=$cmd" >> $SZF_HA_UPG_INFO_TMP
					mv $SZF_HA_UPG_INFO_TMP $SZF_HA_UPG_INFO
				fi
				;;
			"FAIL_UPG")
				log "[upg fail $cmd]"
				rm $SZF_HA_UPG_INFO
				;;
			"DONE_PAS"|"FAIL_PAS")
				log "[upg result $cmd]"
				echo "$SZK_HA_UPG_PROGRESS=$cmd" > $SZF_HA_REMOTE_UPG_TMP
				if [ -f $SZF_HA_REMOTE_UPG ]; then
					mv $SZF_HA_REMOTE_UPG_TMP $SZF_HA_REMOTE_UPG
				else
					rm -f $SZF_HA_REMOTE_UPG_TMP
				fi
				;;
			"PRESTART")
				log "[passive upg pre-start]"
				/bin/ps auxw | grep -v grep | grep "wait-then-online" | awk '{print $2}' | xargs -r kill
				touch $SZF_HA_UPG_INFO
				{
				retry=0
				sleep 6300 # define MAX_UPGRADE_TIME_ACTIVE
				if [ -f "$SZF_HA_UPG_INFO" ] && [ "passive" != "`/usr/syno/bin/synogetkeyvalue $SZF_HA_UPG_INFO role`" ]; then
					synoha_log "Active upgrade timeout, unbind remote and online local"
					rm -f $SZF_HA_UPG_INFO
					$HA_BIN --isolate-apply &> /dev/null
					$HA_BIN --online &> /dev/null
					while [ "$SYNO_HA_ROLE_ACTIVE" != "`$HA_BIN --local-role`" ]; do
						synoha_log notice "Wait passive server promote: $retry"
						if [ $retry -eq 180 ]; then
							synoha_log "Wait passive server promote timeout"
							break;
						fi
						retry=$(($retry + 1))
						sleep 1
					done
					$HA_BIN --unbind-remote &> /dev/null
					$HA_BIN --isolate-restore &> /dev/null
				fi
				}&
				;;
			"START   ")
				log "[upg start]"
				# This is the passive upgrad entry point
				echo "$data" > "/var/lib/ha/ha_remote_upgrade"
				$HA_BIN --upg-start-passive &
				;;
			*)
			log "unknown cmd: $cmd"
				;;
		esac
		rm -f $1
		;;
	$SZ_HA_NODE_ONLINE)
		log "[Node online]"
		{
			_host=`head -c 48 $1 | cut -b 9-48`
			log "node $_host online"
			localRole=`$HA_BIN --local-role`
			if [ "$SYNO_HA_ROLE_ACTIVE" == "$localRole" ]; then
				if [ -f $FLAG_HA_REMOTE_IS_FENCED ] ; then
					rm -f $FLAG_HA_REMOTE_IS_FENCED
					synoha_log notice "clean up remove fencing flag"
				fi

				HAWaitCibInfoReady
				$HA_BIN --check-remote-ssd-cache &> /dev/null
				$HA_BIN --check-memsize-when-cache-exist &> /dev/null
				$HA_BIN --check-flashcache-sysctl &> /dev/null
				$HA_BIN --synolog-remote sys info 0x13400044 &> /dev/null
				$SYNOLOGSET1_BIN sys info 0x13400044 &> /dev/null
			fi

			rm -f $1
			rm -f $SZF_REMOTE_SHUTDOWN_FLAG
			rm -f $SZF_WAIT_FSCK_FLAG
			rm -f $SZF_HA_STATUS_RECORD
		}&
		;;
	$SZ_PASSIVE_MAC)
		log "[Recive mac form remote node]"
		{
			$HA_PREFIX/sbin/synoha --fill-ha-mac-passive $1
			rm -f $1
		}&
		;;
	$SYNO_HA_MESG_REQ_AIS_HEADER)
		_SN=`head -c 24 $1 | cut -b 9-24`
		_SYNO_HA_DEBUG_DAT="${SYNO_HA_DEBUG_DAT}.$_SN"
		_SYNO_HA_DEBUG_DIR="${_SYNO_HA_DEBUG_DAT}.dir"
		log "[mesg req $_SN ]"
		{
			rm -rf "$_SYNO_HA_DEBUG_DAT" "$_SYNO_HA_DEBUG_DIR"
			/usr/syno/bin/synomsg_collector2 "${_SYNO_HA_DEBUG_DIR}"
			/usr/bin/tar czhf "$_SYNO_HA_DEBUG_DAT" "${_SYNO_HA_DEBUG_DIR}"
			$HA_PREFIX/etc.defaults/rc.ha send-debug-dat $_SN
			rm -rf "$_SYNO_HA_DEBUG_DAT" "$_SYNO_HA_DEBUG_DIR"
			rm -f $1
		}&
		;;
	$SYNO_HA_MESG_RES_AIS_HEADER)
		_SN=`head -c 24 $1 | cut -b 9-24`
		_SYNO_HA_DEBUG_DAT_DONE=${SYNO_HA_DEBUG_DAT_DONE}.$_SN
		log "[mesg res $_SN ]"
		{
			touch $_SYNO_HA_DEBUG_DAT_DONE
			rm -f $1
		}&
		;;
	$SZ_RUN_SSHD)
		log "[Run sshd]"
		{
			/usr/syno/sbin/synoservice --resume-by-reason ssh-shell ha-passive
			rm -f $1
		}&
		;;
	$SZ_STOP_SSHD)
		log "[Stop sshd]"
		{
			/usr/syno/sbin/synoservice --pause-by-reason ssh-shell ha-passive
			rm -f $1
		}&
		;;
	$SZ_RUN_SAFEMODE)
		log "[Run safemode]"
		{
			if ! [ -f "$SYNO_HA_SAFEMODE" ]; then
				$HA_PREFIX/sbin/handler_sb.sh safemode
			fi
			rm -f $1
		}&
		;;
	$SZ_CHK_SAFEMODE)
		log "[Check safemode]"
		{
			if [ -f "$SYNO_HA_SAFEMODE" ]; then
				crm_node --node="$REMOTE_HOST" --mesg="${SZ_CHK_SAFEMODE_REPLY_TRUE}"
			else
				crm_node --node="$REMOTE_HOST" --mesg="${SZ_CHK_SAFEMODE_REPLY_FALSE}"
			fi
			rm -f $1
		}&
		;;
	$SZ_CHK_SAFEMODE_REPLY)
		log "[Check safemode reply]"
		{
			SZF_SB_REMOTE_IN_SAFEMODE=$SB_REMOTE_IN_SAFEMODE
			SZF_SB_REMOTE_NOT_IN_SAFEMODE=$SB_REMOTE_NOT_IN_SAFEMODE

			rm -f $SZF_SB_REMOTE_IN_SAFEMODE $SZF_SB_REMOTE_NOT_IN_SAFEMODE
			if [ "`head -c 15 $1`" == "$SZ_CHK_SAFEMODE_REPLY_TRUE" ]; then
				touch $SZF_SB_REMOTE_IN_SAFEMODE
			else
				touch $SZF_SB_REMOTE_NOT_IN_SAFEMODE
			fi
			rm -f $1
		}&
		;;
	$SZ_SB_SET_ROLE)
		{
			data=`cat $1 | cut -b 17-80`
			log "[Set SB Role:$data]"
			$HA_BIN --set-sb-role $data
			rm -f $1
		}&
		;;
	$SZ_CHANGE_DSM_VERSION)
		log "[Change dsm version] $1"
		{
			version=`cat $1 | cut -b 9-24`;
			major=`echo $version | cut -d"," -f 1`
			minor=`echo $version | cut -d"," -f 2`
			build=`echo $version | cut -d"," -f 3`
			log "major=$major minor=$minor build=$build"
			sed 's/^majorversion=.*$/majorversion="'$major'"/; s/^minorversion=.*$/minorversion="'$minor'"/; s/^buildnumber=.*$/buildnumber="'$build'"/' $SZF_SYNO_VERSION_DEF > $SZF_SYNO_VERSION_DEF_TMP
			mv $SZF_SYNO_VERSION_DEF_TMP $SZF_SYNO_VERSION_DEF
		}&
		;;
	$AIS_NOTIFY_REMOTE)
		log "[Notification from remote]"
		{
			data="Notification from $REMOTE_HOST - [`cat $1 | cut -b 9-72`]"
			synoha_log warning "$data"
		}&
		;;
	$SZ_TOUCH_SHUTDOWN_FLAG)
		log "[Remote shutdown first]"
		{
			touch $SZF_REMOTE_SHUTDOWN_FLAG
		}&
		;;
	$SZ_TOUCH_WAIT_FSCK_FLAG)
		log "[Do fsck now]"
		{
			touch $SZF_WAIT_FSCK_FLAG
		}&
		;;
	$SZ_SYNOLOG_REMOTE)
		log "[Get synolog]"
		{
			args="`cat $1 | cut -b 9-264`"
			eval $SYNOLOGSET1_BIN $args
		}&
		;;
	$AIS_SYNC_MD0_MD1)

		log "[Sync md0 partion]"
		{
			# wait for conf sync done
			sleep 5
			synostgsysraid --sync
		}&
		;;
	$AIS_PASSIVE_ENTER_UPS_SAFEMODE)
		log "[Passive enter UPS safe mode]"
		{
			[ -e $SZF_HA_IN_UPS_SAFEMODE ] && exit 0
			touch $SZF_HA_IN_UPS_SAFEMODE
			sleep 3
			enter_ups_safemode
			rm -f $1
		}&
		;;
	"API_REQ ")
		log "[Exec webapi]"
		{
			pid="`cat $1 | cut -b 9-16`"
			args="`cat $1 | cut -b 17-512`"
			echo "API_RESP" > /tmp/ha/.ha.webapi.$$
			echo $pid >> /tmp/ha/.ha.webapi.$$
			eval synowebapi $args >> /tmp/ha/.ha.webapi.$$
			crm_node --node="$REMOTE_HOST" --mesg="-fIlE-:/tmp/ha/.ha.webapi.$$"

			rm -f /tmp/ha/.ha.webapi.$$
			rm -f $1
		}&
		;;
	"API_RESP")
		log "[response webapi]"
		{
			sed -i '1d' $1
			pid="`head -n 1 $1`"
			sed -i '1d' $1
			cp $1 /tmp/ha/ha.webapi.return.$pid

			rm -f $1
		}&
		;;
	*)
		log "unknown header: ${header}."
		rm -f $1
		exit 1
		;;
esac
exit 0
