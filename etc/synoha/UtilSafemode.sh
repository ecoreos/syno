#!/bin/bash

export LC_ALL=en_US.UTF-8

LSYNCD_PASSWORD_FILE=/usr/syno/synoha/etc/confsync/rsync.pw
RSYNC=/bin/rsync
RSYNC_OPTIONS="--dry-run --port=874 -Rna --password-file=$LSYNCD_PASSWORD_FILE --exclude=@tmp --exclude=@eaDir"
HA_SAFEMODE_DIR=/var/lib/ha/safemode
LOCAL_LIST=$HA_SAFEMODE_DIR/local.list
REMOTE_LIST=$HA_SAFEMODE_DIR/remote.list
ALL_LIST=$HA_SAFEMODE_DIR/diff.all

# local list
ListLocalList()
{
	local remote_ip=$1
	local volume=$2
	local share=$3
	$RSYNC $RSYNC_OPTIONS --out-format='{"filepath": "%f", "local_modify_time": "%M", "local_size": %l}' \
		"/$volume/$share" \
		"root@$remote_ip::synoha_root/$volume/$share" \
		| /bin/sed 's,\\,\\\\,g' \
		| (head -n 10000 > $LOCAL_LIST; \
		killall `/bin/ps auxww \
		| /bin/grep rsync \
		| /bin/grep -v grep \
		| /bin/grep -v daemon \
		| /bin/awk '{print $2}'`)
}

# remote list
ListRemoteList()
{
	local remote_ip=$1
	local volume=$2
	local share=$3
	$RSYNC $RSYNC_OPTIONS --out-format='{"filepath": "%f", "remote_modify_time": "%M", "remote_size": %l}' \
		"root@$remote_ip::synoha_root/$volume/$share" \
		"/$volume/$share" \
		| /bin/sed 's,\\,\\\\,g' \
		| (head -n 10000 > $REMOTE_LIST; \
		killall `/bin/ps auxww \
		| /bin/grep rsync \
		| /bin/grep -v grep \
		| /bin/grep -v daemon \
		| /bin/awk '{print $2}'`)
}

ListCombined()
{
	local volume=$1
	local share=$2
	/bin/jq -c -s "group_by(.filepath) \
		| map(add \
			| select(.filepath != \"$volume\") \
			| select(.local_size != .remote_size or .local_modify_time != .remote_modify_time) \
			| .filepath = \"/\" + .filepath)" \
		$LOCAL_LIST \
		$REMOTE_LIST \
		> $HA_SAFEMODE_DIR/${volume}.${share}.diff
	rm -f $LOCAL_LIST
	rm -f $REMOTE_LIST
}

action=$1; shift

case $action in
	"list-remote")
		[ 3 -ne $# ] && exit 1
		ListRemoteList $1 $2 $3
		;;
	"list-local")
		[ 3 -ne $# ] && exit 1
		ListLocalList $1 $2 $3
		;;
	"list-combined")
		[ 2 -ne $# ] && exit 1
		ListCombined $1 $2
		;;
	"list")
		[ 3 -ne $# ] && exit 1
		ListRemoteList $1 $2 $3
		ListLocalList $1 $2 $3
		ListCombined $2 $3
		;;
	"list-all")
		[ 0 -eq $# ] && exit 1
		/bin/jq -c -s 'add | if length > 100000 then [.[range(0;100000)]] else . end' $* > $ALL_LIST
		;;
	*)
		false
		;;
esac

exit 0

