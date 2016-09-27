#!/bin/sh

SYNO_INITD_DIR=/usr/syno/etc/rc.d

#. $HA_PREFIX/etc.defaults/serv_conf_def.sh
. /etc.defaults/rc.subr # For LSB_*
. /usr/syno/etc.defaults/synoaha/aha.rc.subr

AHA_PREFIX="/usr/syno/synoaha"
SYNO_AHA_STATUS_CHECK_LOG="/tmp/aha/status_check.log"

SYNOAHA_BIN="$AHA_PREFIX/bin/synoaha"
SYNOAHASTR_BIN="$AHA_PREFIX/bin/synoahastr"

SYNOSERVICECFG_BIN="/usr/syno/sbin/synoservice"
SERV_TYPE_NONE=0
SERV_TYPE_SYSV=1
SERV_TYPE_SYNO_SERVICE=2
SERV_TYPE_SYNO_PKG=3

SERV_MONITOR_INTERVAL=10
SERV_ISCSI_NAME=`$SYNOAHASTR_BIN --service-iscsi-name`

CheckServiceStatusReady() {
	_serv=$1
	if [ "$_serv" != "$SERV_ISCSI_NAME" ]; then
		return 0
	fi
	return 1
	CheckIfISCSIReady
	if [ "$?" == "0" ]; then
		return 0
	fi
	echo "service $_serv not ready" >> $SYNO_AHA_STATUS_CHECK_LOG
	return 1
}

# $1: service type (SERV_TYPE_NONE|SERV_TYPE_SYSV|SERV_TYPE_SYNO_SERVICE|SERV_TYPE_SYNO_PKG)
# $2: service name
# $3: execute command
GetServiceStatus()
{
	local _type=$1
	local _srv=$2
	local _file=$3

	case "$_type" in
		"$SERV_TYPE_SYSV")
			"$_file" status &>/dev/null
			return $?
			;;
		"$SERV_TYPE_SYNO_SERVICE")
			if [ "ftpd" == "$_srv" ]; then
				# ftpd and ftpd-ssl share same daemon ftpd, so only check one
				$SYNOSERVICECFG_BIN --is-enabled ftpd &>/dev/null
				if [ $? -eq 1 ] ; then
					# ftpd is enabled, check ftpd
					$SYNOSERVICECFG_BIN --status ftpd &>/dev/null
				else
					$SYNOSERVICECFG_BIN --status ftpd-ssl &>/dev/null
				fi
			else
				$SYNOSERVICECFG_BIN --status "$_srv" &>/dev/null
			fi
			return $?
			;;
		"$SERV_TYPE_SYNO_PKG")
			"$SYNO_PKG_BIN" status "$_srv" &>/dev/null
			return $?
			;;
		*)
			return $LSB_STAT_UNKNOWN
			;;
	esac
}

RestartService()
{
	local _type=$1
	local _srv=$2
	local _file=$3

	case "$_type" in
		"$SERV_TYPE_SYSV")
			$_file stop &>/dev/null
			$_file start &>/dev/null
			return $?
			;;
		"$SERV_TYPE_SYNO_SERVICE")
			if [ "ftpd" == "$_srv" ]; then
				# ftpd and ftpd-ssl share same daemon ftpd, so only restart one
				$SYNOSERVICECFG_BIN --is-enabled ftpd &>/dev/null
				if [ $? -eq 1 ] ; then
					# ftpd is enabled, restart ftpd anyway
					$SYNOSERVICECFG_BIN --restart ftpd &>/dev/null
				else
					$SYNOSERVICECFG_BIN --restart ftpd-ssl &>/dev/null
				fi
			else
				$SYNOSERVICECFG_BIN --restart "$_srv" &>/dev/null
			fi
			return $?
			;;
		"$SERV_TYPE_SYNO_PKG")
			$SYNO_PKG_BIN stop $_srv &>/dev/null
			$SYNO_PKG_BIN start $_srv &>/dev/null
			return $?
			;;
		*)
			return  $LSB_ERR_GENERIC
			;;
	esac
}

