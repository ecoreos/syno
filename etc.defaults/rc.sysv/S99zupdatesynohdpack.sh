#!/bin/sh
#

# 1 = download failure
# 2 = extract failure
# 3 = fail to get url

G_Running_File_Path="/tmp/downloadSynohdpack.running"
G_Error_File_Path="/tmp/downloadSynohdpack.error"
G_Download_Tar="/usr/syno/synoman/synohdpack/tmp/synohdpack_img.tgz"

syslog() {
	local ret=$?
	logger -p user.err -t $(basename $0) "$@"
	return $ret
}

getSynohdpack() {
	getUpdateServer
	mkdir -p /usr/syno/synoman/synohdpack/tmp/
	if [ 0 -eq $? -a -n "$G_update_server" ]; then
		get="--data-urlencode timezone=$G_timeZone --data-urlencode dsm_version=$G_DSMVersion --data-urlencode version=$G_dsmVersion"
		G_Response=`curl -G  $get ${G_update_server}updatesynohdpack/getSynohdpack.php`
		#G_Response=`curl -G  $get http://192.168.32.72/updatesynohdpack/getSynohdpack.php`
		if [ 0 -eq $? ]; then
			echo $G_Response > /tmp/synohdpack.json
			G_URL=`grep "url" /tmp/synohdpack.json | cut -d'"' -f4`
			G_URL=`echo $G_URL | sed -e 's/\\\//g'`
			#syslog $G_URL
			G_md5=`grep "md5" /tmp/synohdpack.json | cut -d',' -f2 | cut -d':' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
			G_SUCCESS=`grep "success" /tmp/synohdpack.json | cut -d',' -f3 | cut -d':' -f2 | cut -d'}' -f1`
			rm -f /tmp/synohdpack.json
		else
			rm -f $G_Running_File_Path
			echo "error=3" > $G_Error_File_Path
		fi
	else
		rm -f $G_Running_File_Path
		echo "error=3" > $G_Error_File_Path
	fi

	if [ 0 -eq $? -a "$G_SUCCESS" == "true" ]; then
		wget -O $G_Download_Tar $G_URL --no-check-certificat
		md5=`/usr/bin/openssl md5 $G_Download_Tar 2>/dev/null | cut -d' ' -f2`
		if [ 0 -eq $? -a -f $G_Download_Tar -a "$md5" == "$G_md5" ];
		then
			rm -rf /usr/syno/synoman/synohdpack/images
			rm -f /usr/syno/synoman/synohdpack/synohdpack.version

			if [ 0 -eq $? -a -f $G_Download_Tar ]; then
				mkdir -p /usr/syno/synoman/synohdpack/tmp/extract
				tar -xf $G_Download_Tar -C /usr/syno/synoman/synohdpack/tmp/extract
				if [ 0 -eq $? ]; then
					cp -af /usr/syno/synoman/synohdpack/tmp/extract/* /usr/syno/synoman/synohdpack
					rm -rf /usr/syno/synoman/synohdpack/tmp/
				else
					rm -f $G_Running_File_Path
					rm -rf /usr/syno/synoman/synohdpack/tmp/
					echo "error=2" > $G_Error_File_Path
					exit 2
				fi
			fi
		else
			echo "error=1" > $G_Error_File_Path
			rm -f $G_Running_File_Path
			rm -rf /usr/syno/synoman/synohdpack/tmp/
			exit 1
		fi
	else
		rm -f $G_Running_File_Path
		echo "error=3" > $G_Error_File_Path
		rm -rf /usr/syno/synoman/synohdpack/tmp/
		exit 3
	fi
}

getUpdateServer() {
	G_update_server=`grep "update_server" /etc.defaults/synoinfo.conf  | cut -d'=' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
}

getVersion() {
	G_dsmVersion=`uname -a | sed 's/ /\n/g' | grep ^# | cut -d'#' -f2`
}

getSynohdpackVersion() {
	G_synohdpackVersion=`grep "buildnumber" /usr/syno/synoman/synohdpack/synohdpack.version  | cut -d'=' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
}

getTimeZone() {
	G_timeZone=`grep "timezone" /etc/synoinfo.conf  | cut -d'=' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
}

getMinorVersion() {
	G_MinorVersion=`grep "minorversion" /etc.defaults/VERSION | cut -d'=' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
}

getMajorVersion() {
	G_MajorVersion=`grep "majorversion" /etc.defaults/VERSION | cut -d'=' -f2 | cut -d'"' -f2 | cut -d'"' -f1`
}

getDSMVersion() {
	getMajorVersion
	getMinorVersion
	G_DSMVersion="DSM${G_MajorVersion}.${G_MinorVersion}"
}

main() {
	if [ -f $G_Running_File_Path ];
	then
		exit
	fi

	touch $G_Running_File_Path
	rm -f $G_Download_Tar
	rm -f $G_Error_File_Path

	getDSMVersion
	getTimeZone
	getVersion

	if [ -f /usr/syno/synoman/synohdpack/synohdpack.version ]; then
		getSynohdpackVersion
		if [ "$G_dsmVersion" != "$G_synohdpackVersion" ]; then
			getSynohdpack
		fi
	else
		getSynohdpack
	fi
	rm -f $G_Running_File_Path
}

main &
