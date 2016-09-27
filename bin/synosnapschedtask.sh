#!/bin/sh
# Copyright (c) 2015-2015 Synology Inc. All rights reserved.

BIN_NAME=synosnapschedtask.sh

MKDIR=/bin/mkdir

SYNODR_PKG_ROOT=/var/packages/SnapshotReplication
SYNODR_PKG_ROOT_TARGET=${SYNODR_PKG_ROOT}/target
SYNODR_PKG_ROOT_ETC=${SYNODR_PKG_ROOT}/etc
SYNODR_PKG_SBIN=${SYNODR_PKG_ROOT_TARGET}/sbin

SYNODR_PKG_SYNODR=${SYNODR_PKG_SBIN}/synodr
SYNODR_PKG_SYNODRTOOL=${SYNODR_PKG_SBIN}/synodrtool
SYNODR_PKG_SYNOSNAPSCHEDTOOL=${SYNODR_PKG_SBIN}/synodrsnapschedtool

SYNODR_PKG_STOPPING_FLAG=${SYNODR_PKG_ETC}/stopping

SYNOSDR_SYNODR_SBIN=${SYNODR_PKG_ROOT_TARGET}/sbin
SYNOSDR_SYNODR=${SYNOSDR_SYNODR_SBIN}/synodr
SYNOSDR_SYNODRTOOL=${SYNOSDR_SYNODR_SBIN}/synodrtool
SYNOSDR_SYNOSNAPSCHEDTOOL=${SYNOSDR_SYNODR_SBIN}/synodrsnapschedtool

SYNO_BIN=/usr/syno/bin
SYNOISCSIWEBAPI=${SYNO_BIN}/synoiscsiwebapi

SYNO_SBIN=/usr/syno/sbin
SYNOSHARESNAPSHOT=${SYNO_SBIN}/synosharesnapshot
SYNOVOLUMESNAPSHOT=${SYNO_SBIN}/synovolumesnapshot

DR_SUPPORT_KEYS="support_btrfs support_share_snapshot support_share_quota support_share_user_quota support_dr_snap support_dr_replica"

LOCK_DIR=/tmp/synosnapschedtask
$MKDIR -p "$LOCK_DIR"

FAIL_LOG=${LOCK_DIR}/fail.log
echo > ${FAIL_LOG}

TASK_LOCK_NAME=""
TARGET_LOCK_NAME=""

START_SEC=$(date +%s)

notify_and_log()
{
	$SYNOSNAPSCHEDTOOL notify_task_too_dense "$SCHEDULE_TYPE" "$TARGET_TYPE" "$TARGET_ID"
}

