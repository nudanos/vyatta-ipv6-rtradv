#!/usr/bin/perl
#
# Module: vyatta-ipv6-link-local.pl
#
# **** License ****
# Copyright (c) 2017-2021, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
#
# Syntax:
#    vyatta-ipv6-link-local.pl --update <ifname> <IPv6-address> [--verbose]
#    vyatta-ipv6-link-local.pl --delete <ifname> <IPv6-address> [--verbose]
#
# The first form will update a new  link-local IPv6 address on <ifname>
# Any other link-local address already configured or auto-generated
# for the interface will be deleted.
#
# The second form removes configured link-local address.
# This will result in link-local address to be autoconfigured if
# ipv6 is already enabled.
#

use strict;
use warnings;

use Getopt::Long;
use Net::IP;
use Vyatta::Interface;

# addr_gen_mode values
my $EUI64 = 0;
my $NONE  = 1;

my @update;
my @delete;

my $verbose = '';

GetOptions(
    "update=s{2}" => \@update,
    "delete=s{2}" => \@delete,
    "verbose"     => \$verbose,
) or usage();

update_ll_addr(@update) if (@update);
delete_ll_addr(@delete) if (@delete);
exit 0;

sub usage {
    print <<"EOF";
Updates or deletes configured link-local IPv6 address on the interface
Usage:	$0 --update <ifname> <IPv6address> [--verbose]
	$0 --delete <ifname> <IPv6address> [--verbose]
EOF
    exit 1;
}

# Set addr generation mode for IPv6 link-local addrs for when intf next comes up
sub ipv6_addr_gen_mode {
    my ( $name, $mode ) = @_;

    open my $f, '>', "/proc/sys/net/ipv6/conf/$name/addr_gen_mode"
      or return;
    print $f $mode;
    close $f;

    return;
}

sub update_ll_addr {
    my ( $ifname, $address ) = @_;

    # We expect the interface to exist and to be configured for IPv6
    die "Error: Interface $ifname does not exist.\n"
      unless ( -d "/proc/sys/net/ipv6/conf/$ifname" );

    my $ip = Net::IP->new($address);

    my $type = ( $ip->iptype() );
    die "Error: not a valid link-local IPv6 address: $address\n"
      if ( $type ne "LINK-LOCAL-UNICAST" );

    my $intf = Vyatta::Interface->new($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";
    open( my $ip_out, '-|', 'ip', '-6', 'addr', 'show', 'dev', $ifname, 'scope', 'link' )
      or die "Cannot run ip: $!\n";
    my @ll_addr_line = grep { /net6/x } <$ip_out>;
    close $ip_out;

    for ( my $i = 0 ; $i <= $#ll_addr_line ; $i++ ) {

        my @addr_line = split( ' ', $ll_addr_line[$i] );
        my $ll_addr   = $addr_line[1];
        if ( system("ip -6 addr del $ll_addr dev $ifname") != 0 ) {
            warn "Delete $ll_addr on $ifname failed \n";
        }
    }
    if ( system("ip -6 addr add $address/64 dev $ifname") != 0 ) {
        warn "IPv6 address $address on $ifname add failed \n";
    }
    elsif ($verbose) {
        ipv6_addr_gen_mode( $ifname, $NONE );
        print "$address replaced any other link-local addresses on $ifname \n";
    }

    exit 0;
}

sub delete_ll_addr {
    my ( $ifname, $address ) = @_;
    my $intf = Vyatta::Interface->new($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";

    if ( system("ip -6 addr del $address/64 dev $ifname") != 0 ) {
        warn "IPv6 address $address on $ifname delete failed \n";
    }
    ipv6_addr_gen_mode( $ifname, $EUI64 );
    print "IPv6 link-local address autoconfiguration enabled on $ifname \n"
      if $verbose;
    exit 0;
}

