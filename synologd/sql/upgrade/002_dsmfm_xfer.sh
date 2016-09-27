#!/bin/sh
# Copyright (c) 2000-2013 Synology Inc. All rights reserved.

echo "Checking synolog dsmfmxfer table existence..."
su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM dsmfmxfer LIMIT 1\" > /dev/null"
Ret=$?
if [ $Ret = 1 ]; then
   echo "Creating dsmfmxfer table..."
   Ret=1
   Script="/usr/syno/synologd/sql/upgrade/002_dsmfm_xfer.pgsql"
else
   Ret=0
fi

if [ $Ret = 1 ]; then      
   su postgres -c "/usr/bin/psql synolog < $Script"
   if [ $? != 0 ]; then
      echo "Failed to dsmfmxfer table"
      exit
   fi
fi