lun_get_res()
{
	SYNOISCSIWEBAPI_LUN_GET_RES=$($SYNOISCSIWEBAPI node#1 lun get "$TARGET_ID" all | grep "\[.\]")
	if [ $(echo "$SYNOISCSIWEBAPI_LUN_GET_RES" | cut -d " " -f 1) == "[O]" ]; then
		ISCSI_TARGET_LOCKED=$(echo "$SYNOISCSIWEBAPI_LUN_GET_RES" | grep -o "is_action_locked: \w\+" | cut -d " " -f 2)
	else
		echo $(date) "synoiscsiwebapi lun get res failed:" "$SYNOISCSIWEBAPI_LUN_GET_RES" >> ${TARGET_LOCK_NAME}
		exit 52
	fi
}

try_take()
{
	touch "$TASK_LOCK_NAME"
	# take snapshot is a target operation
	if $SYNODRTOOL is_recovery_target "$TARGET_TYPE" "$TARGET_ID"; then
		return
	fi

	echo "try take $SCHEDULE_TYPE"

	# Check if I need to take a snapshot by verify if anyone take a
	# schedule snapshot in 3 minutes.
	LAST_SEC=$(grep last_take ${TARGET_LOCK_NAME} | cut -d " " -f 2-)
	if [ -z "$LAST_SEC" ]; then
		LAST_SEC=0
	fi
	# TODO wait until the previous take is done.
	SEC_DIFF=$(expr $START_SEC - $LAST_SEC)
	if [ "$SEC_DIFF" -lt 60 ]; then
		SNAPSHOT_NAME=$(grep snap_name ${TARGET_LOCK_NAME} | cut -d " " -f 2-)
		return
	fi

	HOSTNAME=$(hostname)
	SNAP_DESCRIPTION=$(printf "Scheduled snapshot taken by [%s]" "$HOSTNAME")
	echo "last_take" `date +%s` > ${TARGET_LOCK_NAME}
	case $TARGET_TYPE in
		"volume")
			SNAPSHOT_NAME=$(env "USERNAME=admin" $SYNOVOLUMESNAPSHOT --sched_task_run "$TARGET_ID" "$SNAP_DESCRIPTION")
			if [ $? -ne 0 ]; then
				echo $(date) "synovolumesnapshot failed:" $? >> ${TARGET_LOCK_NAME}
				return
			fi
			SNAPSHOT_SIZE=$($SYNOVOLUMESNAPSHOT --get_snapshot_size "$TARGET_ID" "$SNAPSHOT_NAME")
			echo $SNAPSHOT_NAME taken
			;;
		"share")
			SNAPSHOT_NAME=$(env "USERNAME=admin" $SYNOSHARESNAPSHOT sched task_run "$TARGET_ID" "$SNAP_DESCRIPTION")
			if [ $? -ne 0 ]; then
				echo $(date) "synosharesnapshot failed:" $? >> ${TARGET_LOCK_NAME}
				return
			fi
			SNAPSHOT_SIZE=$($SYNOSHARESNAPSHOT snapsize "$TARGET_ID" "$SNAPSHOT_NAME")
			echo $SNAPSHOT_NAME taken
			;;
		"lun")
			LUN_APP_AWARE=$($SYNODRTOOL lun_get_app_aware "$TARGET_ID")
			if [ $? -lt 0 ]; then
				echo $(date) "Get lun appaware failed:" $? >> ${TARGET_LOCK_NAME}
				return
			fi
			echo app "$LUN_APP_AWARE" >> ${TARGET_LOCK_NAME}
			SYNOISCSIWEBAPI_RES=$($SYNOISCSIWEBAPI node#1 lun take_snapshot "$TARGET_ID" "$LUN_APP_AWARE" false "" "$SNAP_DESCRIPTION" scheduler 0 true)
			if [ $? -ne 0 ]; then
				echo $(date) "synpiscsiwebapi failed:" $? >> ${TARGET_LOCK_NAME}
				return
			fi
			SNAPSHOT_RES=$(echo "$SYNOISCSIWEBAPI_RES" | grep "\[.\]")
			if [ $(echo "$SNAPSHOT_RES" | cut -d " " -f 1) == "[O]" ]; then
				SNAPSHOT_NAME=$(echo "$SNAPSHOT_RES" | cut -d " " -f 3)
				echo $SNAPSHOT_NAME taken
			else
				echo $(date) "synoiscsiwebapi res failed:" "$SNAPSHOT_RES" >> ${TARGET_LOCK_NAME}
				return
			fi

			# Taking snapshot is finished if lun is not locked.
			lun_get_res
			while [ "true" == "$ISCSI_TARGET_LOCKED" ]; do
				echo $(date) "LUN is taking snapshot..." >> ${TARGET_LOCK_NAME}
				sleep 1
				lun_get_res
			done
			SNAPSHOT_SIZE=$($SYNOISCSIWEBAPI node#1 lun gs "$SNAPSHOT_NAME" | /bin/sed 's/,/\n/g' | grep mapped_size | cut -d ' ' -f 2)
			;;
		*)
			echo "Invalid target type [${TARGET_TYPE}]."
			exit 1
			;;
	esac
	if [ "$SCHEDULE_TYPE" = "systemdr" ]; then
		/bin/rm -f ${SNAP_NAME_FILE}
		/usr/syno/bin/synosetkeyvalue ${SNAP_NAME_FILE} "name" ${SNAPSHOT_NAME}
		/usr/syno/bin/synosetkeyvalue ${SNAP_NAME_FILE} "size" ${SNAPSHOT_SIZE}
	fi
	echo "snap_name ${SNAPSHOT_NAME}" >> ${TARGET_LOCK_NAME}
	echo "finished" >> ${TARGET_LOCK_NAME}
}

try_pre_send()
{
	echo $(date) "try_pre_send func start" >> "$TASK_LOCK_NAME"
	echo "try pre-send $PLAN_ID" >> "$TASK_LOCK_NAME"
	echo $(date) "pre-pending snapshots: " $($SYNODR plan list_pending_snaps "$PLAN_ID") >> ${TASK_LOCK_NAME}
	echo $(date) "pre-sending" >> ${TASK_LOCK_NAME}
	# This would not failed if no snapshot is sent since the list does not
	# contain scheduled snapshot.

	if [ 0 -lt "$($SYNODR plan list_pending_snaps "$PLAN_ID" | head -n 1 | cut -d ":" -f 2)" ]; then
		$SYNODR plan send_pending_snaps "$PLAN_ID" false
	fi
	echo $(date) "pre-send finished" >> ${TASK_LOCK_NAME}
}

