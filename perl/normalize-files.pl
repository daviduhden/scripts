#!/usr/bin/env perl

# normalize-files.pl
# - Portable (Windows/OpenBSD/Linux/macOS) recursive normalizer for
#   file and directory names and for text file contents.
# - Three independent operations: rename, encoding -> UTF-8 (no BOM),
#   line endings -> LF.
# - Dry-run by default; only --apply modifies anything.
# - Never overwrites, never follows symlinks by default, never calls
#   destructive git commands, never shells out with concatenated paths.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

package NormalizeFiles;

use 5.010_001;
use strict;
use warnings;

use Encode             qw(decode encode FB_CROAK LEAVE_SRC);
use File::Basename     qw(basename dirname fileparse);
use File::Spec         ();
use File::Temp         qw(tempfile);
use Getopt::Long       qw(GetOptionsFromArray);
use Unicode::Normalize qw(NFKD);
use Pod::Usage         ();
use Digest::SHA        ();
use Cwd                qw(abs_path);
use Fcntl              qw(O_WRONLY O_CREAT O_EXCL);
use Errno              qw(EEXIST);

# UTF-16LE/BE codecs live in Encode::Unicode. Some Perl builds (notably the
# one shipped with OpenBSD) do not autoload them, so request the module
# explicitly. If it is unavailable, UTF-16 files are reported as unsupported
# instead of aborting.
our $HAVE_ENCODE_UNICODE = eval { require Encode::Unicode; 1 } ? 1 : 0;

our $CFG;
our @LOG;

my @MODE_KEYS = qw(rename encoding line_endings);

my @DEFAULT_EXCLUDES =
  qw(.git .svn .hg node_modules vendor target build dist __pycache__);

my %WINDOWS_RESERVED;
$WINDOWS_RESERVED{$_}      = 1 for qw(con prn aux nul);
$WINDOWS_RESERVED{"com$_"} = 1 for 1 .. 9;
$WINDOWS_RESERVED{"lpt$_"} = 1 for 1 .. 9;

my %BINARY_EXT = map { $_ => 1 }
  qw(pdf doc docx xls xlsx ppt pptx odt ods odp zip gz xz 7z rar
  png jpg jpeg gif webp ico exe dll so dylib a o class jar);

my %TEXT_EXT = map { $_ => 1 }
  qw(txt md adoc csv tsv json xml html htm css js ts yml yaml toml
  ini conf properties java kt c h cc cpp hpp rs go py rb pl pm sh ksh
  zsh fish ps1 bat cmd);

my %TRANSLIT = (
    "\x{00A0}" => ' ',
    "\x{00AB}" => '"',
    "\x{00BB}" => '"',
    "\x{2018}" => "'",
    "\x{2019}" => "'",
    "\x{201C}" => '"',
    "\x{201D}" => '"',
    "\x{2010}" => '-',
    "\x{2011}" => '-',
    "\x{2013}" => '-',
    "\x{2014}" => '-',
    "\x{2015}" => '-',
    "\x{2212}" => '-',
    "\x{00B7}" => '-',
    "\x{2022}" => '-',
    "\x{2026}" => '.',
    "\x{00D7}" => 'x',
    "\x{00F7}" => '-',
    "\x{00A9}" => '(c)',
    "\x{00AE}" => '(r)',
    "\x{2122}" => '(tm)',
    "\x{00B0}" => 'deg',
    "\x{00BC}" => '1-4',
    "\x{00BD}" => '1-2',
    "\x{00BE}" => '3-4',
    "\x{00E6}" => 'ae',
    "\x{00C6}" => 'AE',
    "\x{0153}" => 'oe',
    "\x{0152}" => 'OE',
    "\x{00DF}" => 'ss',
    "\x{00F0}" => 'd',
    "\x{00D0}" => 'D',
    "\x{00F8}" => 'o',
    "\x{00D8}" => 'O',
    "\x{00FE}" => 'th',
    "\x{00DE}" => 'Th',
    "\x{0142}" => 'l',
    "\x{0141}" => 'L',
    "\x{0111}" => 'd',
    "\x{0110}" => 'D',
    "\x{0127}" => 'h',
    "\x{0126}" => 'H',
    "\x{0131}" => 'i',
    "\x{0138}" => 'k',
    "\x{014B}" => 'n',
    "\x{014A}" => 'N',
    "\x{0192}" => 'f',
    "\x{00A1}" => '',
    "\x{00BF}" => '',
);

my %TEMP_CACHE;
my %GA_CACHE;
my %EC_CACHE;

####################
# Basic OS helpers #
####################

sub is_windows { return $^O eq 'MSWin32' }
sub is_openbsd { return $^O eq 'openbsd' }

# Best-effort OpenBSD sandbox, mirroring perl/ssh-menu.pl: unveil every path
# the program may touch, lock the veil, then pledge. No-op on other systems.
sub setup_openbsd_sandbox {
    my ( $cfg, $target_raw, $repo_raw ) = @_;
    return unless is_openbsd();

    my $use_git = ( $repo_raw && !$cfg->{no_git} ) ? 1 : 0;

    eval {
        require OpenBSD::Pledge;
        require OpenBSD::Unveil;

        # The binding returns false and sets $! on failure; collect failures
        # instead of silently running with an incomplete veil.
        # See OpenBSD::Unveil(3p).
        my @uv_failed;
        my $unveil = sub {
            my ( $path, $perm ) = @_;
            return 1 unless defined $path && length $path && -d $path;
            return 1 if OpenBSD::Unveil::unveil( $path, $perm );
            push @uv_failed, "$path ($perm)";
            return 0;
        };

        # Perl may lazily load modules (Encode tables, Pod::Text for --help).
        for my $inc (@INC) {
            next if ref $inc;
            $unveil->( $inc, 'r' );
        }

        # The tree being processed, plus repository metadata for git.
        $unveil->( $target_raw, 'rwc' );
        $unveil->( $repo_raw,   'rwc' );

        # The single-source VERSION file next to this program.
        my ( undef, $dir ) = fileparse($0);
        for my $d ( $dir, File::Spec->catdir( $dir, File::Spec->updir ) ) {
            $unveil->( $d, 'r' );
        }

        # --report may point outside the processed tree.
        if ( defined $cfg->{report} ) {
            $unveil->( dirname( $cfg->{report} ), 'rwc' );
        }

        if ($use_git) {
            my %seen;
            for my $path_dir ( File::Spec->path() ) {
                next unless defined $path_dir && length $path_dir;
                next if $seen{$path_dir}++;
                $unveil->( $path_dir, 'rx' );
            }
            $unveil->( $ENV{HOME}, 'r' );
            for my $lib (
                qw(/etc /usr/lib /usr/libexec /usr/local/lib /usr/share /var))
            {
                $unveil->( $lib, 'r' );
            }
        }

        OpenBSD::Unveil::unveil()
          or die "unveil lock failed: $!";

        # The binding takes a list of promises and always adds 'stdio';
        # see OpenBSD::Pledge(3p).
        my @promises = qw(stdio rpath wpath cpath fattr);
        push @promises, qw(exec proc flock unix) if $use_git;
        OpenBSD::Pledge::pledge(@promises) or die "pledge failed: $!";

        die 'unveil failed for: ' . join( ', ', @uv_failed ) . "\n"
          if @uv_failed;
        1;
    } or do {
        emit_error("OpenBSD pledge/unveil setup failed: $@");
    };
    return;
}

# Single source of truth for the project version. The repository keeps it in
# the top-level VERSION file; installed trees ship a copy next to perl/.
# Falls back to a development value only when the file is unavailable.
sub project_version {
    my ( $prog, $dir ) = fileparse($0);
    $prog = '' unless defined $prog;
    $prog =~ s/\.(?:pl|pm)\z//;
    my @cand;
    push @cand, File::Spec->catfile( $dir, $prog . '.version' ) if length $prog;
    push @cand, File::Spec->catfile( $dir, 'VERSION' );
    push @cand, File::Spec->catfile( $dir, File::Spec->updir, 'VERSION' );
    push @cand, File::Spec->catfile( File::Spec->curdir, 'VERSION' );

    for my $cand (@cand) {
        next unless defined $cand && -f $cand;
        my $fh;
        next unless open( $fh, '<:raw', $cand );
        my $line = <$fh>;
        close $fh;
        next unless defined $line;
        $line =~ s/\s+\z//;
        return $line if length $line;
    }
    return '0.0.0-dev';
}

sub version_string {
    return 'normalize-files ' . project_version();
}

sub find_in_path {
    my ($cmd) = @_;
    return undef unless defined $cmd && length $cmd;
    my @exts = ('');
    if ( is_windows() ) {
        my $pathext = $ENV{PATHEXT} // '.COM;.EXE;.BAT;.CMD';
        @exts = split /;/, $pathext;
    }
    for my $dir ( File::Spec->path() ) {
        next unless defined $dir && length $dir;
        for my $ext (@exts) {
            my $cand = File::Spec->catfile( $dir, $cmd . lc $ext );
            return $cand if -f $cand && -x $cand;
            if ( $ext ne lc $ext ) {
                my $cand2 = File::Spec->catfile( $dir, $cmd . $ext );
                return $cand2 if -f $cand2 && -x $cand2;
            }
        }
    }
    return undef;
}

sub _devino {
    my ( $dev, $ino ) = @_;
    return '' unless defined $dev && defined $ino;
    return "$dev:$ino";
}

