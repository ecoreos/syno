#!/bin/sh
# Copyright (c) 2000-2015 Synology Inc. All rights reserved.

echo "Checking synolog afpxfer table existence..."
su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM afpxfer LIMIT 1\" > /dev/null"
Ret=$?
if [ $Ret = 1 ]; then
   echo "Creating afpxfer table..."
   Script="/usr/syno/synologd/sql/upgrade/007_afp_xfer.pgsql"
else
   Ret=0
fi

if [ $Ret = 1 ]; then      
   su postgres -c "/usr/bin/psql synolog < $Script"
   if [ $? != 0 ]; then
      echo "Failed to afpxfer table"
      exit
   fi
fi
