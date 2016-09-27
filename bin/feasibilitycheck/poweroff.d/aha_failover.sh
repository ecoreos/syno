#!/bin/sh

/usr/syno/synoaha/bin/synoaha --is_failing_over

if [ $? -ne 0 ]; then
	exit 1
fi

exit 0