# Deterministic byte key for sorting/comparison of possibly wide strings.
sub byte_key {
    my ($s) = @_;
    return '' unless defined $s;
    my $c = $s;
    utf8::encode($c) if utf8::is_utf8($c);
    return $c;
}

sub fold_key {
    my ($s) = @_;
    return '' unless defined $s;
    my $c = lc $s;
    utf8::encode($c) if utf8::is_utf8($c);
    return $c;
}

# Printable rendering of a possibly non-decodable native name.
sub disp {
    my ($s) = @_;
    return '' unless defined $s;
    my $copy = $s;
    if ( utf8::is_utf8($copy) ) {
        $copy =~ s/([\x00-\x1F\x7F])/sprintf( '\\x%02X', ord $1 )/ge;
        return $copy;
    }
    $copy =~ s/([^\x20-\x7E])/sprintf( '\\x%02X', ord $1 )/ge;
    return $copy;
}

sub safe_decode {
    my ($bytes) = @_;
    return '' unless defined $bytes;
    my $d = eval { decode( 'UTF-8', $bytes, FB_CROAK | LEAVE_SRC ) };
    return $d if defined $d;
    return decode( 'UTF-8', $bytes, Encode::FB_WARN() );
}

#########
# Names #
#########

sub decode_fs_name {
    my ($name) = @_;
    return ( $name, 1 ) if utf8::is_utf8($name);
    if ( is_windows() ) {
        return ( $name, ( $name =~ /^[\x00-\x7F]*$/ ) ? 1 : 0 );
    }
    my $decoded = eval { decode( 'UTF-8', $name, FB_CROAK | LEAVE_SRC ) };
    return ( $decoded, 1 ) if defined $decoded;
    return ( $name,    0 );
}

sub encode_fs_name {
    my ($chars) = @_;
    return $chars if is_windows();
    return $chars unless utf8::is_utf8($chars);
    return encode( 'UTF-8', $chars );
}

##################
# Normalization  #
##################

sub fold_to_ascii {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/(.)/ exists $TRANSLIT{$1} ? $TRANSLIT{$1} : $1 /gexs;
    my $d = NFKD($s);
    $d =~ s/\p{Mn}+//g;
    return $d;
}

sub split_extension {
    my ($name) = @_;
    return ( $name, '' ) unless defined $name;
    my $i = rindex( $name, '.' );
    return ( $name,                  '' ) if $i <= 0;
    return ( substr( $name, 0, $i ), substr( $name, $i + 1 ) );
}

sub normalize_extension {
    my ($ext) = @_;
    my $e = fold_to_ascii($ext);
    $e = lc $e;
    $e =~ s/[^a-z0-9]+//g;
    return $e;
}

sub normalize_component {
    my ($s) = @_;
    my $t = fold_to_ascii($s);
    $t = lc $t;
    $t =~ s/\s+/-/g;
    $t =~ s/[^a-z0-9._-]+/-/g;
    $t =~ s/-{2,}/-/g;
    $t =~ s/\.{2,}/./g;
    $t =~ s/^-+//;
    $t =~ s/-+$//;
    return $t;
}

sub unreserve {
    my ($result) = @_;
    my $base = $result;
    $base =~ s/\..*$//s;
    $base = lc $base;
    if ( exists $WINDOWS_RESERVED{$base} ) {
        return '_' . $result;
    }
    return $result;
}

sub normalize_basename {
    my ($name) = @_;
    return $name unless defined $name;

    # The transliteration table can map a character to '.' (for example the
    # ellipsis U+2026), which the extension splitter may reinterpret on a
    # later pass. Iterate to a fixed point so the documented property
    # normalize(normalize(x)) == normalize(x) holds.
    my $result = normalize_basename_once($name);
    for ( 1 .. 8 ) {
        my $next = normalize_basename_once($result);
        last if $next eq $result;
        $result = $next;
    }
    return $result;
}

sub normalize_basename_once {
    my ($name) = @_;
    return $name unless defined $name;
    return $name if $name eq '' || $name eq '.' || $name eq '..';
    my ( $stem, $ext ) = split_extension($name);
    my $nstem = normalize_component($stem);
    my $next  = normalize_extension($ext);
    my $result;
    if ( $next ne '' ) {
        $result = ( $nstem eq '' ? 'unnamed' : $nstem ) . ".$next";
    }
    else {
        $result = $nstem;
    }
    $result =~ s/\.{2,}/./g;
    $result =~ s/[.\-]+$//;
    $result = 'unnamed' if $result eq '';
    return unreserve($result);
}

sub extension_of {
    my ($name) = @_;
    return '' unless defined $name;
    my $i = rindex( $name, '.' );
    return '' if $i <= 0 || $i == length($name) - 1;
    return lc substr( $name, $i + 1 );
}

sub is_excluded {
    my ( $cfg, $char_name, $rel_char, $is_dir ) = @_;
    my $lc = lc $char_name;
    return 1 if $lc eq '.git';
    if ( $cfg->{default_excludes} && $is_dir ) {
        for my $d (@DEFAULT_EXCLUDES) {
            return 1 if $lc eq $d;
        }
    }
    if ($is_dir) {
        for my $d ( @{ $cfg->{excludes} } ) {
            return 1 if $lc eq lc $d;
        }
    }
    for my $re ( @{ $cfg->{compiled_excludes} } ) {
        return 1 if $rel_char =~ /$re/;
    }
    return 0;
}

############
# CLI      #
############

sub default_config {
    return {
        apply              => 0,
        want               => { rename => 1, encoding => 1, line_endings => 1 },
        recursive          => 1,
        excludes           => [],
        exclude_patterns   => [],
        compiled_excludes  => [],
        windows_scripts_lf => 0,
        verbose            => 0,
        quiet              => 0,
        report             => undef,
        follow_symlinks    => 0,
        preserve_times     => 0,
        assume_encoding    => undef,
        assume_enc_name    => undef,
        verify             => 0,
        no_git             => 0,
        default_excludes   => 1,
        max_depth          => 0,
        max_bytes          => 64 * 1024 * 1024,
        help               => 0,
        version            => 0,
        usage_error        => undef,
    };
}

sub parse_args {
    my ($argv) = @_;
    my $cfg = default_config();

    my ( $r_opt, $e_opt, $l_opt );
    my @bad;

    local $SIG{__WARN__} = sub { push @bad, $_[0] };

    Getopt::Long::Configure(qw(no_auto_abbrev no_ignore_case));
    my $ok = GetOptionsFromArray(
        $argv,
        'apply'               => sub { $cfg->{apply} = 1 },
        'dry-run'             => sub { $cfg->{apply} = 0 },
        'rename!'             => \$r_opt,
        'encoding!'           => \$e_opt,
        'line-endings!'       => \$l_opt,
        'recursive!'          => sub { $cfg->{recursive} = $_[1] },
        'exclude=s@'          => $cfg->{excludes},
        'exclude-pattern=s@'  => $cfg->{exclude_patterns},
        'windows-scripts-lf!' => sub { $cfg->{windows_scripts_lf} = $_[1] },
        'follow-symlinks!'    => sub { $cfg->{follow_symlinks}    = $_[1] },
        'preserve-times!'     => sub { $cfg->{preserve_times}     = $_[1] },
        'verify!'             => sub { $cfg->{verify}             = $_[1] },
        'no-git'              => sub { $cfg->{no_git}             = 1 },
        'default-excludes!'   => sub { $cfg->{default_excludes}   = $_[1] },
        'assume-encoding=s'   => \$cfg->{assume_encoding},
        'max-depth=i'         => \$cfg->{max_depth},
        'max-bytes=i'         => \$cfg->{max_bytes},
        'verbose|v+'          => \$cfg->{verbose},
        'quiet|q'             => \$cfg->{quiet},
        'report=s'            => \$cfg->{report},
        'help|h'              => \$cfg->{help},
        'version|V'           => \$cfg->{version},
    );

    if ( !$ok ) {
        $cfg->{usage_error} = 'invalid command line options';
        return ( $cfg, [] );
    }

    my $any_positive = grep { defined $_ && $_ } ( $r_opt, $e_opt, $l_opt );
    if ($any_positive) {
        for my $m (@MODE_KEYS) { $cfg->{want}{$m} = 0 }
    }
    $cfg->{want}{rename}       = $r_opt if defined $r_opt;
    $cfg->{want}{encoding}     = $e_opt if defined $e_opt;
    $cfg->{want}{line_endings} = $l_opt if defined $l_opt;

    for my $re ( @{ $cfg->{exclude_patterns} } ) {
        my $compiled = eval { qr/$re/ };
        if ( !defined $compiled ) {
            $cfg->{usage_error} = "invalid --exclude-pattern: $re";
            return ( $cfg, [] );
        }
        push @{ $cfg->{compiled_excludes} }, $compiled;
    }

    if ( defined $cfg->{assume_encoding} && length $cfg->{assume_encoding} ) {
        my $enc = Encode::find_encoding( $cfg->{assume_encoding} );
        if ( !$enc ) {
            $cfg->{usage_error} =
              "unknown --assume-encoding: $cfg->{assume_encoding}";
            return ( $cfg, [] );
        }
        $cfg->{assume_enc_name} = $enc->name;
    }
    else {
        $cfg->{assume_encoding} = undef;
    }

    if ( $cfg->{max_depth} < 0 ) {
        $cfg->{usage_error} = '--max-depth must be >= 0';
        return ( $cfg, [] );
    }
    if ( $cfg->{max_bytes} < 0 ) {
        $cfg->{usage_error} = '--max-bytes must be >= 0';
        return ( $cfg, [] );
    }
    if ( $cfg->{verbose} && $cfg->{quiet} ) {
        $cfg->{usage_error} = '--verbose and --quiet are mutually exclusive';
        return ( $cfg, [] );
    }

    my @rest = @$argv;
    if ( @rest > 1 ) {
        $cfg->{usage_error} = 'at most one directory argument is allowed';
        return ( $cfg, [] );
    }
    return ( $cfg, \@rest );
}

