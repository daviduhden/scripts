#!/usr/bin/env perl
#
# Atomic symlink replacement for sync-website.ksh. OpenBSD mv has no -h/-T;
# Perl's rename is used without embedding source in the ksh script.
#
# Usage: rename-link.pl SOURCE DESTINATION
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

my ( $source, $destination ) = @ARGV;
if ( !defined $source || !defined $destination || @ARGV != 2 ) {
    print STDERR "Usage: rename-link.pl SOURCE DESTINATION\n";
    exit 2;
}
rename $source, $destination or die "rename: $!\n";