add_pending_snap()
{
	echo $(date) "add_pending_snap func start" >> "$TASK_LOCK_NAME"
	# Sending snapshots is not a target operation so we don't touch target
	# lock here.

	if $SYNODRTOOL is_origin_target "$TARGET_TYPE" "$TARGET_ID"; then
		if [ -n "$SNAPSHOT_NAME" ]; then
			echo $(date) "try add $PLAN_ID $SNAPSHOT_NAME" >> "$TASK_LOCK_NAME"
			if ! $SYNODR plan add_pending_snap_by_name "$PLAN_ID" "$SNAPSHOT_NAME"; then
				echo $(date) "Failed to add pending snapshot by name" >> "$TASK_LOCK_NAME"
				exit 60
			fi
		else
			echo $(date) "No snapshot name provided" >> "$TASK_LOCK_NAME"
			return
		fi
	elif $SYNODRTOOL is_recovery_target "$TARGET_TYPE" "$TARGET_ID"; then
		echo $(date) "try add $PLAN_ID time $START_SEC" >> "$TASK_LOCK_NAME"
		if ! $SYNODR plan add_pending_snap_by_time "$PLAN_ID" "$START_SEC"; then
			echo $(date) "Failed to add pending snapshot by time" >> "$TASK_LOCK_NAME"
			exit 61
		fi
	fi
}

try_send()
{
	add_pending_snap

	echo "try send $PLAN_ID"

	# This would failed if another process is sending for the same plan (lock)
	# or there is no snapshot to send.
	echo $(date) "pending snapshots: " $($SYNODR plan list_pending_snaps "$PLAN_ID") >> "$TASK_LOCK_NAME"
	echo $(date) "sending" >> "$TASK_LOCK_NAME"
	if ! $SYNODR plan send_pending_snaps "$PLAN_ID" true >> "$TASK_LOCK_NAME" ; then
		echo $(date) "Failed to send pending snapshot" >> "$TASK_LOCK_NAME"
		exit 63
	fi
	echo $(date) "send finished" >> "$TASK_LOCK_NAME"
}

local_task()
{
	echo $(date) "local task start" >> "$TASK_LOCK_NAME"
	{
		if flock 3; then
			try_take
		fi
	} 3>>"$TARGET_LOCK_NAME"
}

replication_task()
{
	echo $(date) "replication task start" >> "$TASK_LOCK_NAME"

	TAKEN=""

	# Send first if there is another task taking snapshot.
	{
		if flock -n 3; then
			try_take
			TAKEN="Y"
		else
			try_pre_send
		fi
	} 3>>"$TARGET_LOCK_NAME"

	if [ -z "$TAKEN" ]; then
		{
			if flock 3; then
				try_take
			fi
		} 3>>"$TARGET_LOCK_NAME"
	else
		try_pre_send
	fi

	try_send
}

