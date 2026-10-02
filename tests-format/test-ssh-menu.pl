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
use File::Temp qw(tempdir tempfile);
use IPC::Open3;

my $fail = 0;

sub fail_test {
    my ($msg) = @_;
    print STDERR "[FAIL] $msg\n";
    $fail = 1;
}

# Locate perl/ssh-menu.pl relative to this test (one level up).
my ( $vol, $dirs ) = File::Spec->splitpath( File::Spec->rel2abs($0) );
my $script = File::Spec->catfile( File::Spec->catpath( $vol, $dirs, '' ),
    '..', 'perl', 'ssh-menu.pl' );
-f $script or fail_test("cannot find perl/ssh-menu.pl relative to $0");

# ssh is required by ssh-menu itself; skip when unavailable.
{
    my $found;
    my $sep = $^O eq 'MSWin32' ? ';' : ':';
    for my $p ( split /\Q$sep\E/, ( $ENV{PATH} || '' ) ) {
        my $cand = File::Spec->catfile( $p, 'ssh' );
        $cand .= '.exe' if $^O eq 'MSWin32' && !-x $cand;
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

my $test_home = File::Spec->catfile( $tmp, 'home' );
make_path($test_home);

local $ENV{HOME}                 = $test_home;
local $ENV{SSH_MENU_KNOWN_HOSTS} = $known_hosts;
local $ENV{SSH_MENU_FREQ_FILE}   = File::Spec->catfile( $tmp, 'frequencies' );
local $ENV{SSH_MENU_ALIAS_FILE}  = File::Spec->catfile( $tmp, 'aliases' );
local $ENV{SSH_MENU_LAST_USER_FILE} = File::Spec->catfile( $tmp, 'last-user' );

# Avoid shell-specific printf/pipelines so these tests also run on Windows.
sub run_perl {
    my ( $input, @args ) = @_;
    my ($in)  = tempfile( DIR => $tmp, UNLINK => 1 );
    my ($out) = tempfile( DIR => $tmp, UNLINK => 1 );
    print {$in} $input;
    seek $in, 0, 0 or die "seek input: $!";
    my $pid = open3(
        '<&' . fileno($in),
        '>&' . fileno($out),
        '>&' . fileno($out),
        $^X, @args
    );
    waitpid $pid, 0;
    my $status = $?;
    seek $out, 0, 0 or die "seek output: $!";
    my $output = do { local $/; <$out> };
    close $in;
    close $out;
    return ( $output, $status );
}

my ($out) = run_perl( '', $script );

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

# Deleting a host through the "Manage known_hosts (delete)" menu entry must
# work and must not disturb comments, marker lines or hashed entries.
# Input: manage (3), entry 1, confirm (y), quit (q).
my ($del_out)  = run_perl( "3\n1\ny\nq\n", $script );
my ($kh_after) = do {
    open my $fh, '<', $known_hosts or fail_test("cannot read $known_hosts");
    local $/;
    <$fh>;
};
if ( $del_out !~ /Removed 1 line/ ) {
    fail_test("known_hosts deletion did not report removing one line");
}
if ( $kh_after =~ /^host1\.example\.com\b/m ) {
    fail_test("deleted host1 still present in known_hosts");
}
if ( $kh_after !~ /^host2\.example\.com\b/m ) {
    fail_test("host2 was removed unexpectedly");
}
if ( $kh_after !~ /\@cert-authority/ || $kh_after !~ /\@revoked/ ) {
    fail_test("marker lines were removed unexpectedly");
}
if ( $kh_after !~ /^\|1\|hash-of-something\|key/m ) {
    fail_test("hashed entry was removed unexpectedly");
}

# -G prints configuration without connecting. Exercise the real exec path,
# including Windows installations under Program Files, for both port forms.
my $driver = File::Spec->catfile( $tmp, 'ssh-config.pl' );
open my $driver_fh, '>', $driver or die "write $driver: $!";
print {$driver_fh} <<'DRIVER';
require shift;
my $port = shift;
my @cmd = build_ssh_command(find_in_path('ssh'), 'testuser', 'example.com', $port);
splice @cmd, 1, 0, '-G', '-F', File::Spec->devnull();
exec_ssh_command(@cmd);
DRIVER
close $driver_fh;
for my $port ( '', '2222' ) {
    my ( $config, $status ) = run_perl( '', $driver, $script, $port );
    my $expected_port = $port || '22';
    fail_test("SSH configuration failed for port $expected_port")
      if $status
      || $config !~ /^hostname example\.com\r?$/m
      || $config !~ /^user testuser\r?$/m
      || $config !~ /^port $expected_port\r?$/m;
}

if ($fail) {
    print STDERR "[INFO] test-ssh-menu.pl: FAILED\n";
    exit 1;
}
print "[INFO] test-ssh-menu.pl: passed\n";
exit 0;
