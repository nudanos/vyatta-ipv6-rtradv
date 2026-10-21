#!/usr/bin/perl
#
# Module: vyatta_gen_radvd.pl
# Description:  Setup section of the radvd.conf file for an interface.
#
# **** License ****
#
# Copyright (c) 2019, AT&T Intellectual Property.  All rights reserved.
#
# Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2005-2009 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
#
#

#
# Syntax:
#    vyatta_gen_radvd.pl --generate <ifname>
#    vyatta_gen_radvd.pl --delete <ifname>
#
# In the first instance, <ifname> is the name of the interface for
# which the configuration file is to be generated (e.g. eth0, eth7.3,
# pppoe7, wan0.1, ml0, etc.) and <config-param-root> is the root of
# the tree of configuration parameters
# (e.g. "/interfaces/ethernet/eth0/ipv6/router-advert").
#
# This script generates a partial radvd.conf file holding the
# parameters for one interface, and writes it to a temp file.  It then
# strips any previous configuration for this interface from the
# system-wide config file /etc/radvd.conf.  Then it cat's the contents
# of the temp file into the system-wide config file /etc/radvd.conf.
# After that it re-starts the radvd daemon.  Since the daemon is stateless,
# re-starting it is a lightweight operation.
#
# In the second instance, <ifname> is the name of the interface
# whose configuration is to be removed from the /etc/radvd.conf file

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use Vyatta::Config;
use Getopt::Long;
use Vyatta::Interface;

# VYATTA_RADVD_CONF is for the tests
my $conf_file = $ENV{VYATTA_RADVD_CONF} // "/etc/radvd.conf";

# Set to 1 to enable debug output
my $debug_flag = 0;

sub log_msg {
    my $message = shift;

    if ( $debug_flag > 0 ) {
        print "DEBUG: $message";
    }
    return;
}

my $config;
my $FD_WR;    # Temporary config file pointer
my $generate;
my $delete;

GetOptions(
    "generate=s" => \$generate,
    "delete=s"   => \$delete
);

if ($generate) {
    generate_conf($generate);
    exit 0;
}

if ($delete) {
    delete_conf($delete);
    exit 0;
}

printf("Error: invalid args: @ARGV\n");
exit 1;

