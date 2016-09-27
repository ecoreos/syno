#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

SYNOPKG=/usr/syno/bin/synopkg

syslog() {
	local ret=$?
	logger -p user.err -t $(basename $0) "$@"
	return $ret
}

resolve_pkgname_from_spk()
{
	echo $1 | sed -n 's,^.*/\([^-]\+\)-.*$,\1,p'
}

send_notification()
{
	local app="SYNO.SDS.PkgManApp.Instance"
	local send_to="@administrators"
	local title="tree:leaf_packagemanage"

	/usr/syno/bin/synodsmnotify -c "$app" -t "true" "$send_to" "$title" "$1" "$2" "" ""
}

is_package_installed()
{
	local packageName=$(resolve_pkgname_from_spk $1)

	if [ -d "/var/packages/$packageName" ]; then
		true
	else
		false
	fi
}

# Is packge $2 built-in package for dsm $1?
#
# PROTO TYPE:
#         is_in_dsm previous_dsm_build_number spk_filename
is_in_dsm()
{
	local packageName=$(resolve_pkgname_from_spk $2)
	local package_list=

	# TimeBackup always in dsm
	if [ "x$packageName" = "xTimeBackup" ]; then
		return 0
	fi

	# Install SnapshotReplication by check there are snapshots and snapshot schedulers if previous dsm before DSM6.0
	if [ "x$packageName" = "xSnapshotReplication" ]; then
		if [ $1 -lt 7140 ]; then
			local CHECK_SNAPREPLICA_REQUIRE_PY="/usr/syno/synodr/sbin/check_snapreplica.py"
			python $CHECK_SNAPREPLICA_REQUIRE_PY
			local chk_ret=$?
			if [ 0 == $chk_ret ]; then
				return 0
			else
				return 1
			fi
		elif is_package_installed $2; then
			return 0
		else
			return 1
		fi
	fi

	# following if-statements should be something like
	#	if [ $1 -lt xxxx ]; then
	#		package="$package_list yyyy"
	#	fi
	# where
	# 	xxxx: max reserved build number in "previous" release
	#	yyyy: packages become builtin or must install/upgrade in "this" release
	if [ $1 -lt 7140 ]; then  # builtin package introduced in 6.0 beta2
		package_list="$package_list HyperBackupVault WebDAVServer LogCenter Git Java7"
		# BackupAndRestore exist in 6.0 beta 1 only
		if [ -d "/var/packages/BackupAndRestore" ]; then
			package_list="$package_list HyperBackup"
		fi
	fi
	if [ $1 -lt 7127 ]; then  # builtin package introduced in 6.0 beta1
		package_list="$package_list PHP5.6 WebStation StorageAnalyzer TextEditor HyperBackup Node.js_v0.10"
	fi

	for i in ${package_list}
	do
		if [ "x$packageName" = "x${i}" ]; then
			return 0
		fi
	done
	return 1
}

