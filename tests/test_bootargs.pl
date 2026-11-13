#!/usr/bin/env perl

# Regression checks for the rpi-update-safe bootargs helper.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;
use Test::More;

use TestHarness qw(
  new_tempdir
  repo_root
  run_command
  slurp
  write_file
);

my $REPO   = repo_root();
my $HELPER = "$REPO/debian/bootargs.pl";
my $PERL   = $^X;

sub normalize {
    my ( $value, $drop ) = @_;
    my @command = ( $PERL, $HELPER, 'normalize' );
    push @command, $drop if defined $drop;
    return run_command(
        cmd     => \@command,
        stdin   => $value,
        timeout => 20,
    );
}

subtest 'normalize canonicalizes whitespace' => sub {
    my $result = normalize("  a\t b\n c  ");
    is( $result->{returncode}, 0,         'normalize succeeds' );
    is( $result->{stdout},     "a b c\n", 'tokens are space separated' );
};

subtest 'normalize can omit an exact token' => sub {
    my $result =
      normalize( "a cgroup_disable=memory b\n", 'cgroup_disable=memory' );
    is( $result->{returncode}, 0,       'normalize succeeds' );
    is( $result->{stdout},     "a b\n", 'only the exact token is removed' );
};

subtest 'remove-token edits bootargs values in place' => sub {
    my $directory = new_tempdir('bootargs-');
    my $path      = "$directory/original.dts";
    my $content   = <<'DTS';
/dts-v1/;

/ {
    chosen {
        bootargs = "console=ttyS0 cgroup_disable=memory root=/dev/mmcblk0p2";
    };
    other {
        bootargs = "cgroup_disable=memoryx keep=cgroup_disable=memory";
    };
};
DTS

    write_file( $path, $content );
    chmod 0640, $path or die "cannot chmod $path: $!";

    my $result = run_command(
        cmd     => [ $PERL, $HELPER, 'remove-token', $path ],
        timeout => 20,
    );
    is( $result->{returncode}, 0, 'remove-token succeeds' );

    my $updated = slurp($path);
    like(
        $updated,
        qr{bootargs = "console=ttyS0  root=/dev/mmcblk0p2";},
        'complete token is removed'
    );
    like(
        $updated,
        qr{bootargs = "cgroup_disable=memoryx keep=cgroup_disable=memory";},
        'partial and non-token occurrences are preserved'
    );
    is( ( stat $path )[2] & oct('7777'), oct('640'), 'file mode is preserved' );
};

done_testing();
