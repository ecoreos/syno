#!/bin/sh

_PGDATA=/var/services/pgsql
PGDATA="`/usr/bin/readlink ${_PGDATA}`"
PGDIRNAME="`/usr/bin/dirname ${PGDATA}`"
PGDATA32="${PGDIRNAME}/pgsql.32bit.`/bin/date +%s`"
PGDATA64="${PGDIRNAME}/pgsql.64bit.`/bin/date +%s`"
PGMAJORVERSION=9.3
UsbStation=`/bin/get_key_value /etc.defaults/synoinfo.conf usbstation`
UnixPerm="no"
PGPIDFILE="/var/run/postgresql/postmaster.pid"
PGUPGRADE_FLAG="/tmp/.UpgradePGSQLDatabase"
ERR_MESSAGE="Failed to upgrade PostgreSQL, please contact Synology for support."
ret=0
BOOL_INIT_DB=false

EchoDate()
{
	echo "[`/bin/date '+%Y-%m-%d %H:%M:%S %Z'`]: $1"
}

ChkPGSQLShare()
{
	/usr/syno/bin/servicetool --get-service-path pgsql >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		EchoDate "No volume to start PostgreSQL."
		return 1
	fi
	return 0
}

ChkExecEnv()
{
	if ! ChkPGSQLShare; then
		exit 1
	fi

	if [ ! -f /etc/postgresql/postgresql.conf ]; then
		/bin/cp -a /etc.defaults/postgresql /etc
	fi

	/bin/mkdir -p /run/postgresql
	/bin/chown -R postgres: /etc/postgresql /run/postgresql
	/bin/chmod 700 /etc/postgresql
	if [ "yes" = "${UsbStation}" ]; then
		/bin/cp -f /etc/postgresql/postgresql.conf ${PGDATA}/postgresql.conf

		PgsqlVolume=`/usr/syno/bin/servicetool --get-service-volume pgsql`
		VolFsType=`/usr/syno/bin/synofstool --get-fs-type ${PgsqlVolume}`
		if [ "ext3" = "${VolFsType}" -o "ext4" = "${VolFsType}" -o "hfsplus" = "${VolFsType}" ]; then
			UnixPerm="yes"

			/bin/chown -R postgres: ${PGDATA}
			/bin/chmod 700 ${PGDATA}
			/usr/bin/find ${PGDATA}/ -type d ! -perm 700 -exec chmod 700 {} \;
			/usr/bin/find ${PGDATA}/ -type f ! -perm 600 -exec chmod 600 {} \;
		fi
	else
		/bin/chown -R postgres: ${PGDATA}
		/bin/chmod 700 ${PGDATA}
		/usr/bin/find ${PGDATA}/ -type d ! -perm 700 -exec chmod 700 {} \;
		/usr/bin/find ${PGDATA}/ -type f ! -perm 600 -exec chmod 600 {} \;

		if [ ! -L ${PGDATA}/postgresql.conf ]; then
			/bin/ln -sf /etc/postgresql/postgresql.conf ${PGDATA}/postgresql.conf
		fi
	fi
}

ChkCompat()
{
	/usr/bin/pg_controldata --check-compatibility ${PGDATA} 2>/dev/null
	if [ $? -ne 0 ]; then
		EchoDate "Compatibility check is failed. Please check /var/log/postgresql.log for further information."
		/bin/mv -f ${PGDATA} "${PGDIRNAME}/.pgsql.`/bin/date +%s`"
		InitDB
	fi
}

CleanPID()
{
	if [ -f ${PGDATA}/postmaster.pid ]; then
		EchoDate "Find postmaster.pid file"
		EchoDate "-------start postmaster.pid-----"
		/bin/cat ${PGDATA}/postmaster.pid
		EchoDate "-------end postmaster.pid-------"
		/bin/rm -f ${PGDATA}/postmaster.pid
	fi
}

