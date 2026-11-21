#!/usr/bin/env perl
#
# Standalone release metadata and archive helper. Shell scripts invoke this
# program instead of embedding Perl with -e or a heredoc.
#
# Usage:
#   release-verify.pl json-tag
#   release-verify.pl json-asset-url ASSET_NAME
#   release-verify.pl json-asset-digest ASSET_URL
#   release-verify.pl json-file-digest FILE_NAME
#   release-verify.pl json-validate
#   release-verify.pl tar-extract-all ARCHIVE DEST ROOT LIMIT
#   release-verify.pl tar-extract-entry ARCHIVE DEST ENTRY LIMIT
#   release-verify.pl rename SOURCE DESTINATION
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use Archive::Tar;
use File::Basename         qw(dirname);
use File::Path             qw(make_path);
use File::Temp             qw(tempfile);
use IO::Uncompress::Gunzip qw($GunzipError);
use JSON::PP               ();

my $command = shift @ARGV // '';

sub usage {
    print STDERR <<'EOF';
Usage: release-verify.pl <command> [arguments]

Commands: json-tag, json-asset-url, json-asset-digest, json-file-digest,
json-validate, tar-extract-all, tar-extract-entry, rename
EOF
    exit 2;
}

sub read_json {
    local $/;
    my $raw = <STDIN>;
    die "empty JSON input\n" unless defined $raw && length $raw;
    return JSON::PP::decode_json($raw);
}

sub json_tag {
    my $data = read_json();
    my $tag  = $data->{tag_name};
    die "missing tag_name\n" unless defined $tag && length $tag;
    print $tag, "\n";
}

