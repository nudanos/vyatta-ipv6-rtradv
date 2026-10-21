#!/bin/bash
# Copyright (c) 2019, AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

procfile="/proc/sys/net/ipv6/conf/$2/forwarding"

# Check if fwding for intf is in kernel (0 if match), need tunnels only for now
kernelfwd=1
haverule=1
if [ -e "$procfile" ]; then
    ip link show dev "$2" | grep -q "tunnel6"
    kernelfwd=$?
    if [ $kernelfwd -eq 0 ]; then
        # Check if already have a rule (0 if match) to avoid duplicate addition
        ip6tables -S FORWARD |  grep -q "$2 -j DROP"
        haverule=$?
    fi
fi

if [ "$1" == "create" ]; then
    if [ -e "$procfile" ]; then
	echo "Disabling IPv6 forwarding for $2"
	echo 0 > "$procfile"
        # Use Netfilter where forwarding is in kernel & controlled per intf
        # (not exec: that ended the script before the touch below)
        if [ $kernelfwd -eq 0 ] && [ $haverule -eq 1 ]; then
            ip6tables -A FORWARD -i "$2" -j DROP 2> /dev/null
        fi
    else
	echo "IPv6 forwarding will be disabled when $2 comes up"
    fi
    touch "/var/run/vyatta/ipv6_no_fwd.$2"

elif [ "$1" == "delete" ]; then
    if [ -e "$procfile" ]; then
	# Only re-enable forwarding if global disable-forwarding switch
	# is not set.
	global=$(cat /proc/sys/net/ipv6/conf/default/forwarding)
	if [ "$global" = 1 ]; then
	    echo "Re-enabling IPv6 forwarding for $2"
	    echo 1 > "$procfile"
            # Use Netfilter where forwarding is in kernel & controlled per intf
            # (not exec: that ended the script before the rm below)
            if [ $kernelfwd -eq 0 ] && [ $haverule -eq 0 ]; then
                ip6tables -D FORWARD -i "$2" -j DROP 2> /dev/null
            fi
	else
	    echo "Not re-enabling IPv6 forwarding for $2 because it is still"
	    echo "globally disabled."
	fi
    else
	echo "IPv6 forwarding will be re-enabled when $2 comes up"
    fi
    rm -f "/var/run/vyatta/ipv6_no_fwd.$2"

else
    echo "Usage: $0 create <ifname>"
    echo "       $0 delete <ifname>"
fi


