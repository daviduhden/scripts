#!/usr/bin/env perl

# Profile the release extractor with synthetic data on a disposable CI tree.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use File::Find  qw(find);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin     qw($Bin);
use POSIX       qw(WNOHANG);
use Time::HiRes qw(sleep time);

my $root    = tempdir( 'release-profile-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $src     = "$root/source";
my $out     = "$root/output";
my $scratch = "$root/scratch";
make_path("$src/release/small");
for my $directory ( $out, $scratch ) {
    mkdir $directory, oct('700') or die "mkdir $directory: $!\n";
}

open my $payload, '>:raw', "$src/release/payload" or die "open payload: $!\n";
my $size = 128 * 1024 * 1024;
seek $payload, $size - 1, 0 or die "seek payload: $!\n";
print {$payload} 'X' or die "write payload: $!\n";
close $payload       or die "close payload: $!\n";

for my $index ( 1 .. 1024 ) {
    open my $file, '>:raw', "$src/release/small/$index"
      or die "open small file: $!\n";
    print {$file} 'entry' or die "write small file: $!\n";
    close $file           or die "close small file: $!\n";
}

my $archive = "$root/site.tar.gz";
system 'tar', '-czf', $archive, '-C', $src, 'release';
die "cannot build synthetic archive\n" if $?;

local $ENV{TMPDIR} = $scratch;
my $start = time();
my $pid   = fork;
die "cannot start verifier profile: $!\n" unless defined $pid;
if ( !$pid ) {
    exec $^X, "$Bin/../scripts/release-verify.pl",
      'tar-extract-all', $archive, $out, 'release', $size + 65536
      or POSIX::_exit(1);
}

my $peak = 0;
my $wait;
while ( ( $wait = waitpid( $pid, WNOHANG ) ) == 0 ) {
    my $bytes = 0;
    find(
        {
            no_chdir => 1,
            wanted   => sub { $bytes += -s _ if -f $File::Find::name; }
        },
        $out,
        $scratch
    );
    $peak = $bytes if $bytes > $peak;
    sleep(0.025);
}
my $status = $?;
die "verification profile failed\n" if $wait != $pid || $status;
die "wrong result in verification profile\n"
  unless -s "$out/release/payload" == $size && -f "$out/release/small/1024";

my $format = "archive_bytes=%d payload_bytes=%d "
  . "peak_sampled_extraction_bytes=%d elapsed_seconds=%.3f\n";
printf $format, -s $archive, $size, $peak, time() - $start;