gen_infos()
{
	case $SCHEDULE_TYPE in
		"local")
			SYNODR=${SYNODR_PKG_SYNODR}
			SYNODRTOOL=${SYNODR_PKG_SYNODRTOOL}
			SYNOSNAPSCHEDTOOL=${SYNODR_PKG_SYNOSNAPSCHEDTOOL}
			TARGET_TYPE=$1
			TARGET_ID=$2
			;;
		"replication")
			PLAN_ID=$1
			SYNODR=${SYNODR_PKG_SYNODR}
			SYNODRTOOL=${SYNODR_PKG_SYNODRTOOL}
			SYNOSNAPSCHEDTOOL=${SYNODR_PKG_SYNOSNAPSCHEDTOOL}
			TARGET_TYPE=$($SYNOSNAPSCHEDTOOL replication_target_type "$PLAN_ID")
			TARGET_ID=$($SYNOSNAPSCHEDTOOL replication_target_id "$PLAN_ID")
			;;
		"systemdr")
			PLAN_ID=$1
			SYNODR=${SYNOSDR_SYNODR}
			SYNODRTOOL=${SYNOSDR_SYNODRTOOL}
			SYNOSNAPSCHEDTOOL=${SYNOSDR_SYNOSNAPSCHEDTOOL}
			TARGET_TYPE=$($SYNOSNAPSCHEDTOOL replication_target_type "$PLAN_ID")
			TARGET_ID=$($SYNOSNAPSCHEDTOOL replication_target_id "$PLAN_ID")
			SNAP_NAME_FILE=$2
			;;
		"systemdr_local_task")
			PLAN_ID=$1
			SYNODR=${SYNOSDR_SYNODR}
			SYNODRTOOL=${SYNOSDR_SYNODRTOOL}
			SYNOSNAPSCHEDTOOL=${SYNOSDR_SYNOSNAPSCHEDTOOL}
			TARGET_TYPE=$($SYNOSNAPSCHEDTOOL replication_target_type "$PLAN_ID")
			TARGET_ID=$($SYNOSNAPSCHEDTOOL replication_target_id "$PLAN_ID")
			;;
		*)
			usage
			exit 1
			;;
	esac

	if [ -z "$TARGET_TYPE" ]; then
		echo $(date) "Not a valid target type" >> "$FAIL_LOG"
		exit 4
	fi
	if [ -z "$TARGET_ID" ]; then
		echo $(date) "Not a valid target id" >> "$FAIL_LOG"
		exit 5
	fi

	LOCK_TARGET_DIR="${LOCK_DIR}/${TARGET_TYPE}"
	$MKDIR -p "$LOCK_TARGET_DIR"

	if [ -n "$PLAN_ID" ]; then
		TASK_LOCK_NAME="${LOCK_TARGET_DIR}/${SCHEDULE_TYPE}.${PLAN_ID}.task"
	else
		TASK_LOCK_NAME="${LOCK_TARGET_DIR}/${SCHEDULE_TYPE}.${TARGET_ID}.task"
	fi
	TARGET_LOCK_NAME="${LOCK_TARGET_DIR}/${TARGET_ID}"
	TARGET_TIME_LOCK_NAME="${TARGET_LOCK_NAME}.time"
}

tool_check()
{
	for BIN in ${SYNODR} ${SYNODRTOOL} ${SYNOSNAPSCHEDTOOL}; do
		if [ ! -f ${BIN} ]; then
			echo $(date) "Require binary ${BIN} does not exist." >> "$TASK_LOCK_NAME"
			exit 70
		fi
	done

}

support_check()
{
	support_dr_check
}

support_dr_check()
{
	for SUPPORT_KEY in ${DR_SUPPORT_KEYS}; do
		if [ "yes" != "$(get_key_value /etc.defaults/synoinfo.conf "${SUPPORT_KEY}")" ]; then
			echo "This machine does not support the required key [${SUPPORT_KEY}]." >> $FAIL_LOG
			exit 71
		fi
	done
}

usage()
{
	echo "Copyright (c) 2015-2015 Synology Inc. All rights reserved."
	echo ""
	echo "Usage:"
	echo "       $BIN_NAME local [lun|share] <lun id|share name>"
	echo "       $BIN_NAME replication <replication_id>"
}

if [ -f "$SYNODR_PKG_STOPPING_FLAG" ]; then
	echo Package is stopping >> $FAIL_LOG
	exit 0
fi

SCHEDULE_TYPE=$1
shift
gen_infos "$@"


# We must check if there is previous task on same target (may not be the same
# task) by exclusive file lock on TARGET_LOCK_NAME.
{
	if flock 3; then
		{
			if ! flock -n 4; then
				TARGET_LAST_SEC=$(date -r "$TARGET_TIME_LOCK_NAME" +%s)
				TARGET_SEC_DIFF=$(expr $START_SEC - $TARGET_LAST_SEC)
				if [ "$TARGET_SEC_DIFF" -gt 60 ]; then
					echo previous target $START_SEC $TARGET_LAST_SEC >> $FAIL_LOG
					notify_and_log
					exit 2
				fi
			else
				touch "$TARGET_TIME_LOCK_NAME"
			fi
		} 4>>"$TARGET_LOCK_NAME"
	fi
} 3>>"$TARGET_TIME_LOCK_NAME"

# We must check if there is previous task by exclusive file lock on
# TASK_LOCK_NAME.
{
	echo $(date) "Task init" > "$TASK_LOCK_NAME"
	if flock -n 3; then
		case $SCHEDULE_TYPE in
			"local")
				tool_check
				support_check
				local_task
				;;
			"replication")
				tool_check
				support_check
				replication_task
				;;
			"systemdr")
				tool_check
				replication_task
				;;
			"systemdr_local_task")
				tool_check
				local_task
				add_pending_snap
				;;
			*)
				usage
				exit 1
				;;
		esac
	else
		notify_and_log
		exit 3
	fi
} 3>>"$TASK_LOCK_NAME"

