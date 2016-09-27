#!/bin/sh
# Copyright (c) 2000-2013 Synology Inc. All rights reserved.

echo "Checking synolog tftpxfer table existence..."
su postgres -c "/usr/bin/psql synolog -c \"SELECT 1 FROM tftpxfer LIMIT 1\" > /dev/null"
Ret=$?
if [ $Ret = 1 ]; then
   echo "Creating tftpxfer table..."
   Script="/usr/syno/synologd/sql/upgrade/005_tftp_xfer.pgsql"
else
   Ret=0
fi

if [ $Ret = 1 ]; then      
   su postgres -c "/usr/bin/psql synolog < $Script"
   if [ $? != 0 ]; then
      echo "Failed to tftpxfer table"
      exit
   fi
fi
