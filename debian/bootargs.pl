#!/usr/bin/env perl
#
# Boot-argument helper for rpi-update-safe. Kept separate so the shell script
# does not embed Perl source in -e or a heredoc.
#
# Usage:
#   bootargs.pl normalize            # read arguments from stdin
#   bootargs.pl remove-token FILE    # edit a DTS bootargs property in place
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Temp     qw(tempfile);

my $command = shift @ARGV // '';

sub usage {
    print STDERR "Usage: bootargs.pl normalize | remove-token FILE\n";
    exit 2;
}

sub normalize {
    my $value = do { local $/; <STDIN> };
    $value = '' unless defined $value;
    print join( ' ', grep { length } split /\s+/, $value ), "\n";
}

sub remove_token {
    my ($path) = @_;
    usage() unless defined $path && length $path;
    open my $in, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $text = <$in>;
    close $in or die "cannot close $path: $!\n";
    $text =~ s{
        (^[ \t]*bootargs[ \t]*=[ \t]*"[^"\n]*?)
        (?<![^ \t"])cgroup_disable=memory(?![^ \t"])
    }{$1}gmx;
    my @stat = stat $path or die "cannot stat $path: $!\n";
    my ( $out, $temporary ) = tempfile(
        '.bootargs-XXXXXX',
        DIR    => dirname($path),
        UNLINK => 0
    );
    print {$out} $text or die "cannot write $temporary: $!\n";
    close $out         or die "cannot close $temporary: $!\n";
    chmod $stat[2] & oct("7777"), $temporary
      or die "cannot chmod $temporary: $!\n";
    rename $temporary, $path or die "cannot replace $path: $!\n";
}

if ( $command eq 'normalize' ) {
    normalize();
}
elsif ( $command eq 'remove-token' ) {
    remove_token( shift @ARGV );
}
else {
    usage();
}
