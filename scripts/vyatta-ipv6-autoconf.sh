#!/bin/bash
# Copyright (c) 2019, AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

if [ "$1" == "update" ]; then
    if [ -e "/proc/sys/net/ipv6/conf/$2/autoconf" ]; then
        echo "Enabling address auto-configuration for $2"
        echo 1 > "/proc/sys/net/ipv6/conf/$2/autoconf"
        forwarding=$(cat "/proc/sys/net/ipv6/conf/$2/forwarding")
        if [ "$forwarding" = 1 ]; then
	    echo "Warning: IPv6 forwarding is currently enabled."
	    echo "         IPv6 address auto-configuration will not be performed"
	    echo "         unless IPv6 forwarding is disabled."
        fi
    else
        echo "Address auto-configuration will be enabled when interface comes up."
    fi
elif [ "$1" == "delete" ]; then
    if [ -e "/proc/sys/net/ipv6/conf/$2/autoconf" ]; then
        echo 0 > "/proc/sys/net/ipv6/conf/$2/autoconf"

        # Command prefix to execute iproute2 commands in correct rdid
        RDID=$(cat "/sys/class/net/$2/rdid" 2>/dev/null)
        if [[ -n "$RDID" && "$RDID" -ne 1 ]]; then
            IP_RD_ARGS=(rdid exec "$RDID" ip)
        else
            IP_RD_ARGS=()
        fi

        # Flush any temporary addresses created due to autoconf
        exec ip "${IP_RD_ARGS[@]}" -6 addr flush dev "$2" mngtmpaddr

    else
        echo "Address auto-configuration will be disabled when interface comes up."
    fi
else 
    echo "Usage:$0 update <ifname> "
    echo "	$0 delete <ifname>" 
fi