# Read the parameters under $root into %$hash: a "true"/other flag node
# sets its key "on"/"off", a value node sets its key to the value
sub read_params {
    my ( $root, $hash, $flags, $values ) = @_;

    foreach my $param ( $config->listNodes($root) ) {
        log_msg("Node: $param \n");
        my $value = $config->returnValue("$root $param");
        log_msg( "Value: " . ( defined($value) ? $value : "NULL" ) . "\n" );

        if ( exists $flags->{$param} ) {
            $hash->{ $flags->{$param} } = ( ( $value // q{} ) eq "true" ) ? 'on' : 'off';
        }
        elsif ( exists $values->{$param} ) {
            $hash->{ $values->{$param} } = $value;
        }
    }
    return;
}

# Parse and write config file for one prefix under an interface
sub do_prefix {
    my ( $param_root, $prefix ) = @_;

    # RFC-4861 parameters for each element of AdvPrefixList.
    # Parameters with fixed default values have those values specified
    # here.  Those values may be simply over-ridden by user-selected
    # values.  Parameters that have algorithmic default values have
    # their value set to -1 here.  User-selected values can over-ride
    # them.  If the user doesn't select a value, a final value is
    # determined later on.  Note: Keys are the parameter strins
    # used in radvd.conf file, which do not always match exactly the
    # strings used in RFC-4861.

    my %prefix_param_hash = (
        'AdvValidLifetime'     => '2592000',
        'AdvOnLink'            => 'on',
        'AdvPreferredLifetime' => '-1',
        'AdvAutonomous'        => 'on'
    );

    # Read in parameters set by user
    read_params(
        "$param_root prefix $prefix",
        \%prefix_param_hash,
        { 'on-link-flag' => 'AdvOnLink', 'autonomous-flag' => 'AdvAutonomous' },
        {
            'valid-lifetime'     => 'AdvValidLifetime',
            'preferred-lifetime' => 'AdvPreferredLifetime'
        }
    );

    # Fill in any missing default values
    if ( $prefix_param_hash{'AdvPreferredLifetime'} == -1 ) {
        if (   ( $prefix_param_hash{'AdvValidLifetime'} > 604800 )
            || ( $prefix_param_hash{'AdvValidLifetime'} eq "infinity" ) )
        {
            $prefix_param_hash{'AdvPreferredLifetime'} = 604800;
        }
        else {
            $prefix_param_hash{'AdvPreferredLifetime'} = $prefix_param_hash{'AdvValidLifetime'};
        }
    }

    # Validate user parameters
    if (
        ( $prefix_param_hash{'AdvValidLifetime'} ne "infinity" )
        && (
            ( $prefix_param_hash{'AdvPreferredLifetime'} eq "infinity" )
            || ( $prefix_param_hash{'AdvPreferredLifetime'} >
                $prefix_param_hash{'AdvValidLifetime'} )
        )
      )
    {
        printf("Error: You have set preferred-lifetime to ");
        printf("$prefix_param_hash{'AdvPreferredLifetime'}\n");
        printf("and valid-lifetime to ");
        printf("$prefix_param_hash{'AdvValidLifetime'}.\n");
        printf("preferred-lifetime must be less than or equal to valid-lifetime.\n");
        exit(1);
    }

    # Write parameters out to config file
    print $FD_WR "    prefix $prefix {\n";
    foreach my $key ( keys %prefix_param_hash ) {
        print $FD_WR "        $key $prefix_param_hash{$key};\n";
    }

    print $FD_WR "    };\n";
    return;
}

# The MTU "ip link show" reports for $ifname, or undef
sub live_mtu {
    my ($ifname) = @_;
    open( my $ip, '-|', 'ip', '-o', 'link', 'show', $ifname ) or return;
    my $out = do { local $/ = undef; <$ip> }
      // q{};
    close $ip;
    my ($mtu) = ( $out =~ /mtu[ ]([0-9]+)/x );
    return $mtu;
}

# Fill in the interface parameters that default to a value computed from
# the others
sub fill_interface_defaults {
    my ($param_hash) = @_;

    if ( $param_hash->{'MinRtrAdvInterval'} == -1 ) {
        if ( $param_hash->{'MaxRtrAdvInterval'} > 9 ) {

            # Round to nearest integer
            $param_hash->{'MinRtrAdvInterval'} =
              sprintf( "%.0f", $param_hash->{'MaxRtrAdvInterval'} * 0.33 );
        }
        else {
            $param_hash->{'MinRtrAdvInterval'} = 3;
        }
    }

    if ( $param_hash->{'AdvDefaultLifetime'} == -1 ) {
        $param_hash->{'AdvDefaultLifetime'} = $param_hash->{'MaxRtrAdvInterval'} * 3;
    }
    return;
}

# Warn about link-mtu against the live MTU; exit 1 on an invalid interval
# or default lifetime
sub validate_interface_params {
    my ( $ifname, $param_hash ) = @_;
    my %p = %$param_hash;

    my $mtu_param = $p{'AdvLinkMTU'};
    if ( $mtu_param > 0 ) {
        my $live_mtu = live_mtu($ifname);
        if ( $live_mtu > $mtu_param ) {
            printf("Warning: link-mtu parameter given ($mtu_param) is less than the MTU\n");
            printf("currently being used on $ifname ($live_mtu).\n");
        }
        elsif ( $live_mtu < $mtu_param ) {
            printf("Warning: link-mtu parameter given ($mtu_param) exceeds the MTU\n");
            printf("currently being used on $ifname ($live_mtu) and will NOT be advertised.\n");
        }
    }

    # the first failing check ends the run
    my @checks = (
        [
            $p{'MaxRtrAdvInterval'} > 1800,
            "Error: MaxRtrAdvInterval value is $p{'MaxRtrAdvInterval'}. It must be 1800 or less.\n"
        ],
        [
            $p{'MaxRtrAdvInterval'} < 4,
            "Error: MaxRtrAdvInterval valueis $p{'MaxRtrAdvInterval'}. It must be 4 or more\n"
        ],
        [
            $p{'MinRtrAdvInterval'} < 3,
            "Error: MinRtrAdvInterval value is $p{'MinRtrAdvInterval'}. It must be 3 or more\n"
        ],
        [
            $p{'MinRtrAdvInterval'} > ( $p{'MaxRtrAdvInterval'} * 0.75 ),
"Error: MinRtrAdvInterval is $p{'MinRtrAdvInterval'} and MaxRtrAdvInterval is $p{'MaxRtrAdvInterval'}.\n"
              . "MinRtrAdvInterval must be no greater than 3/4 MaxRtrAdvInterval\n"
        ],
        [
            ( $p{'AdvDefaultLifetime'} != 0 )
              && ( $p{'AdvDefaultLifetime'} < $p{'MaxRtrAdvInterval'} ),
            "Error: AdvDefaultLifetime is $p{'AdvDefaultLifetime'}"
              . " and MaxRtrAdvInterval is $p{'MaxRtrAdvInterval'}.\n"
              . "AdvDefaultLifetime must equal to or greater than MaxRtrAdvInterval.\n"
        ],
        [
            $p{'AdvDefaultLifetime'} > 9000,
"Error: AdvDefaultLifetime vlaue is $p{'AdvDefaultLifetime'}.  It must be 9000 or less.\n"
        ],
    );
    my @errors = map { $_->[1] } grep { $_->[0] } @checks;
    if (@errors) {
        print $errors[0];
        exit 1;
    }
    return;
}

# Parse params and write config file for one interface
sub do_interface {
    my $ifname = shift;
    my $intf   = Vyatta::Interface->new($ifname);
    die "Unknown interface type $ifname\n" unless $intf;
    my $param_root = $intf->path() . " ipv6 router-advert";

    # RFC-4861 parameters and their default values.
    # Parameters with fixed defined default values have those values
    # set here.  Those values may be simply over-ridden by user-selected
    # values.  Parameters that have algorithmic default values
    # have their value set to -1 here.  User-selected values can
    # over-ride them.  If the user doesn't select a value, a final
    # value is determined later on.
    my %param_hash = (
        'AdvSendAdvert'        => 'off',
        'MaxRtrAdvInterval'    => 600,
        'MinRtrAdvInterval'    => -1,
        'AdvManagedFlag'       => 'off',
        'AdvOtherConfigFlag'   => 'off',
        'AdvLinkMTU'           => '0',
        'AdvReachableTime'     => '0',
        'AdvRetransTimer'      => '0',
        'AdvCurHopLimit'       => '64',
        'AdvDefaultLifetime'   => '-1',
        'AdvDefaultPreference' => 'medium'
    );

    # Read in top-level params; prefixes are done later
    read_params(
        $param_root,
        \%param_hash,
        {
            'managed-flag'      => 'AdvManagedFlag',
            'other-config-flag' => 'AdvOtherConfigFlag',
            'send-advert'       => 'AdvSendAdvert'
        },
        {
            'max-interval'       => 'MaxRtrAdvInterval',
            'min-interval'       => 'MinRtrAdvInterval',
            'link-mtu'           => 'AdvLinkMTU',
            'reachable-time'     => 'AdvReachableTime',
            'retrans-timer'      => 'AdvRetransTimer',
            'cur-hop-limit'      => 'AdvCurHopLimit',
            'default-lifetime'   => 'AdvDefaultLifetime',
            'default-preference' => 'AdvDefaultPreference'
        }
    );

    fill_interface_defaults( \%param_hash );
    validate_interface_params( $ifname, \%param_hash );

    # Spit out top-level params to config file
    my $date = localtime;
    my $user = getpwuid($<) || 'Unknown';

    print $FD_WR "interface $ifname {\n";
    print $FD_WR "#   This section was automatically generated by the Vyatta\n";
    print $FD_WR "#   configuration sub-system.  Do not edit it.\n";
    print $FD_WR "#\n";
    print $FD_WR "#   Generated by $user on $date\n";
    print $FD_WR "#\n";
    print $FD_WR "    IgnoreIfMissing on;\n";
    foreach my $key ( keys %param_hash ) {
        print $FD_WR "    $key $param_hash{$key};\n";
    }

    # Process prefix params, if any
    my @prefix_params = $config->listNodes("$param_root prefix");
    log_msg("prefix_params = @prefix_params\n");

    foreach my $prefix (@prefix_params) {
        log_msg("prefix = $prefix\n");
        do_prefix( $param_root, $prefix );
    }

    # Finish off config file
    print $FD_WR "};\n";
    return;
}

sub generate_conf {
    my $ifname = shift;
    log_msg("ifname = $ifname\n");

    # Generate config file for this interface into temporary string buffer
    my $conf_buffer;

    open $FD_WR, '>', \$conf_buffer
      or die "can't open temporary buffer: $!\n";

    $config = Vyatta::Config->new();

    # Generate config file section for interface into temp file
    do_interface($ifname);

    close $FD_WR;

    if ( -e $conf_file ) {

        # Delete old parameter section for interface from global config file
        delete_conf($ifname);
    }

    # Cat newly generated temp file into global config file
    log_msg("copying in tempfile...\n");

    open my $CFG, '>>', $conf_file
      or die "can't open $conf_file: $!\n";

    print {$CFG} $conf_buffer;

    close $CFG;
    return;
}

#
# Delete the configuration information for an interface from the config file:
# from its "interface <ifname> {" line to the next "}" line, as
# sed '/^interface <ifname> {/,/^}/d' did.
#
sub delete_conf {
    my ($ifname) = @_;
    log_msg("delete_conf ifname = $ifname\n");

    my @lines;
    my $ok = open( my $in, '<', $conf_file );
    if ($ok) {
        @lines = <$in>;
        close $in;

        # ... checks for the end from the line after the start, as sed does
        @lines = grep { !( /^interface[ ]\Q$ifname\E[ ][{]/x ... /^[}]/x ) } @lines;
        $ok    = open( my $out, '>', $conf_file );
        if ($ok) {
            print {$out} @lines;
            $ok = close $out;
        }
    }
    if ( !$ok ) {
        printf("Unable to edit radvd system config file: $!\n");
        exit 1;
    }
    return;
}

# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
