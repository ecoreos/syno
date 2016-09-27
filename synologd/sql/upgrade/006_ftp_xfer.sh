#!/bin/sh
# Copyright (c) 2000-2013 Synology Inc. All rights reserved.

UpgradeSQL="ALTER TABLE ftpxfer ADD COLUMN isdir BOOLEAN DEFAULT FALSE"

echo "Checking synolog ftpxfer table for upgrade"
su postgres -c "/usr/bin/psql synolog -c \"SELECT isdir FROM ftpxfer LIMIT 1\" > /dev/null 2>&1"
Ret=$?
if [ $Ret = 1 ]; then
   echo "Upgrade ftpxfer table..."
else
   Ret=0
fi

if [ $Ret = 1 ]; then
   su postgres -c "/usr/bin/psql synolog -c \"$UpgradeSQL\" > /dev/null"
   if [ $? != 0 ]; then
      echo "Failed to upgrade ftpxfer table"
	  logger -p 0 "Failed to upgrade ftpxfer table"
      exit
   fi
fi