install_package() {
	local packageName=$(resolve_pkgname_from_spk $1)
	local ret=
	local is_upgrade=false
	local msg=

	if is_package_installed $1; then
		is_upgrade=true
	fi

	if [ "$packageName" = "TimeBackup" ] || [ "$packageName" = "Git" ]; then
		if ! $is_upgrade; then
				# don't install TimeBackup, upgrade it (see DSM #83853)
			return	# Upgrade Git if installed before (see DSM #88030)
		fi
	elif [ "$packageName" = "SnapshotReplication" ]; then
		:
		# always install and upgrade SnapshotReplication (see Snapshot & Replication #1177).
	else
		if $is_upgrade; then
			return  # don't upgrade packages
		fi
	fi

	# perform package-specific checks here
	case "$packageName" in
		"WebStation")
			local webstationCFG="/usr/syno/etc/synoservice.override/webstation.cfg"
			local needinstall="no"
			if [ "yes" = "$(get_key_value /etc/synoinfo.conf runweb)" ]; then
				needinstall="yes"
			fi
			if [ -s "$webstationCFG" ] && [ "\"yes\"" = "$(/bin/jq .auto_start $webstationCFG 2> /dev/null)" ]; then
				needinstall="yes"
			fi
			/bin/rm -f "$webstationCFG"
			if [ "no" = "$needinstall" ]; then
				return
			fi
			;;
		"Node.js_v0.10")
			# for 6281 platform, we replace Node.js with Node.js-v0.10 if Node.js package has been installed
			if [ ! -d "/var/packages/Node.js" ]; then
				return
			fi
			$SYNOPKG uninstall "Node.js"
			ret=$?
			if [ $ret -ne 0 ]; then
				return $ret
			fi
			;;
		"HyperBackup")
			# for DSM 6.0 beta 1, we replace BackupAndRestore with HyperBackup
			if [ -d "/var/packages/BackupAndRestore" ]; then
				$SYNOPKG uninstall "BackupAndRestore"
				ret=$?
				if [ $ret -ne 0 ]; then
					return $ret
				fi
			fi
			;;
		"HyperBackupVault")
			# for EDS not support img_backupd
			if [ "yes" != "$(get_key_value /etc/synoinfo.conf support_img_backupd)" ]; then
				return
			fi
			;;
		"WebDAVServer")
			local HTTP_RUNKEY_PATH="/usr/syno/etc/synoservice.override/webdav-httpd-pure.cfg"
			local HTTPS_RUNKEY_PATH="/usr/syno/etc/synoservice.override/webdav-httpd-ssl.cfg"
			local needinstall="no"
			if [ -s "$HTTP_RUNKEY_PATH" ] && [ "\"yes\"" = "$(/bin/jq .auto_start $HTTP_RUNKEY_PATH 2> /dev/null)" ]; then
				needinstall="yes"
			fi
			if [ -s "$HTTPS_RUNKEY_PATH" ] && [ "\"yes\"" = "$(/bin/jq .auto_start $HTTPS_RUNKEY_PATH 2> /dev/null)" ]; then
				needinstall="yes"
			fi
			if [ "no" = "$needinstall" ]; then
				return
			fi
			;;
		"LogCenter")
			local SYSLOG_ARCHIVE_CFG="/usr/syno/etc/synoservice.override/syslog-archive.cfg"
			local SYSLOG_BSD_CFG="/usr/syno/etc/synoservice.override/syslog-bsd.cfg"
			local SYSLOG_IETF_CFG="/usr/syno/etc/synoservice.override/syslog-ietf.cfg"
			local SYSLOG_CUSTRULE_CFG="/usr/syno/etc/synoservice.override/syslog-custrule.cfg"
			local SYSLOG_CLIENT_CFG="/usr/syno/etc/synoservice.override/syslog-client.cfg"
			local ENABLE_SERVICE_CONF="/etc/synosyslog/enable_services"
			local DSM_LOGCENTER_SERVER_CONF="/etc/synosyslog/server.conf"
			local SYNO_BIN_SET_KEY_VALUE="/usr/syno/bin/synosetkeyvalue"
			local BIN_RM=/bin/rm
			local needinstall="no"
			local ret=0;

			# following services are advanced feature for Log Center
			# check the synoservice.override and record the runkey in $ENABLE_SERVICE_CONF
			# if $ENABLE_SERVICE_CONF size > 0 or the archiving path is not null, needinstall="yes"
			if [ -s "$SYSLOG_ARCHIVE_CFG" ]; then
				ret=`cat $SYSLOG_ARCHIVE_CFG  | grep "auto_start" |grep "yes"`
				if [ "0" = "$?" ]; then
					$SYNO_BIN_SET_KEY_VALUE $ENABLE_SERVICE_CONF "pkg-LogCenter-localarchive" yes
				fi
			fi
			if [ -s "$SYSLOG_BSD_CFG" ]; then
				ret=`cat $SYSLOG_BSD_CFG  | grep "auto_start" |grep "yes"`
				if [ "0" = "$?" ]; then
					$SYNO_BIN_SET_KEY_VALUE $ENABLE_SERVICE_CONF "pkg-LogCenter-bsd" yes
				fi
			fi
			if [ -s "$SYSLOG_IETF_CFG" ]; then
				ret=`cat $SYSLOG_IETF_CFG  | grep "auto_start" |grep "yes"`
				if [ "0" = "$?" ]; then
					$SYNO_BIN_SET_KEY_VALUE $ENABLE_SERVICE_CONF "pkg-LogCenter-ietf" yes
				fi
			fi
			if [ -s "$SYSLOG_CUSTRULE_CFG" ]; then
				ret=`cat $SYSLOG_CUSTRULE_CFG  | grep "auto_start" |grep "yes"`
				if [ "0" = "$?" ]; then
					$SYNO_BIN_SET_KEY_VALUE $ENABLE_SERVICE_CONF "pkg-LogCenter-custrule" yes
				fi
			fi
			if [ -s "$SYSLOG_CLIENT_CFG" ]; then
				ret=`cat $SYSLOG_CLIENT_CFG  | grep "auto_start" |grep "yes"`
				if [ "0" = "$?" ]; then
					$SYNO_BIN_SET_KEY_VALUE $ENABLE_SERVICE_CONF "pkg-LogCenter-client" yes
				fi
			fi
			if [ -s "$ENABLE_SERVICE_CONF" ]; then
				needinstall="yes"
			fi
			if [ "" != "$(get_key_value $DSM_LOGCENTER_SERVER_CONF arch_dest)" ]; then
				needinstall="yes"
			fi

			$BIN_RM	$SYSLOG_ARCHIVE_CFG
			$BIN_RM	$SYSLOG_BSD_CFG
			$BIN_RM	$SYSLOG_IETF_CFG
			$BIN_RM	$SYSLOG_CUSTRULE_CFG
			$BIN_RM	$SYSLOG_CLIENT_CFG

			if [ "no" = "$needinstall" ]; then
				return
			fi
			;;
		"Java7")
			# Upgrade JavaManager to Java7
			if [ ! -d "/var/packages/JavaManager" ]; then
				return
			fi
			;;
		"*")
			;;
	esac

	if $is_upgrade; then
		syslog "upgrade package: $1"
	else
		syslog "install package: $1"
	fi
	$SYNOPKG install "$1"
	ret=$?

	# return if install failed
	[ $ret -ne 0 ] && return $ret

	if [ "WebStation" = "$packageName" ]; then
		sed -i '/^runweb=\"yes\"$/d' /etc/synoinfo.conf
	fi

	if [ "LogCenter" = "$packageName" ]; then
		# pkg location path
		local PKG_LOGCENTER_TARGET="/var/packages/LogCenter/target"
		local PKG_LOGCENTER_SERVICE_CONF="$PKG_LOGCENTER_TARGET/service/conf/"
		local PKG_LOGCENTER_CLIENT_CONF="$PKG_LOGCENTER_TARGET/service/conf/client.conf"
		local BIN_MV=/bin/mv
		# migrate LogCenter config to pkg location
		local DSM_LOGCENTER_CLIENT_CONF="/etc/synosyslog/client.conf"
		local DSM_LOGCENTER_ENABLESERVICES="/etc/synosyslog/enable_services"
		local DSM_LOGCENTER_CUSTRULE_CONF="/etc/synosyslog/custrule.conf"
		local DSM_LOGCENTER_SERVER_CONF="/etc/synosyslog/server.conf"
		local DSM_LOGCENTER_CLIENT_KEYS="/usr/syno/etc/synosyslog/keys"
		local DSM_LOGCENTER_CLIENT_CLIENTKEYS="/usr/syno/etc/synosyslog/client_keys"

		if [ -s "$DSM_LOGCENTER_CUSTRULE_CONF" ];then
			$BIN_MV $DSM_LOGCENTER_CUSTRULE_CONF $PKG_LOGCENTER_SERVICE_CONF
		fi

		if [ -s "$DSM_LOGCENTER_ENABLESERVICES" ]; then
			$BIN_MV $DSM_LOGCENTER_ENABLESERVICES $PKG_LOGCENTER_SERVICE_CONF
		fi
		if [ -s "$DSM_LOGCENTER_CLIENT_CONF" ];then
			$SYNO_BIN_SET_KEY_VALUE $DSM_LOGCENTER_CLIENT_CONF "server_ca_path" "$PKG_LOGCENTER_CLIENT_CONF"
		fi

		$BIN_MV $DSM_LOGCENTER_SERVER_CONF $PKG_LOGCENTER_SERVICE_CONF
		$BIN_MV $DSM_LOGCENTER_CLIENT_CONF $PKG_LOGCENTER_SERVICE_CONF
		$BIN_MV $DSM_LOGCENTER_CLIENT_KEYS $PKG_LOGCENTER_SERVICE_CONF
		$BIN_MV $DSM_LOGCENTER_CLIENT_CLIENTKEYS $PKG_LOGCENTER_SERVICE_CONF

	fi

	if [ "Java7" = "$packageName" ]; then
		local ORACLE_JDK="/var/packages/JavaManager/target/Java"
		local OPEN_JDK="/var/packages/Java7/target/j2sdk-image"

		# Use OracleJDK if existed
		if [ -e ${ORACLE_JDK}/bin/java ]; then
			/bin/rm -rf ${OPEN_JDK}
			/bin/mv ${ORACLE_JDK} ${OPEN_JDK}
		fi

		# Uninstall package and remove environment variable
		$SYNOPKG uninstall "JavaManager"
	fi

	#install, but not enable
	if [ "HyperBackupVault" = "$packageName" ]; then
		local BACKUP_SERVER_CFG="/usr/syno/etc/synoservice.override/img_backupd.cfg"
		if [ -s "$BACKUP_SERVER_CFG" ] && [ "\"no\"" = "$(/bin/jq .auto_start $BACKUP_SERVER_CFG 2> /dev/null)" ]; then
			# send notification
			if $is_upgrade; then
				msg="pkgmgr:upgrade_pkg_completed"
			else
				msg="pkgmgr:install_pkg_completed"
			fi
			send_notification $msg $packageName
			return
		fi
	fi

	# send notification
	if $is_upgrade; then
		msg="pkgmgr:upgrade_start_pkg_completed"
	else
		msg="pkgmgr:install_start_pkg_completed"
	fi
	send_notification $msg $packageName

	/usr/syno/sbin/synopkgctl enable $packageName
	/usr/syno/sbin/synopkgctl correct-cfg $packageName
	return $ret
}

install_builtin_packages() {
	local package_dir=$1
	local old_bnum=`/bin/get_key_value /.old_patch_info/VERSION buildnumber`

	[ -d "$package_dir" ] || return 1

	# if no "/.old_patch_info" (new installation), skip installation of builtin package
	[ -f "/.old_patch_info/VERSION" ] || return 1

	if [ ! -z "$(ls -A $package_dir)" ]; then
		for i in $package_dir/*; do
			if $(is_in_dsm "${old_bnum}" "$i"); then
				install_package "$i"
			fi
		done
	fi
}

usage() {
	cat << EOF
Usage: $(basename $0) [start]
EOF
}

start()
{
	if [ -d /.SynoUpgradePackages ]; then
		install_builtin_packages /.SynoUpgradePackages
		rm -rf /.SynoUpgradePackages
	fi
}

case "$1" in
	start) start;;
	*) usage >&2; exit 1;;
esac
