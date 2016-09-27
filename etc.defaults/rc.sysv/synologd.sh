#!/bin/sh

SYNOLOGD="/usr/syno/bin/synologd"
PID_FILE="/var/run/synologd.pid"
PGUPGRADE_FLAG="/tmp/.UpgradePGSQLDatabase"

get_pid()
{
	if [ ! -f ${PID_FILE} ]; then
		echo "${PID_FILE} not found. Not running?"
		return 1
	else
		pid=`cat ${PID_FILE} 2>/dev/null`
		if [ -f /proc/$pid/cmdline ]; then
			echo $pid
			return 0
		else
			rm -f ${PID_FILE}
			echo "${PID_FILE} is found, but not running?"
			return 1
		fi
	fi
}

FuncCheckDB()
{
	if [ -e $PGUPGRADE_FLAG ] || ! pidof postgres; then
		echo "PGSQL is not available"
		exit 1;
	fi

	echo "Checking synolog database existence..."
	su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM ftpxfer LIMIT 1\" > /dev/null"
	Ret=$?
	if [ $Ret = 2 ]; then
		echo "Creating synolog database..."
		su postgres -c "/usr/bin/createdb synolog"
		if [ $? != 0 ]; then
			echo "Failed to create database"
			exit 1
		fi
		Ret=1
	fi

	if [ $Ret = 1 ]; then
		echo "Creating synolog tables..."
		su postgres -c "/usr/bin/psql synolog -f /usr/syno/synologd/sql/synolog.pgsql"
		if [ $? != 0 ]; then
			echo "Failed to create tables in synolog database"
			exit 1
		fi
	elif [ $Ret = 0 ]; then
	    upgrades=`find /usr/syno/synologd/sql/upgrade -name "*.sh" | sort`
	    for ThisArg in $upgrades;
	    do
		    $ThisArg
	    done
	else
		echo "Unknown error"
		exit 1
	fi

	return 0
}

FuncDropWebfmTable()
{
	echo "Drop TABLE webfmxfer ..."
	su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM webfmxfer LIMIT 1\" > /dev/null"
	if [ $? = 0 ]; then
		su postgres -c "/usr/bin/psql synolog -c \"INSERT INTO dsmfmxfer SELECT * FROM webfmxfer\" > /dev/null"
		if [ $? != 0 ]; then
			echo "Fail to SELECT * INTO dsmfmxfer FROM webfmxfer"
		fi
		su postgres -c "/usr/bin/psql synolog -c \"DROP TABLE webfmxfer\" > /dev/null"
		if [ $? != 0 ]; then
			echo "Failed to DROP TABLE webfmxfer"
		fi
	fi
}

FuncCheckIfNeedRun()
{
	echo "Checking if need to run synologd..."
	/usr/syno/sbin/synoservice --is-enabled ftpd
	RunFTP=$?
	/usr/syno/sbin/synoservice --is-enabled ftpd-ssl
	RunFTPS=$?
	/usr/syno/sbin/synoservice --is-enabled sftp
	RunSFTP=$?
	/usr/syno/sbin/synoservice --is-enabled tftp
	RunTFTP=$?
	LogFTP=`/bin/get_key_value /etc/synoinfo.conf ftpxferlog`
    LogTFTP=`/bin/get_key_value /etc/synoinfo.conf tftpxferlog`
	LogDSMFM=`/bin/get_key_value /etc/synoinfo.conf filebrowserxferlog`
	RunWEBDAV=`/bin/get_key_value /var/packages/WebDAVServer/target/etc/webdav.cfg enable_http`
	RunWEBDAVS=`/bin/get_key_value /var/packages/WebDAVServer/target/etc/webdav.cfg enable_https`
	LogWEBDAV=`/bin/get_key_value /etc/synoinfo.conf webdavxferlog`
	/usr/syno/sbin/synoservice --is-enabled samba
	RunSMB=$?
	LogSMB=`/bin/get_key_value /etc/synoinfo.conf smbxferlog`
	/usr/syno/sbin/synoservice --is-enabled atalk 
	RunAFP=$?
	LogAFP=`/bin/get_key_value /etc/synoinfo.conf afpxferlog`

	if [  "$RunFTP" -eq 1 -o "$RunFTPS" -eq 1 -o "$RunSFTP" -eq 1 ] && [ "yes" = "$LogFTP" ]; then
	    return 0
	elif [ "$RunTFTP" -eq 1 ] && [ "yes" = "$LogTFTP" ]; then
	    return 0
	elif [ "yes" = "$LogDSMFM" ]; then
	    return 0
	elif [ "$RunSMB" -eq 1 ] && [ "yes" = "$LogSMB" ]; then
	    return 0
	elif [ "$RunAFP" -eq 1 ] && [ "yes" = "$LogAFP" ]; then
	    return 0
	elif [ "yes" == "$RunWEBDAV" -o "yes" == "$RunWEBDAVS" ] && [ "yes" = "$LogWEBDAV" ]; then
	    return 0
	fi 
	echo "No need to start synologd..."
	return 1
}

case $1 in
check_if_need_run)
	FuncCheckIfNeedRun
	exit $?
	;;
check_db)
	FuncCheckDB
	exit $?
	;;
drop_webfm_table)
	FuncDropWebfmTable
	exit 0
	;;
*)
	echo "Usage: $0 [check_if_need_run|check_db|drop_webfm_table]"
	exit 0
	;;
esac

