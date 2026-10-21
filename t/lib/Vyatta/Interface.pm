# Test stub: every interface is a dataplane interface.
package Vyatta::Interface;

use strict;
use warnings;

sub new {
    my ( $class, $name ) = @_;
    return bless { name => $name }, $class;
}

sub path {
    my ($self) = @_;
    return "interfaces dataplane $self->{name}";
}

1;