############
# Output   #
############

sub emit {
    my ($line) = @_;
    $line = '' unless defined $line;
    push @LOG, $line;
    print $line, "\n" unless $CFG && $CFG->{quiet};
    return;
}

sub emit_verbose {
    my ( $cfg, $line ) = @_;
    emit($line) if $cfg->{verbose};
    return;
}

sub emit_error {
    my ($line) = @_;
    $line = '' unless defined $line;
    push @LOG, $line;
    print STDERR "normalize-files: $line\n";
    return;
}

sub emit_block {
    my ( $header, @lines ) = @_;
    emit($header);
    for my $l (@lines) { emit("  $l") }
    emit('');
    return;
}

sub reset_report {
    return {
        scanned_files    => 0,
        scanned_dirs     => 0,
        renames_proposed => 0,
        renames_applied  => 0,
        utf8_valid       => 0,
        converted_utf8   => 0,
        ambiguous        => 0,
        lf_already       => 0,
        crlf_detected    => 0,
        cr_detected      => 0,
        mixed_detected   => 0,
        eol_converted    => 0,
        binary_skipped   => 0,
        collisions       => 0,
        errors           => 0,
        warnings         => 0,
        interventions    => 0,
        pending          => 0,
    };
}

sub report_summary {
    my ($R) = @_;
    emit('');
    emit( 'Scanned files: ' . $R->{scanned_files} );
    emit( 'Scanned directories: ' . $R->{scanned_dirs} );
    emit('');
    emit( 'Renames proposed: ' . $R->{renames_proposed} );
    emit( 'Renames applied: ' . $R->{renames_applied} );
    emit('');
    emit( 'UTF-8 already valid: ' . $R->{utf8_valid} );
    emit( 'Converted to UTF-8: ' . $R->{converted_utf8} );
    emit( 'Ambiguous encodings: ' . $R->{ambiguous} );
    emit('');
    emit( 'LF already: ' . $R->{lf_already} );
    emit( 'CRLF detected: ' . $R->{crlf_detected} );
    emit( 'CR detected: ' . $R->{cr_detected} );
    emit( 'Mixed EOL detected: ' . $R->{mixed_detected} );
    emit( 'EOL conversions applied: ' . $R->{eol_converted} );
    emit('');
    emit( 'Binary files skipped: ' . $R->{binary_skipped} );
    emit('');
    emit( 'Name collisions: ' . $R->{collisions} );
    emit( 'Errors: ' . $R->{errors} );
    emit( 'Warnings: ' . $R->{warnings} );
    emit('');
    return;
}

##############
# Traversal  #
##############

sub sortkey { return byte_key( $_[0] ) }

sub stat_key {
    my ($path) = @_;
    my @st = stat($path);
    return @st ? _devino( @st[ 0, 1 ] ) : '';
}

sub scan_tree {
    my ( $cfg, $root_raw ) = @_;
    my @nodes;
    my %occupied;
    my ( $root_char, $root_ok ) = decode_fs_name($root_raw);
    my %visited;
    my $rkey = stat_key($root_raw);
    $visited{$rkey} = 1 if length $rkey;

    my @stack = ( { raw => $root_raw, rel => '', depth => 0 } );
    while ( my $d = pop @stack ) {
        my $dh;
        if ( !opendir( $dh, $d->{raw} ) ) {
            emit_error( 'cannot open directory: ' . disp( $d->{raw} ) );
            $CFG->{_result}{errors}++ if $CFG->{_result};
            next;
        }
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        @names = sort { sortkey($a) cmp sortkey($b) } @names;
        $occupied{ $d->{raw} } ||= [];

        for my $raw_name (@names) {
            my ( $cname, $ok ) = decode_fs_name($raw_name);
            next if $cname =~ /^\.norm-(?:tmp|bak)-/;
            push @{ $occupied{ $d->{raw} } },
              { raw => $raw_name, char => $cname, ok => $ok };

            my $raw_path = File::Spec->catfile( $d->{raw}, $raw_name );
            my @st       = lstat($raw_path);
            next unless @st;
            my $is_link = ( -l _ ) ? 1 : 0;
            my $is_dir  = ( -d _ && !$is_link ) ? 1 : 0;
            my $is_reg  = ( -f _ && !$is_link ) ? 1 : 0;

            my $rel = $d->{rel} eq '' ? $cname : $d->{rel} . '/' . $cname;
            next if is_excluded( $cfg, $cname, $rel, $is_dir );

            push @nodes,
              {
                raw_path   => $raw_path,
                raw_name   => $raw_name,
                char_name  => $cname,
                name_ok    => $ok,
                rel        => $rel,
                parent_raw => $d->{raw},
                parent_rel => $d->{rel},
                depth      => $d->{depth},
                is_dir     => $is_dir,
                is_link    => $is_link,
                is_reg     => $is_reg,
              };

            if ( $is_dir
                || ( $is_link && $cfg->{follow_symlinks} && -d $raw_path ) )
            {
                next unless $cfg->{recursive};
                next
                  if $cfg->{max_depth}
                  && $d->{depth} + 1 > $cfg->{max_depth};
                my $key = stat_key($raw_path);
                if ( $key ne '' && $visited{$key} ) {
                    $CFG->{_result}{warnings}++ if $CFG->{_result};
                    emit_verbose( $cfg,
                        'SKIP (already visited): ' . disp($rel) );
                    next;
                }
                $visited{$key} = 1 if $key ne '';
                push @stack,
                  { raw => $raw_path, rel => $rel, depth => $d->{depth} + 1 };
            }
        }
    }
    return ( \@nodes, \%occupied, $root_char, $root_ok );
}

#####################
# Rename planning   #
#####################

sub plan_renames {
    my ( $cfg, $nodes, $occupied ) = @_;
    my @ops;
    my @collisions;
    my %by_parent;
    for my $n (@$nodes) {
        push @{ $by_parent{ $n->{parent_raw} } }, $n;
    }

    for my $parent ( keys %by_parent ) {
        my @items;
        my %node_by_rawname;
        for my $n ( @{ $by_parent{$parent} } ) {
            $node_by_rawname{ $n->{raw_name} } = $n;
        }
        for my $o ( @{ $occupied->{$parent} || [] } ) {
            my $n = $node_by_rawname{ $o->{raw} };
            my ( $final, $is_node );
            if ( $n && $n->{name_ok} ) {
                $final   = normalize_basename( $o->{char} );
                $is_node = 1;
            }
            else {
                $final   = $o->{char};
                $is_node = 0;
            }
            push @items,
              {
                raw     => $o->{raw},
                cur     => $o->{char},
                final   => $final,
                node    => $n,
                is_node => $is_node,
                ok      => $o->{ok},
              };
        }

        my %group;
        for my $it (@items) {
            push @{ $group{ fold_key( $it->{final} ) } }, $it;
        }
        my %collide;
        for my $k ( keys %group ) {
            next if @{ $group{$k} } <= 1;
            for my $it ( @{ $group{$k} } ) { $collide{ $it->{raw} } = 1 }
            push @collisions,
              {
                parent_rel => $by_parent{$parent}[0]{parent_rel},
                target     => $group{$k}[0]{final},
                names      => [ map { $_->{cur} } @{ $group{$k} } ],
              };
        }

        for my $it (@items) {
            next unless $it->{is_node};
            next unless $it->{ok};
            next if $collide{ $it->{raw} };
            next if $it->{final} eq $it->{cur};
            my $n = $it->{node};
            push @ops,
              {
                parent_raw => $parent,
                parent_rel => $n->{parent_rel},
                old_raw    => $n->{raw_name},
                old_char   => $n->{char_name},
                new_char   => $it->{final},
                new_raw    => encode_fs_name( $it->{final} ),
                rel        => $n->{rel},
                is_dir     => $n->{is_dir},
                depth      => $n->{depth},
              };
        }
    }

    @ops = sort {
             $b->{depth} <=> $a->{depth}
          || ( $a->{parent_rel} cmp $b->{parent_rel} )
          || ( string_cmp( $a->{old_char}, $b->{old_char} ) )
    } @ops;

    @collisions = sort {
             ( $a->{parent_rel} cmp $b->{parent_rel} )
          || ( string_cmp( $a->{target}, $b->{target} ) )
    } @collisions;

    return ( \@ops, \@collisions );
}

sub string_cmp {
    my ( $a, $b ) = @_;
    return byte_key($a) cmp byte_key($b);
}

