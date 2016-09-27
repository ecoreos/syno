#!/bin/sh
# Copyright (c) 2000-2013 Synology Inc. All rights reserved.

echo "Checking synolog webdavxfer table existence..."
su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM webdavxfer LIMIT 1\" > /dev/null"
Ret=$?
if [ $Ret = 1 ]; then
   echo "Creating webdavxfer table..."
   Ret=1
   Script="/usr/syno/synologd/sql/upgrade/003_webdav_xfer.pgsql"
else
   Ret=0
fi

if [ $Ret = 1 ]; then      
   su postgres -c "/usr/bin/psql synolog < $Script"
   if [ $? != 0 ]; then
      echo "Failed to webdavxfer table"
      exit
   fi
fi

