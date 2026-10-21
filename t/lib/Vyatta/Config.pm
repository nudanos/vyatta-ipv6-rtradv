# Test stub: a config tree from the file named by $ENV{VYATTA_TEST_CONFIG},
# one "path words = value" or "path words" line per node.
package Vyatta::Config;

use strict;
use warnings;

sub new {
    my %tree;
    open my $fh, '<', $ENV{VYATTA_TEST_CONFIG} or die "$!\n";
    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line eq q{};
        my ( $path, $value ) = split /[ ]=[ ]/x, $line, 2;
        $tree{$path} = $value;
    }
    close $fh or die "$!\n";
    return bless { tree => \%tree }, shift;
}

# the child names under $path, in file order
sub listNodes {
    my ( $self, $path ) = @_;
    my ( @names, %seen );
    foreach my $node ( sort keys %{ $self->{tree} } ) {
        next unless $node =~ /^\Q$path\E[ ](\S+)/x;
        push @names, $1 unless $seen{$1}++;
    }
    return @names;
}

sub returnValue {
    my ( $self, $path ) = @_;
    return $self->{tree}{$path};
}

1;
