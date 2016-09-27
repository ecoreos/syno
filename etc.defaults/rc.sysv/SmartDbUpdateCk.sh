#!/bin/sh
# Copyright (c) 2000-2016 Synology Inc. All rights reserved.
/usr/syno/bin/syno_smart_db_update
/bin/cp -af /usr/syno/share/smartmontools/synodrivedb.db /tmp/synodrivedb.db
/bin/cp -af /usr/syno/share/smartmontools/drivedb.db /tmp/drivedb.db