sub json_asset_url {
    my ($name) = @_;
    usage() unless defined $name && length $name;
    my $data = read_json();
    my @assets =
      grep { ( $_->{name} // '' ) eq $name } @{ $data->{assets} // [] };
    die "expected exactly one asset named $name\n" unless @assets == 1;
    my $url = $assets[0]{browser_download_url};
    die "missing browser_download_url\n"
      unless defined $url && length $url;
    print $url, "\n";
}

sub json_asset_digest {
    my ($url) = @_;
    usage() unless defined $url && length $url;
    my $data   = read_json();
    my @assets = grep { ( $_->{browser_download_url} // '' ) eq $url }
      @{ $data->{assets} // [] };
    die "expected exactly one asset with the requested URL\n"
      unless @assets == 1;
    print $assets[0]{digest} // '', "\n";
}

sub json_file_digest {
    my ($filename) = @_;
    usage() unless defined $filename && length $filename;
    my $data = read_json();
    my @matches;
    for my $release (@$data) {
        for my $file ( @{ $release->{files} // [] } ) {
            push @matches, $file
              if ( $file->{filename} // '' ) eq $filename;
        }
    }
    die "missing unique digest for $filename\n" unless @matches == 1;
    my $digest = $matches[0]{sha256} // '';
    die "invalid digest for $filename\n"
      unless $digest =~ /\A[0-9a-f]{64}\z/;
    print $digest, "\n";
}

sub json_validate {
    read_json();
}

sub archive_iterator {
    my ( $archive, $limit ) = @_;
    my $max_entries = 200_000;
    my $max_tar     = $limit + $max_entries * 1024 + 1024;
    my $compressed  = -s $archive;
    die "invalid compressed archive size\n"
      unless defined $compressed && $compressed > 0 && $compressed <= $max_tar;
    my $gzip = IO::Uncompress::Gunzip->new(
        $archive,
        MultiStream => 1,
        Strict      => 1,
        Transparent => 0,
    ) or die "cannot decode archive: $GunzipError\n";
    my ( $temporary, $path ) = tempfile( UNLINK => 1 );
    binmode $temporary or die "cannot set archive mode: $!\n";
    my $unpacked = 0;

    while (1) {
        my $read = $gzip->read( my $buffer, 64 * 1024 );
        die "cannot decode archive: $GunzipError\n" if $read < 0;
        last unless $read;
        $unpacked += $read;
        die "archive exceeds expansion limit\n" if $unpacked > $max_tar;
        print {$temporary} $buffer or die "cannot stage archive: $!\n";
    }
    close $temporary or die "cannot finish staging archive: $!\n";
    my $next = Archive::Tar->iter($path)
      or die "cannot read staged archive\n";
    my $count = 0;
    return sub {
        local $Archive::Tar::error         = '';
        local $Archive::Tar::MAX_FILE_SIZE = $limit;
        my $entry = $next->();
        die "cannot read staged archive: " . Archive::Tar->error . "\n"
          if Archive::Tar->error;
        die "archive exceeds entry limit\n"
          if $entry && ++$count > $max_entries;
        return $entry;
    };
}

sub validate_member {
    my ( $entry, $root, $seen, $total, $limit ) = @_;
    my $name  = $entry->full_path;
    my @parts = split m{/}, $name;
    die "invalid archive entry\n"
      if !@parts
      || $name =~ m{\A/|//}
      || grep { $_ eq '..' || $_ eq '.' } @parts;
    my $canonical = join '/', @parts;
    die "duplicate archive entry\n" if $seen->{$canonical}++;
    die "unexpected archive root\n"
      if defined $root && length $root && $parts[0] ne $root;
    die "archive contains a link or special file\n"
      unless $entry->is_dir || $entry->is_file;
    $$total += $entry->size;
    die "archive exceeds extraction limit\n" if $$total > $limit;
    return $canonical;
}

sub write_entry {
    my ( $entry, $target ) = @_;
    open my $out, '>:raw', $target or die "cannot create $target: $!\n";
    my $content = $entry->get_content_by_ref;
    print {$out} $$content or die "cannot write $target: $!\n";
    close $out             or die "cannot close $target: $!\n";
    chmod $entry->mode & oct("777"), $target
      or die "cannot set archive entry mode: $!\n";
}

sub extract_all {
    my ( $archive, $destination, $root, $limit ) = @_;
    usage() unless defined $limit && $limit =~ /\A[0-9]+\z/ && $limit > 0;
    my $next = archive_iterator( $archive, $limit );
    my %seen;
    my $total = 0;
    while ( my $entry = $next->() ) {
        my $name   = validate_member( $entry, $root, \%seen, \$total, $limit );
        my $target = "$destination/$name";
        if ( $entry->is_dir ) {
            make_path($target);
            next;
        }
        make_path( dirname($target) );
        write_entry( $entry, $target );
    }
    die "archive does not contain any entries\n" unless keys %seen;
    return 1;
}

sub extract_entry {
    my ( $archive, $destination, $entry_name, $limit ) = @_;
    usage() unless defined $entry_name && length $entry_name;
    usage() unless defined $limit && $limit =~ /\A[0-9]+\z/ && $limit > 0;
    my $next = archive_iterator( $archive, $limit );
    my $match;
    while ( my $entry = $next->() ) {
        next unless $entry->full_path eq $entry_name;
        die "expected exactly one regular $entry_name\n"
          if $match || !$entry->is_file;
        die "invalid entry size\n"
          unless $entry->size > 0 && $entry->size <= $limit;
        $match = $entry;
    }
    die "expected exactly one regular $entry_name\n" unless $match;
    write_entry( $match, $destination );
    return 1;
}

sub rename_path {
    my ( $source, $destination ) = @_;
    usage() unless defined $source && defined $destination;
    rename $source, $destination or die "rename: $!\n";
    return 1;
}

if ( $command eq 'json-tag' ) {
    json_tag();
}
elsif ( $command eq 'json-asset-url' ) {
    json_asset_url( shift @ARGV );
}
elsif ( $command eq 'json-asset-digest' ) {
    json_asset_digest( shift @ARGV );
}
elsif ( $command eq 'json-file-digest' ) {
    json_file_digest( shift @ARGV );
}
elsif ( $command eq 'json-validate' ) {
    json_validate();
}
elsif ( $command eq 'tar-extract-all' ) {
    extract_all(@ARGV);
}
elsif ( $command eq 'tar-extract-entry' ) {
    extract_entry(@ARGV);
}
elsif ( $command eq 'rename' ) {
    rename_path(@ARGV);
}
else {
    usage();
}