# Reserve a unique temporary name by creating it exclusively (O_EXCL), which
# closes the check-then-use race a plain lstat() would leave open. The caller
# either renames over the reserved placeholder (Unix) or releases it first
# (Windows, whose rename() will not replace an existing file).
sub reserve_temp_name {
    my ( $dir, $prefix ) = @_;
    $prefix = '.norm-tmp-' unless defined $prefix;
    for my $try ( 1 .. 1000 ) {
        my $name = sprintf(
            '%s%d-%d-%08x%08x',
            $prefix, $$, $try,
            int( rand( 2**31 ) ),
            int( rand( 2**31 ) )
        );
        my $p = File::Spec->catfile( $dir, $name );
        my $fh;
        if ( sysopen( $fh, $p, O_WRONLY | O_CREAT | O_EXCL, 0600 ) ) {
            close $fh;
            return $p;
        }
        next if $! == EEXIST;
        my @st = lstat($p);
        return $p if !@st;
    }
    die "cannot allocate a temporary name in $dir";
}

# Move a source to a freshly reserved temporary name in the same directory.
sub stage_to_temp {
    my ( $src, $dir ) = @_;
    my $tmp = reserve_temp_name($dir);
    unlink $tmp if is_windows();
    if ( rename( $src, $tmp ) ) {
        return $tmp;
    }
    eval { unlink $tmp };
    return undef;
}

# Returns 1 when the rename happened and any requested verification passed,
# -1 when the rename happened but verification failed, and 0 when the rename
# itself failed. In both the 1 and -1 cases the destination exists, so the
# caller records an undo entry for a possible group rollback.
sub rename_op {
    my ( $cfg, $op, $src, $dst, $R, $label ) = @_;
    my $hash_before;
    if ( $cfg->{verify} && $op->{is_dir} == 0 ) {
        $hash_before = sha256_file($src);
    }
    if ( !rename( $src, $dst ) ) {
        $R->{errors}++;
        emit_error( "rename failed ($label): " . disp( $op->{rel} ) . " : $!" );
        return 0;
    }
    $R->{renames_applied}++;
    if ( defined $hash_before ) {
        my $hash_after = sha256_file($dst);
        if ( !defined $hash_after || $hash_after ne $hash_before ) {
            $R->{errors}++;
            emit_error(
                'integrity check failed after rename: ' . disp( $op->{rel} ) );
            return -1;
        }
    }
    return 1;
}

sub execute_renames {
    my ( $cfg, $ops, $R ) = @_;
    my %seen;
    my @parents;
    for my $op (@$ops) {
        my $k = $op->{parent_raw};
        next if $seen{$k}++;
        push @parents, $k;
    }
    for my $parent (@parents) {
        my @group = grep { $_->{parent_raw} eq $parent } @$ops;
        execute_rename_group( $cfg, $parent, \@group, $R );
    }
    return;
}

# Best-effort rollback: reverse completed renames, newest first, but never
# clobber a name that is occupied again. This is not a filesystem transaction;
# it only restores what we can prove we moved.
sub unwind_renames {
    my ( $undo, $R ) = @_;
    for my $entry ( reverse @$undo ) {
        my ( $from, $to ) = @$entry;
        next unless -e $from || -l $from;
        if ( -e $to || -l $to ) {
            $R->{warnings}++;
            emit_error( 'rollback skipped, target exists: ' . disp($to) );
            next;
        }
        if ( rename( $from, $to ) ) {
            $R->{renames_applied}-- if $R->{renames_applied} > 0;
        }
        else {
            $R->{warnings}++;
            emit_error( 'rollback rename failed: ' . disp($to) . " : $!" );
        }
    }
    return;
}

sub execute_rename_group {
    my ( $cfg, $parent, $group, $R ) = @_;
    my ( @direct, @stage );

    for my $op (@$group) {
        my $target = File::Spec->catfile( $parent, $op->{new_raw} );
        my @st     = lstat($target);
        if   (@st) { push @stage,  $op }
        else       { push @direct, $op }
    }

    my @undo   = ();
    my $failed = 0;

    for my $op (@stage) {
        my $src = File::Spec->catfile( $parent, $op->{old_raw} );
        my $tmp = stage_to_temp( $src, $parent );
        if ( defined $tmp ) {
            $op->{tmp} = $tmp;
        }
        else {
            $op->{failed} = 1;
            $failed = 1;
            $R->{errors}++;
            emit_error(
                'staging rename failed: ' . disp( $op->{rel} ) . " : $!" );
        }
    }

    for my $op (@direct) {
        next if $op->{failed};
        my $src = File::Spec->catfile( $parent, $op->{old_raw} );
        my $dst = File::Spec->catfile( $parent, $op->{new_raw} );
        my @st  = lstat($dst);
        if (@st) {
            $op->{failed} = 1;
            $failed = 1;
            $R->{errors}++;
            emit_error( 'refusing to overwrite: ' . disp( $op->{rel} ) );
            next;
        }
        my $rc = rename_op( $cfg, $op, $src, $dst, $R, 'direct' );
        if ( $rc == 0 ) {
            $failed = 1;
        }
        else {
            push @undo, [ $dst, $src ];
            $failed = 1 if $rc < 0;
        }
    }

    for my $op (@stage) {
        next if $op->{failed};
        my $src = File::Spec->catfile( $parent, $op->{old_raw} );
        my $dst = File::Spec->catfile( $parent, $op->{new_raw} );
        my @st  = lstat($dst);
        if (@st) {
            $failed = 1;
            $R->{errors}++;
            emit_error( 'refusing to overwrite: ' . disp( $op->{rel} ) );
            push @undo, [ $op->{tmp}, $src ];
            next;
        }
        my $rc = rename_op( $cfg, $op, $op->{tmp}, $dst, $R, 'staged' );
        if ( $rc == 0 ) {
            $failed = 1;
            push @undo, [ $op->{tmp}, $src ];
        }
        else {
            push @undo, [ $dst, $src ];
            $failed = 1 if $rc < 0;
        }
    }

    unwind_renames( \@undo, $R ) if $failed;
    return;
}

sub sha256_file {
    my ($path) = @_;
    my $fh;
    return undef unless open( $fh, '<:raw', $path );
    my $sha = Digest::SHA->new(256);
    my $buf;
    while ( read( $fh, $buf, 1048576 ) ) { $sha->add($buf) }
    close $fh;
    return $sha->hexdigest;
}

#############################
# Text/binary classification #
#############################

sub looks_text {
    my ($b) = @_;
    return 1 if $b =~ /^\xEF\xBB\xBF/;
    return 1 if $b =~ /^\xFF\xFE/ || $b =~ /^\xFE\xFF/;

    # UTF-32 BOMs contain NUL bytes; recognize them before the NUL test
    # so detect_encoding() can report them consistently with UTF-32LE.
    return 1 if $b =~ /^\x00\x00\xFE\xFF/ || $b =~ /^\xFF\xFE\x00\x00/;
    return 0 if $b =~ /\x00/;
    my $len = length $b;
    return 1 if $len == 0;
    my $ctrl = () = $b =~ /[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]/g;
    return 0 if $ctrl > $len * 0.30;
    return 1;
}

sub detect_encoding {
    my ( $bytes, $cfg ) = @_;
    if ( substr( $bytes, 0, 4 ) eq "\x00\x00\xFE\xFF" ) {
        return ( 'utf-32be', 1 );
    }
    if ( substr( $bytes, 0, 4 ) eq "\xFF\xFE\x00\x00" ) {
        return ( 'utf-32le', 1 );
    }
    if ( substr( $bytes, 0, 3 ) eq "\xEF\xBB\xBF" ) {
        return ( 'utf-8-bom', 1 );
    }
    if ( substr( $bytes, 0, 2 ) eq "\xFF\xFE" ) {
        return ( $HAVE_ENCODE_UNICODE ? 'utf-16le' : 'unicode-unsupported', 1 );
    }
    if ( substr( $bytes, 0, 2 ) eq "\xFE\xFF" ) {
        return ( $HAVE_ENCODE_UNICODE ? 'utf-16be' : 'unicode-unsupported', 1 );
    }
    my $valid_utf8 =
      eval { decode( 'UTF-8', $bytes, FB_CROAK | LEAVE_SRC ); 1 };
    return ( 'utf-8', 1 ) if $valid_utf8;
    if ( defined $cfg->{assume_encoding} ) { return ( 'assumed',          1 ) }
    if ( $bytes =~ /[\x80-\x9F]/ )         { return ( 'ambiguous-cp1252', 0 ) }
    return ( 'ambiguous-latin1', 0 );
}

sub decode_known {
    my ( $bytes, $enc, $cfg ) = @_;
    my $b = $bytes;
    if ( $enc eq 'utf-8-bom' ) {
        $b = substr( $b, 3 );
        return decode( 'UTF-8', $b, FB_CROAK | LEAVE_SRC );
    }
    if ( $enc eq 'utf-16le' ) {
        $b = substr( $b, 2 );
        return decode( 'UTF-16LE', $b, FB_CROAK | LEAVE_SRC );
    }
    if ( $enc eq 'utf-16be' ) {
        $b = substr( $b, 2 );
        return decode( 'UTF-16BE', $b, FB_CROAK | LEAVE_SRC );
    }
    if ( $enc eq 'assumed' ) {
        return decode( $cfg->{assume_encoding}, $b, FB_CROAK | LEAVE_SRC );
    }
    return decode( 'UTF-8', $b, FB_CROAK | LEAVE_SRC );
}

