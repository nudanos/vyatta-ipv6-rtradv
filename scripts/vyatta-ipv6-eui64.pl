#!/usr/bin/perl
#
# Module: vyatta-ipv6-eui64.pl
#
# **** License ****
# Copyright (c) 2019, AT&T Intellectual Property.  All rights reserved.
#
# Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# Copyright (c) 2007-2013, Vyatta, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
#
# Syntax:
#    vyatta-ipv6-eui64.pl --create <ifname> <IPv6-prefix>
#    vyatta-ipv6-eui64.pl --delete <ifname> <IPv6-prefix>
#
# The first form will create a new IPv6 address on <ifname> using
# the EUI-64 format.  The <IPv6-prefix> will be used to form the
# high-order 64 bits of the address.  The 48-bit MAC address will
# be padded out as specified in RFC-3513 to form a 64-bit EUI-64
# which will be used to form the low-order 64-bits of the address.
#
# The second form removes an EUI-64 format address from <ifname>.
# First an IPv6 address will be formed in the same manner as above.  Then,
# if that address is assigned to <ifname>, it will be deleted.
#
# If the interface just has an IPv4 address as a hardware address
# (tunnel interfaces) convert using RFC5342.
#

use strict;
use warnings;

use Getopt::Long;
use Net::IP;
use Vyatta::Interface;

my @create;
my @delete;

GetOptions(
    "create=s{2}" => \@create,
    "delete=s{,}" => \@delete,
) or usage();

create_addr(@create) if (@create);
delete_addr(@delete) if (@delete);
exit 0;

# Test if IPv6 is disabled on this interface
sub ipv6_disabled {
    my $name = shift;
    open my $f, '<', "/proc/sys/net/ipv6/conf/$name/disable_ipv6"
      or return;
    chomp( my $disabled = <$f> );
    close $f;
    return $disabled;
}

# the output of a shell command, as backticks gave it, with $? set; undef
# if it cannot run
sub command_output {
    my ($cmd) = @_;
    open( my $fh, '-|', $cmd ) or return;
    my $out = do { local $/ = undef; <$fh> }
      // q{};
    close $fh;
    return $out;
}

sub usage {
    print <<"EOF";
Usage:	$0 --create ifname ipv6address/64
	$0 --delete ifname ipv6address/64
EOF
    exit 1;
}

sub get_mac_address {
    my ( $ifname, $macaddr ) = @_;

    unless ( defined($macaddr) ) {

        # Get 48-bit MAC addr of $ifname
        open my $sysfs, '<', "/sys/class/net/$ifname/address"
          or die "can't open /sys/class/net/$ifname/address: $!\n";
        $macaddr = <$sysfs>;
        close $sysfs;
        chomp $macaddr;
    }

    my @octets = split( ':', $macaddr );
    die "Error: $macaddr not a 48 bit MAC address, IPv6 or IPv4 address\n"
      unless ( $#octets == 15 || $#octets == 5 || $#octets == 3 );

    return @octets;
}

sub get_uuid_eui64 {
    my $ifname = shift;
    my $uuid   = command_output('/usr/sbin/dmidecode -s system-uuid');
    die "Error: no system UUID found\n" unless ( defined($uuid) );
    chomp($uuid);

    # Extract node identifier as last 6 octets from UUID as per RFC4122
    my @nodeid = lc( substr( $uuid, -12, 12 ) ) =~ /([0-9a-f]{4})/gx;
    die "Error: no valid system UUID found\n" unless ( $#nodeid == 2 );

    # Set universal/local bit to indicate local scope
    $nodeid[0] = sprintf( "%x", hex( $nodeid[0] ) & 0xfdff );

    # Interface id lower 12 bits derived from numeric part of name. Top nibble
    # of 2 octets reserved for interface type (applies only to tunnels so far)
    $ifname =~ tr/0-9//cd;
    die "Error: invalid interface name\n" if ( $ifname eq "" );
    my $ifid = sprintf( "%.4x", $ifname % 4096 );

    return ( @nodeid, $ifid );
}

sub get_address {
    my ( $ifname, $address, $mac ) = @_;

    # We expect the interface to exist and to be configured for IPv6
    die "Error: Interface $ifname does not exist.\n"
      unless ( -d "/proc/sys/net/ipv6/conf/$ifname" );

    my $ip = Net::IP->new($address);
    die "Error: not a valid IPv6 prefix: $address\n"
      unless defined($ip);

    my $prefix_len = $ip->prefixlen();
    die "Error: Prefix length $prefix_len is not 64\n"
      if ( $prefix_len != 64 );

    # construct the host part from the MAC address
    my @ea = get_mac_address( $ifname, $mac );

    my @eui64;
    if ( $#ea == 3 ) {

        # Modified EUI-64 is constructed from the IPv4 address given
        # in the h/w address as per RFC5342 section 2.2.1
        @eui64 = ( "0200", "5efe", "$ea[0]$ea[1]", "$ea[2]$ea[3]" );
    }
    elsif ( $#ea == 5 ) {

        # flip locally assigned bit per RFC 2373
        $ea[0] = sprintf( "%x", hex( $ea[0] ) ^ 0x2 );

        # construct EUI64 address array
        @eui64 = ( "$ea[0]$ea[1]", "$ea[2]ff", "fe$ea[3]", "$ea[4]$ea[5]" );
    }
    else {
        @eui64 = get_uuid_eui64($ifname);
    }

    # Form 128-bit IPv6 addr based by adding the host part to the prefix
    my $eui64suffix = Net::IP->new( "::" . join ":", @eui64 );
    my $ipv6_addr   = $ip->binadd($eui64suffix);
    return $ipv6_addr->ip . "/64";
}

sub create_addr {
    my ( $ifname, $prefix ) = @_;
    my $ipv6_addr = get_address( $ifname, $prefix, undef );

    # If IPv6 is disabled, the address cannot be added in the kernel. Do not
    # run the command so as not to lose the address from the configuration.
    if ( ipv6_disabled($ifname) ) {
        exit 0;
    }

    # Assign addr to $ifname
    my $intf = Vyatta::Interface->new($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";
    my $cmd_prefix = $intf->can("vrf_cmd_prefix") ? $intf->vrf_cmd_prefix() : "";
    my $result     = command_output("${cmd_prefix}ip -6 addr add $ipv6_addr dev $ifname 2>&1");
    if ( $? && index( $result, "File exists" ) == -1 ) {
        die "Error: Couldn't assign IPv6 addr $ipv6_addr to $ifname\n";
    }

    exit 0;
}

sub delete_addr {
    my ( $ifname, $prefix, $mac ) = @_;
    my $ipv6_addr = get_address( $ifname, $prefix, $mac );

    # If IPv6 is disabled, the address cannot be deleted in the kernel. Do not
    # run the command so as not to lose this change from the configuration.
    if ( ipv6_disabled($ifname) ) {
        exit 0;
    }

    # Attempt to delete addr from $ifname...
    # Requested address may not exist if mac given externally, so ignore error
    my $intf = Vyatta::Interface->new($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";
    my $cmd_prefix = $intf->can("vrf_cmd_prefix") ? $intf->vrf_cmd_prefix() : "";
    my $result     = command_output("${cmd_prefix}ip -6 addr del $ipv6_addr dev $ifname 2>&1");
    if ( $? && ( !defined($mac) || index( $result, "Cannot assign" ) == -1 ) ) {
        die "Warning: Couldn't delete IPv6 addr $ipv6_addr from $ifname\n";
    }

    exit 0;
}