InitDB()
{
	local enable_checksum=""
	local no_fsync=""

	if [ "x`/bin/get_key_value /etc.defaults/synoinfo.conf support_postgresql_data_checksums`" == "xyes" ]; then
		enable_checksum="--data-checksums"
	fi

	if [ ! -d ${PGDATA}/base ]; then
		EchoDate "Initialize PostgreSQL database"

		/bin/mkdir -p ${PGDATA}
		if [ "yes" = "${UsbStation}" ]; then
			/bin/tar zxf /usr/share/postgresql//pgsql.tgz -C ${PGDATA}
			/bin/cp -f /etc/postgresql/postgresql.conf ${PGDATA}/postgresql.conf

			if [ "yes" = "${UnixPerm}" ]; then
				/bin/chown -R postgres: ${PGDATA}
				/bin/chmod 700 /etc/postgresql ${PGDATA}
				/bin/chmod 777 ${PGDATA}/postgresql.conf
			fi
		else
			if [ "x`/usr/syno/bin/synofstool --get-fs-type ${PGDATA}`" == "xbtrfs" ]; then
				EchoDate "${PGDATA} is btrfs"
				no_fsync="--nosync"
			fi

			/bin/chown -R postgres: ${PGDATA}
			/bin/chmod 700 /etc/postgresql ${PGDATA}
			/bin/su postgres -c "/usr/bin/initdb --locale=POSIX --pgdata=${PGDATA} ${enable_checksum} ${no_fsync}" >/dev/null 2>&1
			/bin/ln -sf /etc/postgresql/postgresql.conf ${PGDATA}/postgresql.conf
		fi
		/bin/sync; /bin/sync; /bin/sync

		touch ${PGINIT_FLAG}
		BOOL_INIT_DB=true
	fi
}

ChkNeedDump()
{
	if [ -f /var/.UpgradeBootup -a -f /usr/bin/pg_controldata32 ]; then
		/usr/bin/pg_controldata --check-compatibility ${PGDATA} 2>/dev/null
		if [ $? -ne 0 ]; then
			/usr/bin/pg_controldata32 --check-compatibility ${PGDATA} 2>/dev/null
			if [ $? -eq 0 ]; then
				return 0;
			fi
		fi
	fi
	return 1
}

DumpDB()
{
	if [ -f ${PGDATA}/pgsql-32bit.sql ]; then
		return 0;
	fi
	CleanPID
	start pgsql32
	sec=1
	while [ ${sec} -le 600 ]
	do
		if pidof postgres32; then
			/bin/su postgres -c "/usr/bin/pg_isready" > /dev/null 2>&1
			ret=$?
			# pg_isready retern value: PQPING_OK (1), PQPING_REJECT (2), PQPING_NO_RESPONSE(3), PQPING_NO_ATTEMPT(4)
			if [ ${sec} -ge 180 -a ${ret} -ge 2 ]; then
				/usr/bin/logger -p user.err $ERR_MESSAGE
				stop pgsql32
				return 1
			fi
			if [ ${ret} -eq 0 ]; then
				EchoDate "postgres32 is ready after waiting ${sec} seconds..."
				break
			fi
		elif [ ${sec} -ge 30 ]; then
			EchoDate "postgres32 process start up failed."
			/usr/bin/logger -p user.err $ERR_MESSAGE
			stop pgsql32
			return 1
			break
		fi
		sec=`expr ${sec} + 1`
		sleep 1
	done
	EchoDate "dump postgres32 database."
	/bin/su postgres -c "/usr/bin/pg_dumpall --disable-triggers -f ${PGDATA}/pgsql-32bit.sql > ${PGDATA}/pg_upgrade_dump.log 2>&1"
	if [ $? -ne 0 ]; then
		EchoDate "dump postgres32 database failed."
		/usr/bin/logger -p user.err $ERR_MESSAGE
		return 1
	fi
	stop pgsql32
	return 0
}

