#!/bin/sh

ETC_DIR="/usr/syno/etc/synobtrfsreplica/"
REPLICA_DB=${ETC_DIR}"/snap_replica.db"
INIT_SQL=${ETC_DIR}"/init_db.sql"
DB_VER="1"

init_db()
{
	if [ ! -f ${INIT_SQL} ]; then
		logger -p user.info -t synobtrfsreplica "Failed to init snap_replica.db since ${INIT_SQL} is not existed"
	else
		sqlite3 ${REPLICA_DB} < ${INIT_SQL}
		logger -p user.info -t synobtrfsreplica "Init synodrnode.db done"
	fi
}

start()
{
	logger -p user.info -t synobtrfsreplica " ---> Start DB Check"

	if [ ! -f "${REPLICA_DB}" ]; then
		init_db
	else
		local existed=`sqlite3 ${REPLICA_DB} "SELECT 1 FROM sqlite_master WHERE type='table' AND name='db_ver';"`

		if [ -z "$existed" ]; then
			init_db
		else
			local ver=`sqlite3 ${REPLICA_DB} "SELECT value FROM db_ver;"`;
			if [ -z "$ver" -o "$DB_VER" != "${ver}" ]; then
				init_db
			fi
		fi

	fi
	logger -p user.info -t synobtrfsreplica " <--- Finish DRNode Check"
	/sbin/initctl emit syno.btrfs.replica.ready
}

migrate_from_beta1()
{
	BETA1_CONFIG="/usr/syno/etc/share_replica/share_replica.db"
	SHARE_REPLICA_BIN="/usr/syno/sbin/synosharereplica"

	if [ -e "${BETA1_CONFIG}" ];then
		if [ -e "${SHARE_REPLICA_BIN}" ];then
			${SHARE_REPLICA_BIN} --replica_updater
			RET=$?
			if [ "${RET}" -eq "0" ]; then
				rm -f "${BETA1_CONFIG}"
				rm -rf /usr/syno/etc/share_replica
			else
				mv "${BETA1_CONFIG}" "${BETA1_CONFIG}.failed"
			fi
		fi
	fi
}

case "$1" in
start)
	start
	migrate_from_beta1
;;
*)
	echo "usage: $0 [start]" >&2
	exit 1
;;
esac
