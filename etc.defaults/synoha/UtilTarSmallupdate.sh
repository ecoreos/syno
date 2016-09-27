#!/bin/bash

if [ $# -ne 2 ]; then
	exit 1;
fi

srcDir=$1
destPat=$2

if [ -d "$srcDir" ]; then
	cd $srcDir
	tar zcf $destPat *
fi

