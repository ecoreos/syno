#!/bin/sh

CHECKING_FILE=/tmp/.ha.checking.heartbeat

if [ -f ${CHECKING_FILE} ]; then
    exit 1
fi

exit 0
