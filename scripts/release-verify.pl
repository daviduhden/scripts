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
use Fcntl                  qw(O_CREAT O_EXCL O_WRONLY);
use File::Basename         qw(dirname);
use IO::Uncompress::Gunzip qw($GunzipError);
use JSON::PP               ();
use POSIX                  qw(_exit);

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

sub stream_gzip_child {
    my ( $archive, $max_tar ) = @_;
    my $gzip = IO::Uncompress::Gunzip->new(
        $archive,
        MultiStream => 1,
        Strict      => 1,
        Transparent => 0,
    ) or die "cannot decode archive: $GunzipError\n";
    binmode STDOUT or die "cannot set archive stream mode: $!\n";
    my $unpacked = 0;

    while (1) {
        my $read = $gzip->read( my $buffer, 64 * 1024 );
        die "cannot decode archive: $GunzipError\n" if $read < 0;
        last unless $read;
        $unpacked += $read;
        die "archive exceeds expansion limit\n" if $unpacked > $max_tar;
        print STDOUT $buffer or die "cannot stream archive: $!\n";
    }
    close STDOUT or die "cannot finish streaming archive: $!\n";
    return 1;
}

# Stream decompressed bytes to the iterator through a pipe. Bound the whole
# stream separately from the member payload quota to allow for TAR overhead.
sub process_archive {
    my ( $archive, $limit, $consume ) = @_;
    my $max_entries = 200_000;
    my $max_tar     = $limit + $max_entries * 1024 + 1024;
    my $compressed  = -s $archive;
    die "invalid compressed archive size\n"
      unless defined $compressed && $compressed > 0 && $compressed <= $max_tar;
    my $child = open my $stream, '-|';
    die "cannot start archive reader: $!\n" unless defined $child;
    if ( !$child ) {
        my $ok = eval { stream_gzip_child( $archive, $max_tar ) };
        print STDERR $@ unless $ok;
        _exit( $ok ? 0 : 1 );
    }
    my $ok = eval {
        binmode $stream or die "cannot set archive read mode: $!\n";
        my $next = Archive::Tar->iter($stream) or die "cannot read archive\n";
        my $count   = 0;
        my $checked = sub {
            local $Archive::Tar::error = '';

            # Newer versions enforce this before reading member data. Retain
            # any stricter upstream cap. Older versions rely on the stream
            # expansion and extraction limits.
            my $default_limit = $Archive::Tar::MAX_FILE_SIZE;
            local $Archive::Tar::MAX_FILE_SIZE = $default_limit
              && $default_limit < $limit ? $default_limit : $limit;
            my $entry = $next->();
            die "cannot read archive: " . Archive::Tar->error . "\n"
              if Archive::Tar->error;
            die "archive exceeds entry limit\n"
              if $entry && ++$count > $max_entries;
            return $entry;
        };
        $consume->($checked);

        # Archive::Tar can stop at the end marker before the gzip trailer.
        # Consume the rest so decompression checks its CRC and total bound.
        while (1) {
            my $size = read $stream, my $discard, 65536;
            die "cannot drain archive stream: $!\n" unless defined $size;
            last                                    unless $size;
        }
        1;
    };
    my $error = $@;

    # Closing the pipe reaps the child on both successful and failed parse
    # paths. An early close also stops a producer blocked on the pipe.
    my $finished = close $stream;
    die $error                           unless $ok;
    die "archive decompression failed\n" unless $finished;
    return 1;
}

# Use the logical path, which includes the USTAR prefix. Track normalized
# names so a second header cannot claim a destination already seen.
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

sub private_directory {
    my ( $path, $disallowed_mode ) = @_;
    $disallowed_mode //= oct('077');
    my @info = lstat $path;
    die "extraction requires an owned private directory\n"
      unless @info
      && -d _
      && $info[4] == $>
      && !( $info[2] & $disallowed_mode );
    return 1;
}

sub ensure_member_directory {
    my ( $root, @parts ) = @_;
    my $path = $root;
    for my $part (@parts) {
        $path .= "/$part";
        if ( !lstat $path ) {
            mkdir $path, oct('755')
              or die "cannot create archive directory: $!\n";
            chmod oct('755'), $path
              or die "cannot set archive directory mode: $!\n";
        }
        private_directory( $path, oct('022') );
    }
    return $path;
}

sub write_entry {
    my ( $entry, $target ) = @_;
    sysopen my $out, $target, O_WRONLY | O_CREAT | O_EXCL, oct('600')
      or die "cannot create unique archive output: $!\n";
    binmode $out or die "cannot set archive output mode: $!\n";
    my $content = $entry->get_content_by_ref;
    print {$out} $$content or die "cannot write $target: $!\n";
    close $out             or die "cannot close $target: $!\n";
    chmod $entry->mode & oct('755'), $target
      or die "cannot set archive entry mode: $!\n";
}

# Members are written as they are read. The caller owns staging cleanup
# after an error, including failures reported after the final member.
sub extract_all {
    my ( $archive, $destination, $root, $limit ) = @_;
    usage() unless defined $limit && $limit =~ /\A[0-9]+\z/ && $limit > 0;
    private_directory($destination);
    my %seen;
    my $total = 0;
    process_archive(
        $archive, $limit,
        sub {
            my ($next) = @_;
            while ( my $entry = $next->() ) {
                my $name =
                  validate_member( $entry, $root, \%seen, \$total, $limit );
                my @parts = split m{/}, $name;
                if ( $entry->is_dir ) {
                    ensure_member_directory( $destination, @parts );
                    next;
                }
                my $leaf      = pop @parts;
                my $directory = ensure_member_directory( $destination, @parts );
                write_entry( $entry, "$directory/$leaf" );
            }
        }
    );
    die "archive does not contain any entries\n" unless keys %seen;
    return 1;
}

# Check the entire stream for duplicate matches and gzip errors before
# creating the selected output.
sub extract_entry {
    my ( $archive, $destination, $entry_name, $limit ) = @_;
    usage() unless defined $entry_name && length $entry_name;
    usage() unless defined $limit && $limit =~ /\A[0-9]+\z/ && $limit > 0;
    private_directory( dirname($destination) );
    my $match;
    process_archive(
        $archive, $limit,
        sub {
            my ($next) = @_;
            while ( my $entry = $next->() ) {
                next unless $entry->full_path eq $entry_name;
                die "expected exactly one regular $entry_name\n"
                  if $match || !$entry->is_file;
                die "invalid entry size\n"
                  unless $entry->size > 0 && $entry->size <= $limit;
                $match = $entry;
            }
        }
    );
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
