#!/bin/bash
# Copyright (c) 2019, AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2015-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

if [ "$COMMIT_ACTION" = "SET" ] || [ "$COMMIT_ACTION" = "ACTIVE" ]; then
    echo "Re-generating radvd config file for interface $1..."
    if ! /opt/vyatta/sbin/vyatta_gen_radvd.pl --generate "$1"; then
	exit 1
    fi
elif [ "$COMMIT_ACTION" = "DELETE" ]; then
    echo "Deleting entry for interface $1 from radv config file..."
    if ! /opt/vyatta/sbin/vyatta_gen_radvd.pl --delete "$1"; then
	exit 1
    fi
else 
    echo "Unexpected commit action: $COMMIT_ACTION"
fi

if (service radvd status &> /dev/null); then
    if [ -s /etc/radvd.conf ]; then
	echo "Re-starting radvd..."
	service radvd restart
    else
	echo "Stopping radvd..."
	service radvd stop
    fi
else
    if [ -s /etc/radvd.conf ]; then
	echo "Starting radvd..."
	service radvd start
    else
	echo "Not starting radvd."
    fi
fi