# $1: service name
CheckStatus()
{
	local _srv=$1
	local _file=
	local _type=
	local _ret=
	local _skip=

	_file=`find $SYNO_INITD_DIR/ -name "S[0-9][0-9]${_srv}.sh"`
	if [ "$_file" != "" ]; then
		_type=$SERV_TYPE_SYSV
	elif $SYNOSERVICECFG_BIN --list|grep -q "^${_srv}"; then
		_type=$SERV_TYPE_SYNO_SERVICE
	else
		return $LSB_STAT_UNKNOWN
	fi
	_target=""

	GetServiceStatus "$_type" "$_srv" "$_file"
	_ret=$?
	if [ "$LSB_STAT_RUNNING" == "$_ret" -o "$LSB_STAT_NOT_RUNNING" == "$_ret" ]; then
		return $_ret
	fi
	sleep 5
	# check again if failed status is caused by other people
	GetServiceStatus "$_type" "$_srv" "$_file"
	_ret=$?
	if [ "$LSB_STAT_RUNNING" == "$_ret" -o "$LSB_STAT_NOT_RUNNING" == "$_ret" ]; then
		return $_ret
	fi
	skip=`$SYNOAHA_BIN --is-service-should-skip-restart $_srv`
	if [ -n "$skip" ]; then
		return $LSB_ERR_GENERIC
	fi
#	synoha_log "serv check $_srv $_file $_target err, restart."
	RCMsg "Restart $_file ..."
	RestartService "$_type" "$_srv" "$_file"
	_ret=$?
	if [ "$LSB_SUCCESS" != "$_ret" -a "$LSB_NOT_RUNNING" != "$_ret" ]; then
#		synoha_log "failed to restart serv $_srv $_file $_target.(sh start, retcode=$_ret)"
		return $_ret
	fi
	GetServiceStatus "$_type" "$_srv" "$_file"
	_ret=$?
	if [ "$LSB_STAT_RUNNING" != "$_ret" -a "$LSB_STAT_NOT_RUNNING" != "$_ret" ]; then
#		synoha_log "serv check $_srv $_file $_target err after restart.(sh status, retcode=$_ret)"
		return $LSB_ERR_GENERIC
	fi
	return $LSB_SUCCESS
}

# new format: samba,builtin=yes
# old format: samba,builtin
ServiceStatusHA() {
	local _srv=
	local _target=
	local _ret=
	local _idx=0
	local _status_list=
	local _old_status=""

	local _srv_list=`$SYNOAHASTR_BIN --service-name-list`
	local _running=`$SYNOAHASTR_BIN --service-running`
	local _stopped=`$SYNOAHASTR_BIN --service-stopped`
	local _error=`$SYNOAHASTR_BIN --service-error`
	local _skip=`$SYNOAHASTR_BIN --service-skip`

	while [ 1 ]
	do
		_idx=0
		for _srv in $_srv_list
		do
			if [ -z $_srv ]; then
				break;
			fi
			CheckServiceStatusReady $_srv
			if [ "$?" == "1" ]; then
				if [ 0 = $_idx ]; then
					_status_list="$_running"
				else
					_status_list="$_status_list,$_running"
				fi
			else
				CheckStatus $_srv
				_ret=$?

				if [ $_ret = $LSB_STAT_RUNNING ]; then
					if [ 0 = $_idx ]; then
						_status_list="$_running"
					else
						_status_list="$_status_list,$_running"
					fi
				elif [ $_ret = $LSB_STAT_NOT_RUNNING ]; then
					if [ 0 = $_idx ]; then
						_status_list="$_stopped"
					else
						_status_list="$_status_list,$_stopped"
					fi
				else
					if [ 0 = $_idx ]; then
						_status_list="$_error"
					else
						_status_list="$_status_list,$_error"
					fi
				fi
			fi

			_idx=$(($_idx+1))
			sleep 1
		done
		if [ "$_status_list" != "$_old_status" ]; then
			$SYNOAHA_BIN --service-changed $_status_list
			_ret=$?
			if [ $_ret -eq 0 ]; then
				_old_status=$_status_list
			fi
		fi
		sleep $SERV_MONITOR_INTERVAL
	done
}

date > $SYNO_AHA_STATUS_CHECK_LOG
echo "ServiceStatusHA start." >> $SYNO_AHA_STATUS_CHECK_LOG
echo $$ > `$SYNOAHASTR_BIN --service-monitor-pid-path`
ServiceStatusHA