UpdatePGSQLWorker()
{
	local i=""
	local pkg=""

	for i in /var/packages/*/conf/resource; do
		[ -f "$i" ] || continue
		if [ "$(jq '.["pgsql-db"]' "$i")" != "null" ]; then
			pkg=`basename "$(dirname "$(dirname "$i")")"`
			echo "Update ${pkg} pgsql-db worker."
			synopkghelper update "$pkg" pgsql-db
			echo "Done updating ${pkg} pgsql-db worker."
		fi
	done
}

case $1 in
	start)
		if ! pidof postgres ; then
			EchoDate "Start PostgreSQL"
			ChkExecEnv
			if ChkNeedDump; then
				# need upgrade database
				echo start > $PGUPGRADE_FLAG
				if ! DumpDB; then
					rm $PGUPGRADE_FLAG
				fi
				/bin/mv ${PGDATA} ${PGDATA32}
				InitDB
			fi
			ChkCompat
			CleanPID
			start pgsql

			sec=1
			while [ ${sec} -le 1800 ]
			do
				PG_PID=`status pgsql | awk '{ print $4 }'`
				if [ ! -z "${PG_PID}" ]; then
					/bin/su postgres -c "/usr/bin/pg_isready" > /dev/null 2>&1
					ret=$?
					# pg_isready retern value: PQPING_OK (1), PQPING_REJECT (2), PQPING_NO_RESPONSE(3), PQPING_NO_ATTEMPT(4)
					if [ ${sec} -ge 180 -a ${ret} -ge 2 ]; then
						EchoDate "pg_isready remain 'no response' for 180 seconds.."
						break
					fi
					if [ ${ret} -eq 0 ]; then
						EchoDate "pgsql is ready after waiting ${sec} seconds..."
						break
					fi
				else
					if /usr/bin/tail -6 /var/log/postgresql.log | /bin/grep "${PG_PID}" | /bin/grep "could not load pg_hba.conf"; then
						EchoDate "pg_hba.conf is recovered"
						/bin/cp /etc.defaults/postgresql/pg_hba.conf /etc/postgresql/pg_hba.conf
						start pgsql
					elif /usr/bin/tail -6 /var/log/postgresql.log | /bin/grep "${PG_PID}" | /bin/grep "USE_FLOAT8_BYVAL"; then
						EchoDate "USE_FLOAT8_BYVAL incompatable due to migrate."
						if [ -f /usr/bin/pg_controldata32 ]; then
							echo start > $PGUPGRADE_FLAG
							if ! DumpDB; then
								rm $PGUPGRADE_FLAG
							fi
							/bin/mv -f ${PGDATA} ${PGDATA32}
							InitDB
						else
							/bin/mv -f ${PGDATA} ${PGDATA64}
							InitDB
						fi
						start pgsql
					else
						EchoDate "postgrest process start up failed."
						break
					fi
				fi
				sec=`expr ${sec} + 1`
				sleep 1
			done

			if [ ${ret} -ne 0 ]; then
				EchoDate "Failed to start PostgreSQL. Please check /var/log/postgresql.log"
				if /bin/tail /var/log/upstart/pgsql.log -n 6 | /bin/grep "No space left on device"; then
					/usr/syno/bin/synodsmnotify @administrators dsmnotify:system_event widget:pgsql_startup_failed
					/usr/bin/logger -p user.err -t `basename $0` "no space left on device for starting PostgreSQL."
				fi
				exit 1
			else
				if [ -f ${PGUPGRADE_FLAG} -a -f ${PGDATA32}/pgsql-32bit.sql ]; then
					EchoDate "Start restore pgsql data"
					/bin/su postgres -c "/usr/bin/psql < ${PGDATA32}/pgsql-32bit.sql > ${PGDATA32}/pg_upgrade_restore.log 2>&1"
					if [ "`cat $PGUPGRADE_FLAG`" = "timeout" ]; then
						/usr/bin/logger -p user.err -t `basename $0` "pgsql upgrade has been done but exceed 600 second."
						/usr/syno/bin/synodsmnotify @administrators dsmnotify:system_event widget:pgsql_upgrade_done
					fi
					rm $PGUPGRADE_FLAG
					EchoDate "Upgrade pgsql data is done."
				fi
			fi

			/usr/syno/bin/mediaserver.sh start

			if $BOOL_INIT_DB; then
				UpdatePGSQLWorker
			fi
		fi
		;;

	stop)
		stop pgsql
		;;

	reload|restart)
		ChkExecEnv
		ChkCompat
		stop pgsql
		start pgsql
		;;

	status)
		if ! ChkPGSQLShare; then
			exit 1
		fi
		/bin/su postgres -c "/usr/bin/pg_ctl -s -D ${_PGDATA} status" || exit 1
		;;

	*)
		echo "usage: `basename $0` {start|stop|restart|reload|status}" >&2
		exit 64
		;;
esac
exit 0