sub encode_result {
    my ( $text, $enc, $cfg, $want_utf8 ) = @_;
    return encode( 'UTF-8', $text )                  if $want_utf8;
    return encode( 'UTF-8', $text )                  if $enc eq 'utf-8';
    return "\xEF\xBB\xBF" . encode( 'UTF-8', $text ) if $enc eq 'utf-8-bom';
    return "\xFF\xFE" . encode( 'UTF-16LE', $text )  if $enc eq 'utf-16le';
    return "\xFE\xFF" . encode( 'UTF-16BE', $text )  if $enc eq 'utf-16be';
    return encode( $cfg->{assume_encoding}, $text )  if $enc eq 'assumed';
    die "internal error: encode_result unknown encoding '$enc'";
}

###################
# EOL handling    #
###################

sub detect_eol {
    my ($text) = @_;
    my $crlf   = () = $text =~ /\r\n/g;
    my $lf     = () = $text =~ /(?<!\r)\n/g;
    my $cr     = () = $text =~ /\r(?!\n)/g;
    my $kinds  = ( $crlf ? 1 : 0 ) + ( $lf ? 1 : 0 ) + ( $cr ? 1 : 0 );
    my $type;
    if    ( $kinds == 0 ) { $type = 'none' }
    elsif ( $kinds > 1 )  { $type = 'mixed' }
    elsif ($crlf)         { $type = 'crlf' }
    elsif ($cr)           { $type = 'cr' }
    else                  { $type = 'lf' }
    return { type => $type, crlf => $crlf, lf => $lf, cr => $cr };
}

sub eol_normalize {
    my ( $text, $target ) = @_;
    my $n = $text;
    $n =~ s/\r\n/\n/g;
    $n =~ s/\r/\n/g;
    if    ( $target eq 'crlf' ) { $n =~ s/\n/\r\n/g }
    elsif ( $target eq 'cr' )   { $n =~ s/\n/\r/g }
    return $n;
}

sub eol_ok {
    my ( $text, $target ) = @_;
    return 1 if $target eq 'lf' && $text !~ /\r/;
    return 1
      if $target eq 'crlf' && $text !~ /(?<!\r)\n/ && $text !~ /\r(?!\n)/;
    return 1 if $target eq 'cr' && $text !~ /\n/ && $text !~ /\r\n/;
    return 0;
}

sub eol_policy_for {
    my ( $cfg, $node, $attrs, $ec ) = @_;
    return 'binary' if $attrs->{binary};
    my $ext           = extension_of( $node->{char_name} );
    my $is_win_script = ( $ext eq 'bat' || $ext eq 'cmd' );
    my $target        = 'lf';
    if ( $is_win_script && !$cfg->{windows_scripts_lf} ) {
        $target = 'preserve';
    }
    $target = $ec->{end_of_line} if defined $ec->{end_of_line};
    $target = $attrs->{eol}      if defined $attrs->{eol};
    return $target;
}

############################
# .gitattributes/.editorconfig
############################

sub glob_regex {
    my ($pat) = @_;
    my $re    = '';
    my $i     = 0;
    my $n     = length $pat;
    while ( $i < $n ) {
        my $c = substr( $pat, $i, 1 );
        if ( $c eq '*' ) {
            if ( substr( $pat, $i, 2 ) eq '**' ) {
                $i += 2;
                if ( substr( $pat, $i, 1 ) eq '/' ) {
                    $re .= '(?:.*/)?';
                    $i++;
                }
                else { $re .= '.*' }
            }
            else { $re .= '[^/]*'; $i++ }
        }
        elsif ( $c eq '?' ) { $re .= '[^/]'; $i++ }
        elsif ( $c eq '[' ) {
            my $j = index( $pat, ']', $i + 1 );
            if ( $j < 0 ) { $re .= '\[', $i++ }
            else {
                my $cls = substr( $pat, $i + 1, $j - $i - 1 );
                $cls =~ s/^!/^/;
                $re .= '[' . $cls . ']';
                $i = $j + 1;
            }
        }
        elsif ( $c eq '{' ) {
            my $j = index( $pat, '}', $i + 1 );
            if ( $j < 0 ) { $re .= '\{', $i++ }
            else {
                my $alt  = substr( $pat, $i + 1, $j - $i - 1 );
                my @opts = split /,/, $alt, -1;
                $re .= '(?:' . join( '|', map { glob_regex($_) } @opts ) . ')';
                $i = $j + 1;
            }
        }
        elsif ( index( '.^$+()|\\', $c ) >= 0 ) {
            $re .= '\\' . $c;
            $i++;
        }
        else { $re .= $c; $i++ }
    }
    return $re;
}

sub glob_match {
    my ( $pat, $path ) = @_;
    return 0 unless defined $pat && length $pat;
    my $p        = $pat;
    my $anchored = ( $p =~ m{/} ) ? 1 : 0;
    $p =~ s{^/}{};
    my $re = glob_regex($p);

    # A malformed pattern (for example "[]" or "[!]") can produce an invalid
    # character class; treat it as a non-match instead of dying mid-run.
    my $matched = eval {
        if   ($anchored) { $path =~ m{^$re$}       ? 1 : 0 }
        else             { $path =~ m{(?:^|/)$re$} ? 1 : 0 }
    };
    return 0 if $@;
    return $matched ? 1 : 0;
}

sub path_rel_posix {
    my ( $base_raw, $path_raw ) = @_;
    my $r = File::Spec->abs2rel( File::Spec->rel2abs($path_raw),
        File::Spec->rel2abs($base_raw) );
    $r =~ s{\\}{/}g;
    my ($chars) = decode_fs_name($r);
    return $chars;
}

sub read_attr_rules {
    my ( $file, $base ) = @_;
    my @rules;
    my $fh;
    return \@rules unless open( $fh, '<:raw', $file );
    while ( my $line = <$fh> ) {
        $line = eval { decode( 'UTF-8', $line, FB_CROAK | LEAVE_SRC ) }
          // decode( 'UTF-8', $line, Encode::FB_WARN() );
        $line =~ s/\r?\n\z//;
        next if $line =~ /^\s*\z/;
        next if $line =~ /^\s*#/;
        my @fields = split ' ', $line;
        my $pat    = shift @fields;
        next unless defined $pat;
        my %set;
        my %unset;
        my %val;

        for my $a (@fields) {
            if    ( $a =~ /^-(.+)\z/ )      { $unset{$1} = 1 }
            elsif ( $a =~ /^(.+?)=(.+)\z/ ) { $val{$1}   = $2 }
            else                            { $set{$a}   = 1 }
        }
        push @rules,
          {
            base  => $base,
            pat   => $pat,
            set   => \%set,
            unset => \%unset,
            val   => \%val
          };
    }
    close $fh;
    return \@rules;
}

sub chain_dirs {
    my ( $top_raw, $dir_raw ) = @_;
    my $rel = File::Spec->abs2rel( File::Spec->rel2abs($dir_raw),
        File::Spec->rel2abs($top_raw) );
    $rel =~ s{\\}{/}g;
    my @dirs = ($top_raw);
    my $cur  = $top_raw;
    return @dirs if $rel eq '' || $rel eq '.';
    return @dirs if $rel =~ m{^\.\.(?:/|$)};
    for my $part ( split m{/}, $rel ) {
        next if $part eq '' || $part eq '.';
        $cur = File::Spec->catfile( $cur, $part );
        push @dirs, $cur;
    }
    return @dirs;
}

sub gitattr_rules_for {
    my ( $repo_raw, $dir_raw ) = @_;
    return $GA_CACHE{$dir_raw} if exists $GA_CACHE{$dir_raw};
    my @rules;
    for my $d ( chain_dirs( $repo_raw, $dir_raw ) ) {
        my $ga = File::Spec->catfile( $d, '.gitattributes' );
        if ( -f $ga ) {
            push @rules, @{ read_attr_rules( $ga, $d ) };
        }
    }
    return $GA_CACHE{$dir_raw} = \@rules;
}

sub gitattr_for {
    my ( $repo_raw, $path_raw ) = @_;
    my $dir   = dirname($path_raw);
    my $rules = gitattr_rules_for( $repo_raw, $dir );
    my %eff;
    for my $r (@$rules) {
        my $rel = path_rel_posix( $r->{base}, $path_raw );
        next unless glob_match( $r->{pat}, $rel );
        if ( $r->{set}{binary} || $r->{unset}{text} ) { $eff{binary} = 1 }
        if ( $r->{set}{text} )                        { $eff{binary} = 0 }
        if ( exists $r->{val}{eol} ) {
            my $v = lc $r->{val}{eol};
            $eff{eol} = $v if $v eq 'lf' || $v eq 'crlf' || $v eq 'cr';
        }
    }
    return \%eff;
}

