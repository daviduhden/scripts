#!/usr/bin/env perl

# test-ssh-menu.pl
# - Regression test for perl/ssh-menu.pl's known_hosts parsing:
#   plain host lines must be listed, marker lines
#   (@cert-authority / @revoked) must not be mistaken for
#   hostnames.
# - Non-interactive: feeds EOF on stdin so the menu is printed
#   and the script exits without connecting anywhere.
# - Usage: ./test-ssh-menu.pl
#   Exit status: 0 if the test passes, 1 otherwise.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);

my $fail = 0;

sub fail_test {
    my ($msg) = @_;
    print STDERR "[FAIL] $msg\n";
    $fail = 1;
}

# Locate perl/ssh-menu.pl relative to this test (one level up).
my ( $vol, $dirs ) = File::Spec->splitpath( File::Spec->rel2abs($0) );
my $script = File::Spec->catfile( $dirs, '..', 'perl', 'ssh-menu.pl' );
-f $script or fail_test("cannot find perl/ssh-menu.pl relative to $0");

# ssh is required by ssh-menu itself; skip when unavailable.
{
    my $found;
    for my $p ( split /:/, ( $ENV{PATH} || '' ) ) {
        my $cand = File::Spec->catfile( $p, 'ssh' );
        if ( -x $cand ) { $found = 1; last }
    }
    if ( !$found ) {
        print "[INFO] ssh not found in PATH; skipping\n";
        exit 0;
    }
}

my $tmp = tempdir( 'ssh-menu-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

my $known_hosts = File::Spec->catfile( $tmp, 'known_hosts' );
open my $kh, '>', $known_hosts or fail_test("cannot write $known_hosts");
print {$kh} "host1.example.com ssh-ed25519 AAAAC3test\n";
print {$kh} "host2.example.com,host2alias ssh-rsa AAAAB3test\n";
print {$kh} "\@cert-authority *.example.com ssh-ed25519 AAAAC3test\n";
print {$kh} "\@revoked host3.example.com ssh-ed25519 AAAAC3test\n";
print {$kh} "|1|hash-of-something|key\n";
close $kh;

my $HOME = File::Spec->catfile( $tmp, 'home' );
make_path($HOME);

local $ENV{HOME}                 = $HOME;
local $ENV{SSH_MENU_KNOWN_HOSTS} = $known_hosts;

my $out = `printf '' | perl "$script" 2>&1`;

if ( $out !~ /host1\.example\.com/ ) {
    fail_test("plain host not listed in menu output");
}
if ( $out !~ /host2\.example\.com/ ) {
    fail_test("host with alias not listed in menu output");
}
if ( $out =~ /cert-authority/ ) {
    fail_test("\@cert-authority marker line parsed as a host");
}
if ( $out =~ /host3\.example\.com/ ) {
    fail_test("\@revoked marker line parsed as a host");
}

if ($fail) {
    print STDERR "[INFO] test-ssh-menu.pl: FAILED\n";
    exit 1;
}
print "[INFO] test-ssh-menu.pl: passed\n";
exit 0;