sub editorconfig_rules_for {
    my ( $top_raw, $dir_raw ) = @_;
    return $EC_CACHE{$dir_raw} if exists $EC_CACHE{$dir_raw};
    my @rules;
    for my $d ( chain_dirs( $top_raw, $dir_raw ) ) {
        my $ec = File::Spec->catfile( $d, '.editorconfig' );
        next unless -f $ec;
        my $fh;
        next unless open( $fh, '<:raw', $ec );
        my $section;
        while ( my $line = <$fh> ) {
            $line = eval { decode( 'UTF-8', $line, FB_CROAK | LEAVE_SRC ) }
              // decode( 'UTF-8', $line, Encode::FB_WARN() );
            $line =~ s/\r?\n\z//;
            $line =~ s/^\s+//;
            $line =~ s/\s+\z//;
            next if $line eq '';
            next if $line =~ /^[#;]/;
            if ( $line =~ /^\[(.+)\]\z/ ) {
                $section = $1;
                push @rules, { base => $d, pat => $section, props => {} };
                next;
            }
            next unless defined $section;
            if ( $line =~ /^([^=]+?)\s*=\s*(.+)\z/ ) {
                my ( $k, $v ) = ( lc $1, lc $2 );
                $rules[-1]{props}{$k} = $v;
            }
        }
        close $fh;
    }
    return $EC_CACHE{$dir_raw} = \@rules;
}

sub editorconfig_for {
    my ( $top_raw, $path_raw ) = @_;
    my $dir   = dirname($path_raw);
    my $rules = editorconfig_rules_for( $top_raw, $dir );
    my %eff;
    for my $r (@$rules) {
        my $rel = path_rel_posix( $r->{base}, $path_raw );
        next unless glob_match( $r->{pat}, $rel );
        for my $k ( keys %{ $r->{props} } ) {
            $eff{$k} = $r->{props}{$k};
        }
    }
    return \%eff;
}

########################
# Atomic file writing  #
########################

sub safe_replace {
    my ( $tmp, $target ) = @_;
    if ( rename( $tmp, $target ) ) { return 1 }
    return 0 unless is_windows();
    return 0 unless -e $target;
    my $dir = dirname($target);
    my $bak = reserve_temp_name( $dir, '.norm-bak-' );
    unlink $bak;
    return 0 unless rename( $target, $bak );

    if ( rename( $tmp, $target ) ) {
        unlink $bak;
        return 1;
    }
    rename( $bak, $target );
    return 0;
}

sub atomic_write {
    my ( $cfg, $path_raw, $bytes, $R ) = @_;
    my @before     = stat($path_raw);
    my $want_inode = @before ? _devino( @before[ 0, 1 ] ) : '';

    my ( $base, $dir ) = fileparse($path_raw);
    my ( $fh, $tmp );
    my $ok = eval {
        ( $fh, $tmp ) =
          tempfile( '.norm-tmp-XXXXXXXX', DIR => $dir, UNLINK => 0 );
        1;
    };
    if ( !$ok ) {
        $R->{errors}++;
        emit_error( 'cannot create temporary file in ' . disp($dir) . ": $@" );
        return 0;
    }
    my $write_ok = eval {
        binmode( $fh, ':raw' );
        print {$fh} $bytes;
        close $fh;
        1;
    };
    if ( !$write_ok ) {
        $R->{errors}++;
        emit_error( 'write failed for ' . disp($path_raw) . ": $@" );
        eval { close $fh };
        unlink $tmp;
        return 0;
    }

    my $size = -s $tmp;
    if ( !defined $size || $size != length($bytes) ) {
        $R->{errors}++;
        emit_error( 'short write for ' . disp($path_raw) );
        unlink $tmp;
        return 0;
    }

    if (@before) {
        chmod( $before[2] & 07777, $tmp );
        if ( $cfg->{preserve_times} ) {
            utime( $before[8], $before[9], $tmp );
        }
    }

    if ( $want_inode ne '' ) {
        my @now = stat($path_raw);
        if ( !@now || _devino( @now[ 0, 1 ] ) ne $want_inode ) {
            $R->{errors}++;
            emit_error( 'file changed during processing: ' . disp($path_raw) );
            unlink $tmp;
            return 0;
        }
    }

    if ( !safe_replace( $tmp, $path_raw ) ) {
        $R->{errors}++;
        emit_error( 'atomic replace failed for ' . disp($path_raw) . ": $!" );
        unlink $tmp;
        return 0;
    }
    return 1;
}

########################
# Content processing   #
########################

sub read_sniff {
    my ( $path, $n ) = @_;
    my $fh;
    return undef unless open( $fh, '<:raw', $path );
    my $buf = '';
    read( $fh, $buf, $n );
    close $fh;
    return $buf;
}

sub read_all {
    my ($path) = @_;
    my $fh;
    return undef unless open( $fh, '<:raw', $path );
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub process_content {
    my ( $cfg, $nodes, $target_raw, $repo_raw, $R ) = @_;

    for my $n (@$nodes) {
        next if $n->{is_dir};
        next if $n->{is_link};
        next unless $n->{is_reg};

        if ( !$n->{name_ok} ) {
            $R->{warnings}++;
            emit_verbose( $cfg,
                'NOTE (name is not valid UTF-8, rename skipped): '
                  . disp( $n->{rel} ) );
        }

        my $base_lc = lc $n->{char_name};
        if ( $base_lc eq '.gitattributes' || $base_lc eq '.editorconfig' ) {
            emit_verbose( $cfg,
                'SKIP (configuration file, never modified): '
                  . disp( $n->{rel} ) );
            next;
        }

        my $ext = extension_of( $n->{char_name} );
        my $attrs =
          $repo_raw ? gitattr_for( $repo_raw, $n->{raw_path} ) : {};
        my $ec = editorconfig_for( $target_raw, $n->{raw_path} );

        if ( $BINARY_EXT{$ext} || $attrs->{binary} ) {
            $R->{binary_skipped}++;
            emit_verbose( $cfg, 'BINARY' );
            emit_verbose( $cfg, '  ' . disp( $n->{rel} ) );
            emit_verbose( $cfg, '  content unchanged' );
            emit_verbose( $cfg, '' );
            next;
        }

        my $sniff = read_sniff( $n->{raw_path}, 8192 );
        if ( !defined $sniff ) {
            $R->{errors}++;
            emit_error( 'cannot read: ' . disp( $n->{rel} ) );
            next;
        }

        if ( !looks_text($sniff) ) {
            $R->{binary_skipped}++;
            emit_verbose( $cfg, 'BINARY' );
            emit_verbose( $cfg, '  ' . disp( $n->{rel} ) );
            emit_verbose( $cfg, '  content unchanged' );
            emit_verbose( $cfg, '' );
            next;
        }

        my $size = -s $n->{raw_path};
        if ( defined $size && $size > $cfg->{max_bytes} ) {
            $R->{warnings}++;
            emit_verbose( $cfg,
                    'SKIP (too large, > '
                  . $cfg->{max_bytes}
                  . ' bytes): '
                  . disp( $n->{rel} ) );
            next;
        }

        my $bytes = read_all( $n->{raw_path} );
        if ( !defined $bytes ) {
            $R->{errors}++;
            emit_error( 'cannot read: ' . disp( $n->{rel} ) );
            next;
        }

        my ( $enc, $certain ) = detect_encoding( $bytes, $cfg );

        if ( $enc eq 'utf-32le' || $enc eq 'utf-32be' ) {
            $R->{warnings}++;
            $R->{interventions}++;
            emit_block(
                'AMBIGUOUS',
                disp( $n->{rel} ),
                "UTF-32 is not converted automatically (unsupported)"
            );
            next;
        }

        if ( $enc eq 'unicode-unsupported' ) {
            $R->{warnings}++;
            $R->{interventions}++;
            emit_block(
                'AMBIGUOUS',
                disp( $n->{rel} ),
                "UTF-16 codecs are unavailable in this Perl build"
            );
            next;
        }

        if ( !$certain ) {
            $R->{ambiguous}++;
            $R->{warnings}++;
            $R->{interventions}++;
            my $hint =
              $enc eq 'ambiguous-cp1252'
              ? 'possibly Windows-1252/CP-125x'
              : 'possibly ISO-8859-1/Latin-1';
            emit_block(
                'AMBIGUOUS',
                disp( $n->{rel} ),
                "encoding cannot be determined reliably ($hint)"
            );
            next;
        }

        my $text;
        my $dec_ok = eval {
            $text = decode_known( $bytes, $enc, $cfg );
            1;
        };
        if ( !$dec_ok ) {
            $R->{errors}++;
            emit_error( 'decode failed: ' . disp( $n->{rel} ) . ": $@" );
            next;
        }

        if ( $text =~ /\x00/ ) {
            $R->{binary_skipped}++;
            $R->{warnings}++;
            emit_verbose( $cfg, 'BINARY' );
            emit_verbose( $cfg, '  ' . disp( $n->{rel} ) );
            emit_verbose( $cfg, '  content unchanged (NUL after decoding)' );
            emit_verbose( $cfg, '' );
            next;
        }

        $R->{utf8_valid}++ if $enc eq 'utf-8';

        my $canon_assume =
          defined $cfg->{assume_enc_name} ? lc $cfg->{assume_enc_name} : '';
        my $assumed_is_utf8 =
          ( $enc eq 'assumed' && $canon_assume =~ /^utf-?8$/ );

        my $do_enc = $cfg->{want}{encoding};
        my $do_eol = $cfg->{want}{line_endings};

        my $enc_change = 0;
        if ( $do_enc && $enc ne 'utf-8' && !$assumed_is_utf8 ) {
            $enc_change = 1;
        }

        my $policy = eol_policy_for( $cfg, $n, $attrs, $ec );

        my $det = detect_eol($text);
        if    ( $det->{type} eq 'crlf' )  { $R->{crlf_detected}++ }
        elsif ( $det->{type} eq 'cr' )    { $R->{cr_detected}++ }
        elsif ( $det->{type} eq 'mixed' ) { $R->{mixed_detected}++ }
        else                              { $R->{lf_already}++ }

        my $new_text    = $text;
        my $eol_change  = 0;
        my $eol_skipped = 0;
        if ( $do_eol && $policy eq 'preserve' ) {
            $eol_skipped = 1;
        }
        elsif ( $do_eol && $policy ne 'binary' && $det->{type} ne 'none' ) {
            my $target =
              $policy eq 'crlf' ? 'crlf' : $policy eq 'cr' ? 'cr' : 'lf';
            $new_text   = eol_normalize( $text, $target );
            $eol_change = ( $new_text ne $text ) ? 1 : 0;
        }

        my $changed = ( $enc_change || $eol_change ) ? 1 : 0;

        if ( $changed && !-w $n->{raw_path} ) {
            $R->{warnings}++;
            $R->{interventions}++;
            emit_error( 'read-only file, not modified: ' . disp( $n->{rel} ) );
            next;
        }

        my $utf8_out_expected = ( $enc_change || $enc eq 'utf-8' ) ? 1 : 0;

        my $bytes_out = $bytes;
        if ( $changed || ( $utf8_out_expected && $do_enc ) ) {
            $bytes_out =
              eval { encode_result( $new_text, $enc, $cfg, $enc_change ); };
            if ( !defined $bytes_out ) {
                $R->{errors}++;
                emit_error( 'encode failed: ' . disp( $n->{rel} ) . ": $@" );
                next;
            }
        }

        if ($changed) {
            if ($utf8_out_expected) {
                my $valid = eval {
                    decode( 'UTF-8', $bytes_out, FB_CROAK | LEAVE_SRC );
                    1;
                };
                if ( !$valid ) {
                    $R->{errors}++;
                    emit_error(
                        'result is not valid UTF-8: ' . disp( $n->{rel} ) );
                    next;
                }
                if ( substr( $bytes_out, 0, 3 ) eq "\xEF\xBB\xBF" ) {
                    $R->{errors}++;
                    emit_error(
                        'result still has a BOM: ' . disp( $n->{rel} ) );
                    next;
                }
            }
            if ( $do_eol && $policy ne 'binary' && $policy ne 'preserve' ) {
                if ( !eol_ok( $new_text, $policy ) ) {
                    $R->{errors}++;
                    emit_error( 'EOL validation failed: ' . disp( $n->{rel} ) );
                    next;
                }
            }
        }

        if ($enc_change) {
            $R->{converted_utf8}++;
            my $from =
                $enc eq 'utf-8-bom' ? 'UTF-8 BOM'
              : $enc eq 'utf-16le'  ? 'UTF-16LE'
              : $enc eq 'utf-16be'  ? 'UTF-16BE'
              :                       $cfg->{assume_enc_name};
            emit_block( 'ENCODING', disp( $n->{rel} ), "$from -> UTF-8" );
        }

        if ($eol_change) {
            $R->{eol_converted}++;
            my $from = $det->{type} eq 'mixed' ? 'mixed' : uc $det->{type};
            my $target =
              $policy eq 'crlf' ? 'CRLF' : $policy eq 'cr' ? 'CR' : 'LF';
            emit_block( 'EOL', disp( $n->{rel} ), "$from -> $target" );
        }

        if ( $eol_skipped && $det->{type} ne 'none' && $det->{type} ne 'lf' ) {
            emit_verbose( $cfg,
                    'EOL (preserved Windows script): '
                  . disp( $n->{rel} ) . ' ('
                  . uc( $det->{type} )
                  . ')' );
        }

        if ( $changed && !$cfg->{apply} ) {
            $R->{pending}++;
        }

        if ( $changed && $cfg->{apply} ) {
            if ( atomic_write( $cfg, $n->{raw_path}, $bytes_out, $R ) ) {
                $R->{pending}++;
            }
        }
    }
    return;
}

#############
# Git       #
#############

sub repo_root_for {
    my ($dir_raw) = @_;
    my $dir = abs_path($dir_raw);
    return undef unless defined $dir && length $dir;
    while (1) {
        my $g = File::Spec->catfile( $dir, '.git' );
        return $dir if -e $g;
        my $parent = abs_path( File::Spec->catdir( $dir, File::Spec->updir ) );
        return undef unless defined $parent && length $parent;
        return undef if $parent eq $dir;
        $dir = $parent;
    }
}

sub git_capture {
    my (@args) = @_;
    my $git = find_in_path('git');
    return ( undef, 'git not found' ) unless $git;
    my $pid = open( my $fh, '-|', $git, @args );
    return ( undef, 'cannot run git' ) unless defined $pid;
    local $/;
    my $out = <$fh>;
    close $fh;
    return ( defined $out ? $out : '', undef );
}

sub git_report_before {
    my ( $cfg, $repo_raw, $R ) = @_;
    return if $cfg->{quiet};
    my ( $out, $err ) = git_capture( '-C', $repo_raw, 'status', '--porcelain' );
    if ( !defined $out ) {
        emit_verbose( $cfg, "GIT: $err" );
        return;
    }
    if ( length $out ) {
        $R->{warnings}++;
        emit('GIT: repository has pre-existing changes; they are left untouched'
        );
        for my $line ( split /\n/, safe_decode($out) ) {
            emit( '  ' . $line ) if length $line;
        }
        emit('');
    }
    else {
        emit_verbose( $cfg, 'GIT: working tree clean before changes' );
    }
    return;
}

sub git_report_after {
    my ( $cfg, $repo_raw ) = @_;
    return if $cfg->{quiet};
    emit('GIT: status after changes');
    my ( $st, $err1 ) = git_capture( '-C', $repo_raw, 'status', '--short' );
    emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode( $st // '' );
    emit('');
    my ( $chk, $err2 ) = git_capture( '-C', $repo_raw, 'diff', '--check' );
    if ( defined $chk && length $chk ) {
        emit('GIT: diff --check reported problems:');
        emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode($chk);
    }
    else {
        emit('GIT: diff --check: no whitespace errors');
    }
    emit('');
    my ( $stat, $err3 ) = git_capture( '-C', $repo_raw, 'diff', '--stat' );
    if ( defined $stat && length $stat ) {
        emit('GIT: diff --stat');
        emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode($stat);
        emit('');
    }
    return;
}

############
# Report   #
############

sub write_report {
    my ( $cfg, $R ) = @_;
    return unless defined $cfg->{report};
    my $fh;
    if ( !open( $fh, '>:raw', $cfg->{report} ) ) {
        warn "normalize-files: cannot write report $cfg->{report}: $!\n";
        $R->{errors}++;
        return;
    }
    my $text = join( "\n", @LOG ) . "\n";
    print {$fh} encode( 'UTF-8', $text );
    close $fh;
    return;
}

########
# Main #
########

sub run {
    my (@argv) = @_;
    srand();

    my ( $cfg, $rest ) = parse_args( \@argv );
    if ( $cfg->{usage_error} ) {
        print STDERR 'normalize-files: ' . $cfg->{usage_error} . "\n";
        Pod::Usage::pod2usage(
            -exitval => 3,
            -verbose => 0,
            -output  => \*STDERR
        );
    }
    if ( $cfg->{help} ) {
        Pod::Usage::pod2usage( -exitval => 0, -verbose => 2 );
    }
    if ( $cfg->{version} ) {
        print version_string(), "\n";
        exit 0;
    }

    $CFG = $cfg;
    eval {
        binmode( STDOUT, ':encoding(UTF-8)' );
        binmode( STDERR, ':encoding(UTF-8)' );
        1;
    } or do {
        eval { binmode( STDOUT, ':utf8' ); binmode( STDERR, ':utf8' ); };
    };

    my $target = $rest->[0];
    $target = '.' unless defined $target && length $target;
    my $target_raw = File::Spec->rel2abs($target);
    my @tst        = stat($target_raw);
    if ( !@tst || !( -d _ ) ) {
        print STDERR "normalize-files: not a directory: "
          . disp($target) . "\n";
        exit 3;
    }

    my $R = reset_report();
    $CFG->{_result} = $R;

    my $repo_raw = repo_root_for($target_raw);
    setup_openbsd_sandbox( $cfg, $target_raw, $repo_raw );
    if ( $repo_raw && !$cfg->{no_git} ) {
        git_report_before( $cfg, $repo_raw, $R );
    }

    my ( $nodes, $occupied, $root_char ) = scan_tree( $cfg, $target_raw );
    $R->{scanned_files} = scalar grep     { !$_->{is_dir} } @$nodes;
    $R->{scanned_dirs}  = 1 + scalar grep { $_->{is_dir} } @$nodes;

    if ( $cfg->{want}{encoding} || $cfg->{want}{line_endings} ) {
        process_content( $cfg, $nodes, $target_raw, $repo_raw, $R );
    }

    my ( $ops, $collisions ) = ( [], [] );
    if ( $cfg->{want}{rename} ) {
        ( $ops, $collisions ) = plan_renames( $cfg, $nodes, $occupied );
        $R->{renames_proposed} = scalar @$ops;
        for my $c (@$collisions) {
            $R->{collisions}++;
            $R->{interventions}++;
            my @names = map { disp($_) } @{ $c->{names} };
            emit_block( 'COLLISION', @names, '-> ' . disp( $c->{target} ) );
        }
        for my $op (@$ops) {
            my $new_rel =
              ( $op->{parent_rel} eq '' )
              ? $op->{new_char}
              : $op->{parent_rel} . '/' . $op->{new_char};
            emit_block(
                'RENAME',
                '"' . disp( $op->{old_char} ) . '"',
                '-> "' . disp($new_rel) . '"'
            );
        }
        $R->{pending} += scalar @$ops;
        if ( $cfg->{apply} ) {
            execute_renames( $cfg, $ops, $R );
        }
    }

    if ( $cfg->{apply} && $repo_raw && !$cfg->{no_git} ) {
        git_report_after( $cfg, $repo_raw );
    }

    report_summary($R);

    my $pending_work =
      ( $R->{renames_proposed} +
          ( $cfg->{want}{encoding}     ? ( $R->{converted_utf8} ) : 0 ) +
          ( $cfg->{want}{line_endings} ? ( $R->{eol_converted} )  : 0 ) );

    if ( $pending_work == 0 && $R->{collisions} == 0 ) {
        emit('No changes required');
    }

    write_report( $cfg, $R );

    my $code = 0;
    if    ( $R->{errors} )                        { $code = 2 }
    elsif ( $R->{interventions} )                 { $code = 2 }
    elsif ( !$cfg->{apply} && $pending_work > 0 ) { $code = 1 }
    exit $code;
}

package main;

NormalizeFiles::run(@ARGV) unless caller;

__END__

=head1 NAME

normalize-files.pl - portable recursive normalizer for file names and text files

=head1 SYNOPSIS

  normalize-files.pl [options] [directory]

  # Dry-run (default): report what would change, modify nothing
  perl normalize-files.pl --dry-run .

  # Normalize file and directory names only
  perl normalize-files.pl --rename .

  # Encoding and line endings only
  perl normalize-files.pl --encoding --line-endings .

  # Apply everything
  perl normalize-files.pl --apply --rename --encoding --line-endings .

=head1 DESCRIPTION

B<normalize-files.pl> walks a directory tree and performs up to three
independent, conservative operations:

=over 4

=item 1. Filename normalization

Names (files and directories) are folded to lowercase ASCII where reasonable,
spaces become C<->, runs of separators collapse, and only C<[a-z0-9._-]> is
kept. Extensions are lowercased. Windows reserved names (C<CON>, C<PRN>,
C<AUX>, C<NUL>, C<COM1..9>, C<LPT1..9>, including with an extension) are
neutralized with a leading C<_>.

=item 2. Encoding conversion

Text files are converted to UTF-8 without BOM. Auto-conversion only happens
for encodings that can be determined reliably: strict UTF-8, UTF-8 with BOM,
and UTF-16LE/BE with BOM. Any other non-UTF-8 byte stream is reported as
ambiguous and left untouched unless C<--assume-encoding> is given.

=item 3. Line ending normalization

LF, CRLF, CR and mixed line endings are detected. Text files are normalized to
LF by default. C<.bat> and C<.cmd> files keep CRLF unless
C<--windows-scripts-lf> is used. C<.gitattributes> (C<eol=>, C<text>,
C<binary>) and C<.editorconfig> (C<end_of_line>) policies are respected.

=back

The program is a dry-run unless C<--apply> is given.

=head1 OPTIONS

=over 4

=item B<--dry-run>

Report changes without writing anything (default).

=item B<--apply>

Actually perform the selected operations.

=item B<--rename> / B<--encoding> / B<--line-endings>

Select operations. If at least one positive selector is given, only the
selected operations run. With no selector, all three run.

=item B<--no-rename> / B<--no-encoding> / B<--no-line-endings>

Disable individual operations while keeping the rest.

=item B<--recursive> / B<--no-recursive>

Recurse into subdirectories (default: recursive).

=item B<--exclude DIR>

Skip directories with this name. May be repeated.

=item B<--exclude-pattern REGEX>

Skip entries whose path (relative to the root, using C</>) matches REGEX.
May be repeated.

=item B<--windows-scripts-lf>

Also normalize C<.bat>/C<.cmd> files to LF.

=item B<--verbose>, B<-v>

Print per-file detail, including skipped binary files.

=item B<--quiet>, B<-q>

Suppress normal output (errors still go to STDERR).

=item B<--report FILE>

Write the report as UTF-8 text with LF endings.

=item B<--follow-symlinks>

Follow symbolic links to directories. Off by default; loops are detected.

=item B<--preserve-times>

Preserve the modification time of rewritten files.

=item B<--assume-encoding ENC>

Treat non-UTF-8 text as ENC and convert it, instead of reporting it as
ambiguous. ENC is any name understood by L<Encode>.

=item B<--verify>

Verify renamed files with SHA-256, and validate every conversion before
replacing the original.

=item B<--no-git>

Do not run C<git> or report Git state. Repository files such as
C<.gitattributes> are still read to respect existing line-ending policy.

=item B<--default-excludes> / B<--no-default-excludes>

Toggle the default excluded directory list. C<.git> is always excluded.

=item B<--max-depth N>

Limit recursion depth (0 means unlimited).

=item B<--max-bytes N>

Skip content conversion for files larger than N bytes (default 64 MiB).

=item B<--help>, B<--version>

Show help or version.

=back

=head1 FILENAME NORMALIZATION

The normalization is a pure function: C<normalize(normalize(x)) ==
normalize(x)>. It never produces an empty name, C<.>, C<..>, a name ending in
a space or a dot, or a Windows reserved name.

  "Unit 3 - Future Forms Revision.pdf" -> "unit-3-future-forms-revision.pdf"
  "Solución recuperación programación.txt" -> "solucion-recuperacion-programacion.txt"
  "Tema 9- POO Avanzada(4).pdf" -> "tema-9-poo-avanzada-4.pdf"

Non-UTF-8 file names on Unix are left unrenamed; they are noted under
C<--verbose> when content processing runs.

=head1 ENCODING POLICY

Auto-converted: strict UTF-8 (no change), UTF-8 with BOM (BOM removed),
UTF-16LE/BE with BOM (decoded to UTF-8). Detected but I<not> auto-converted:
legacy single-byte encodings (possibly Windows-1252 or ISO-8859-1),
ambiguous, always reported. Decoding uses strict validation; no substitution
character is ever introduced silently. Content that only looks like text
because of a UTF-16 BOM but decodes to C<NUL> characters is treated as
binary and left untouched.

=head1 LINE ENDING POLICY

Default target is LF for text files. C<.bat>/C<.cmd> keep CRLF unless
C<--windows-scripts-lf>. C<.gitattributes> dominates C<.editorconfig>, which
dominates the default. Files classified as binary are never rewritten.

=head1 SAFETY

=over 4

=item * Dry-run by default; only C<--apply> writes.

=item * No overwrites: rename collisions are detected and the involved renames
are skipped (content changes may still have been applied beforehand).

=item * Case-only renames and rename cycles are handled with unique temporary
names inside the same directory.

=item * Content is written to a temporary file in the same directory, verified,
then replaced atomically (with a portable fallback on Windows). Temporary
names are reserved exclusively, so they cannot collide with user files.

=item * Read-only files are reported and skipped; their read-only attribute is
never cleared. C<.gitattributes> and C<.editorconfig> are never modified.

=item * A directory whose renames partially fail is rolled back as far as it
can be done safely, and no existing file is ever overwritten.

=item * Symbolic links are not followed by default; their targets are never
modified. Symlink loops are detected when following.

=item * No shell is used; Git is invoked with list-form arguments.

=back

=head1 GIT

If the target lives in a Git repository and C<git> is available, the working
tree state is reported with C<git status --porcelain> before changes and with
C<git status --short>, C<git diff --check> and C<git diff --stat> after
applying. No destructive Git command (reset, clean, commit, push) is ever run.
C<--no-git> disables all Git interaction. Git is never required.

=head1 PLATFORM NOTES

Runs on Windows 10 and Windows 11 with Strawberry Perl, and on OpenBSD, Linux
and macOS. Symbolic link tests are skipped on Windows. File names are handled
as character strings; on Unix, names that are not valid UTF-8 are left
unrenamed. Ownership, ACLs and extended attributes are not preserved or
copied. Long paths are used as given; no C<\\?> prefix is added.

On OpenBSD the program unveils the processed tree (read/write/create), the
repository metadata when git is used, the VERSION file and I<@INC>, then
pledges C<stdio rpath wpath cpath fattr> (plus C<exec proc flock unix> when
git may run). Sandbox setup is best-effort and does not abort the run.

=head1 EXIT STATUS

  0  success, nothing to do (or applied cleanly)
  1  dry-run: changes are needed
  2  errors, name collisions, or cases requiring intervention
  3  usage error

=head1 DEPENDENCIES

Core modules only: L<Encode>, L<Unicode::Normalize>, L<File::Spec>,
L<File::Basename>, L<File::Temp>, L<Getopt::Long>, L<Pod::Usage>,
L<Digest::SHA>. L<Text::Unidecode> and L<Encode::Guess> are intentionally
not required.

=head1 EXAMPLES

Windows PowerShell:

  perl .\normalize-files.pl --dry-run .
  perl .\normalize-files.pl --apply --rename --encoding --line-endings .

Unix / OpenBSD / Linux / macOS:

  perl ./normalize-files.pl --dry-run .
  perl ./normalize-files.pl --apply --rename --encoding --line-endings .

=head1 LIMITATIONS

=over 4

=item * C<.gitattributes>/C<.editorconfig> glob support is a practical subset
(no numeric ranges like C<{2..5}>).

=item * UTF-16 without a BOM is treated as binary and skipped.

=item * Legacy encodings are not guessed automatically by design.

=item * Whole files are read into memory for conversion; use C<--max-bytes> to
bound this.

=item * Permission bits are preserved, but ownership, ACLs and xattrs are not.

=back

=cut
