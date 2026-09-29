#!/usr/bin/env perl

# test-normalize-files.pl
# - Regression tests for perl/normalize-files.pl.
# - Covers name normalization, collisions, case-only renames, cycles,
#   encoding detection/conversion, line endings, binary safety, symlinks,
#   dry-run/apply and idempotence.
# - All work happens in temporary directories; user files are never touched.
# - Usage: ./test-normalize-files.pl
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;
use utf8;

use Encode     qw(encode decode);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my ( $vol, $dirs ) = File::Spec->splitpath( File::Spec->rel2abs($0) );
my $SCRIPT = File::Spec->catfile( $dirs, '..', 'perl', 'normalize-files.pl' );
-f $SCRIPT or BAIL_OUT("cannot find perl/normalize-files.pl relative to $0");
require $SCRIPT;

my $WINDOWS = ( $^O eq 'MSWin32' ) ? 1 : 0;

# ---------------------------------------------------------------- helpers

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub write_raw {
    my ( $path, $data ) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $data;
    close $fh;
    return;
}

sub run_capture {
    my (@args) = @_;
    open my $fh, '-|', $^X, $SCRIPT, @args or die "cannot run script: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    return ( $? >> 8, defined $out ? $out : '' );
}

sub newtmp {
    return tempdir( 'nf-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
}

# ------------------------------------------------------ unit: normalization

subtest 'normalize_basename: required examples' => sub {
    is(
        NormalizeFiles::normalize_basename(
            'Unit 3 - Future Forms Revision.pdf'),
        'unit-3-future-forms-revision.pdf',
        'spaces and dash'
    );
    is(
        NormalizeFiles::normalize_basename(
            'Solución recuperación programación.txt'),
        'solucion-recuperacion-programacion.txt',
        'accents'
    );
    is( NormalizeFiles::normalize_basename('Tema 9- POO Avanzada(4).pdf'),
        'tema-9-poo-avanzada-4.pdf', 'symbols' );
    done_testing();
};

subtest 'normalize_basename: individual rules' => sub {
    is( NormalizeFiles::normalize_basename('already-safe.txt'),
        'already-safe.txt', 'valid ASCII stays' );
    is( NormalizeFiles::normalize_basename('ABC.TXT'),
        'abc.txt', 'lowercases base and extension' );
    is( NormalizeFiles::normalize_basename('Año.txt'), 'ano.txt', 'enye' );
    is( NormalizeFiles::normalize_basename('a   b.txt'),
        'a-b.txt', 'several spaces collapse' );
    is( NormalizeFiles::normalize_basename('  lead.txt'),
        'lead.txt', 'leading spaces' );
    is( NormalizeFiles::normalize_basename('trail.txt  '),
        'trail.txt', 'trailing spaces' );
    is( NormalizeFiles::normalize_basename('weird*?:"<>|name.txt'),
        'weird-name.txt', 'problematic shell chars' );
    is( NormalizeFiles::normalize_basename('---a---b---.txt'),
        'a-b.txt', 'dash runs trimmed and collapsed' );
    is( NormalizeFiles::normalize_basename('-leading.txt'),
        'leading.txt', 'leading dash removed' );
    is( NormalizeFiles::normalize_basename('trailing-.txt'),
        'trailing.txt', 'trailing dash removed' );
    is( NormalizeFiles::normalize_basename('.gitignore'),
        '.gitignore', 'dotfile preserved' );
    is( NormalizeFiles::normalize_basename('..'), '..', 'dotdot untouched' );
    is( NormalizeFiles::normalize_basename('.'),  '.',  'dot untouched' );
    done_testing();
};

subtest 'normalize_basename: Windows reserved names' => sub {
    is( NormalizeFiles::normalize_basename('CON'),     '_con',     'CON' );
    is( NormalizeFiles::normalize_basename('con.txt'), '_con.txt', 'con.txt' );
    is( NormalizeFiles::normalize_basename('aux.pdf'), '_aux.pdf', 'aux.pdf' );
    is( NormalizeFiles::normalize_basename('LPT9'),    '_lpt9',    'LPT9' );
    is( NormalizeFiles::normalize_basename('Com1.log'),
        '_com1.log', 'Com1.log' );
    is( NormalizeFiles::normalize_basename('_con.txt'),
        '_con.txt', 'already neutralized is stable' );
    done_testing();
};

subtest 'normalize_basename is idempotent' => sub {
    my @names = (
        'foo.txt',        'A B C.TXT',
        'Solución.txt',   'Año.md',
        'CON',            'aux.pdf',
        '---x---.txt',    '.hidden',
        'a(1).b(2).c',    'Tema 9- POO Avanzada(4).pdf',
        'ñandú ñoño Ñ.Ö', 'x.tar.gz',
        '####',           '    ',
        '...',            '..a..b..'
    );
    for my $n (@names) {
        my $once  = NormalizeFiles::normalize_basename($n);
        my $twice = NormalizeFiles::normalize_basename($once);
        is( $twice, $once, "idempotent: <$n> -> <$once>" );
        ok( length($once), "non-empty result for <$n>" );
        unlike( $once, qr{[/\\]}, "no path separator in <$once>" );
        isnt( $once, '.',  "not dot for <$n>" );
        isnt( $once, '..', "not dotdot for <$n>" );
    }
    done_testing();
};

# ------------------------------------------------- integration: dry-run/apply

subtest 'dry-run never modifies and reports exit 1' => sub {
    my $tmp = newtmp();
    my $old = File::Spec->catfile( $tmp, 'Hello World.txt' );
    write_raw( $old, "content\n" );
    my ( $rc, $out ) = run_capture( '--dry-run', '--rename', $tmp );
    is( $rc, 1, 'exit 1 when changes are needed in dry-run' );
    ok( -e $old, 'original name kept' );
    ok( !-e File::Spec->catfile( $tmp, 'hello-world.txt' ), 'no new name' );
    like( $out, qr/RENAME/, 'reports a rename' );
    done_testing();
};

subtest 'apply performs the rename' => sub {
    my $tmp = newtmp();
    my $old = File::Spec->catfile( $tmp, 'Hello World.txt' );
    write_raw( $old, "content\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 0, 'exit 0 after applying' );
    ok( !-e $old,                                          'old name gone' );
    ok( -e File::Spec->catfile( $tmp, 'hello-world.txt' ), 'new name present' );
    done_testing();
};

subtest 'ASCII name already valid: no changes required' => sub {
    my $tmp = newtmp();
    write_raw( File::Spec->catfile( $tmp, 'already-safe.txt' ), "x\n" );
    my ( $rc, $out ) = run_capture( '--dry-run', '--rename', $tmp );
    is( $rc, 0, 'exit 0' );
    like( $out, qr/No changes required/, 'reports nothing to do' );
    done_testing();
};

subtest 'collisions are detected and skipped (case-sensitive)' => sub {
    my $tmp = newtmp();
    my $a   = File::Spec->catfile( $tmp, 'Foo.txt' );
    my $b   = File::Spec->catfile( $tmp, 'foo.txt' );
    write_raw( $a, "A\n" );
    write_raw( $b, "B\n" );
    my ( $rc, $out ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 2, 'exit 2: requires intervention' );
    like( $out, qr/COLLISION/, 'collision reported' );
    ok( -e $a && -e $b, 'both files kept, nothing overwritten' );
    is( slurp_raw($a), "A\n", 'content A intact' );
    is( slurp_raw($b), "B\n", 'content B intact' );
    done_testing();
};

subtest 'case-insensitive collision (different files)' => sub {
    my $tmp = newtmp();
    my $a   = File::Spec->catfile( $tmp, 'README.TXT' );
    my $b   = File::Spec->catfile( $tmp, 'readme.txt' );
    write_raw( $a, "A\n" );
    write_raw( $b, "B\n" );
    my ( $rc, $out ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 2, 'treated as conflict on any platform' );
    ok( -e $a && -e $b, 'both kept' );
    done_testing();
};

subtest 'case-only rename' => sub {
    my $tmp = newtmp();
    my $old = File::Spec->catfile( $tmp, 'README.TXT' );
    write_raw( $old, "hello\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 0, 'exit 0' );
    ok( -e File::Spec->catfile( $tmp, 'readme.txt' ),
        'lowercase name present' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'readme.txt' ) ),
        "hello\n", 'content preserved' );
    done_testing();
};

subtest 'nested directories are renamed deepest-first' => sub {
    my $tmp = newtmp();
    my $sub = File::Spec->catdir( $tmp, 'Tema 1', 'Sub Dir' );
    make_path($sub);
    write_raw( File::Spec->catfile( $sub, 'File X.txt' ), "x\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 0, 'exit 0' );
    ok( -e File::Spec->catfile( $tmp, 'tema-1', 'sub-dir', 'file-x.txt' ),
        'full nested path normalized' );
    done_testing();
};

# --------------------------------------------------- unit: rename cycles

subtest 'rename cycles preserve data' => sub {
    my $tmp = newtmp();
    my $fa  = File::Spec->catfile( $tmp, 'A' );
    my $fb  = File::Spec->catfile( $tmp, 'B' );
    write_raw( $fa, "alpha\n" );
    write_raw( $fb, "beta\n" );
    my $cfg = NormalizeFiles::default_config();
    my @ops = (
        {
            parent_raw => $tmp,
            parent_rel => '',
            old_raw    => 'A',
            old_char   => 'A',
            new_char   => 'B',
            new_raw    => 'B',
            rel        => 'A',
            is_dir     => 0,
            depth      => 0,
        },
        {
            parent_raw => $tmp,
            parent_rel => '',
            old_raw    => 'B',
            old_char   => 'B',
            new_char   => 'A',
            new_raw    => 'A',
            rel        => 'B',
            is_dir     => 0,
            depth      => 0,
        },
    );
    my $R = NormalizeFiles::reset_report();
    NormalizeFiles::execute_rename_group( $cfg, $tmp, \@ops, $R );
    is( $R->{errors},   0,         'no errors during cycle' );
    is( slurp_raw($fa), "beta\n",  'A now holds B content' );
    is( slurp_raw($fb), "alpha\n", 'B now holds A content' );
    done_testing();
};

# ------------------------------------------------------- encodings

subtest 'UTF-8 valid content is left byte-identical' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'utf8.txt' );
    my $data = encode( 'UTF-8', "caf\x{e9} \x{1f600}\n" );
    write_raw( $path, $data );
    my ( $rc, undef ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc,              0,     'exit 0' );
    is( slurp_raw($path), $data, 'bytes unchanged' );
    done_testing();
};

subtest 'UTF-8 BOM is stripped' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'bom.txt' );
    write_raw( $path, "\xEF\xBB\xBFhello\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc,              0,         'exit 0' );
    is( slurp_raw($path), "hello\n", 'BOM removed, text kept' );
    done_testing();
};

subtest 'UTF-16LE is converted to UTF-8' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'le.txt' );
    write_raw( $path, "\xFF\xFE" . encode( 'UTF-16LE', "hola \x{e9}\n" ) );
    my ( $rc, undef ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc, 0, 'exit 0' );
    is(
        slurp_raw($path),
        encode( 'UTF-8', "hola \x{e9}\n" ),
        'converted to UTF-8'
    );
    done_testing();
};

subtest 'UTF-16BE is converted to UTF-8' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'be.txt' );
    write_raw( $path, "\xFE\xFF" . encode( 'UTF-16BE', "hola\n" ) );
    my ( $rc, undef ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc,              0,        'exit 0' );
    is( slurp_raw($path), "hola\n", 'converted to UTF-8' );
    done_testing();
};

subtest 'Windows-1252 is reported ambiguous, not converted' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'cp1252.txt' );
    my $data = encode( 'cp1252', "\x{201c}Hola\x{201d}\n" );
    write_raw( $path, $data );
    my ( $rc, $out ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc, 2, 'exit 2: ambiguity needs a decision' );
    like( $out, qr/AMBIGUOUS/, 'reported ambiguous' );
    is( slurp_raw($path), $data, 'bytes strictly unchanged' );
    done_testing();
};

subtest 'ambiguous Latin-1 is not converted silently' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'latin1.txt' );
    my $data = encode( 'ISO-8859-1', "Caf\x{e9}\n" );
    write_raw( $path, $data );
    my ( $rc, $out ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc, 2, 'exit 2' );
    like( $out, qr/AMBIGUOUS/, 'reported' );
    is( slurp_raw($path), $data, 'bytes unchanged' );
    done_testing();
};

subtest 'assume-encoding converts ambiguous legacy text' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'latin1.txt' );
    write_raw( $path, encode( 'ISO-8859-1', "Caf\x{e9}\n" ) );
    my ( $rc, undef ) =
      run_capture( '--apply', '--encoding', '--assume-encoding', 'iso-8859-1',
        $tmp );
    is( $rc,              0,                                'exit 0' );
    is( slurp_raw($path), encode( 'UTF-8', "Caf\x{e9}\n" ), 'converted' );
    done_testing();
};

# ------------------------------------------------------- line endings

subtest 'line ending conversions' => sub {
    my $tmp = newtmp();
    write_raw( File::Spec->catfile( $tmp, 'crlf.txt' ),  "a\r\nb\r\n" );
    write_raw( File::Spec->catfile( $tmp, 'lf.txt' ),    "a\nb\n" );
    write_raw( File::Spec->catfile( $tmp, 'cr.txt' ),    "a\rb\r" );
    write_raw( File::Spec->catfile( $tmp, 'mixed.txt' ), "a\r\nb\nc\rd" );
    my ( $rc, undef ) = run_capture( '--apply', '--line-endings', $tmp );
    is( $rc, 0, 'exit 0' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'crlf.txt' ) ),
        "a\nb\n", 'CRLF -> LF' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'lf.txt' ) ),
        "a\nb\n", 'LF unchanged' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'cr.txt' ) ),
        "a\nb\n", 'CR -> LF' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'mixed.txt' ) ),
        "a\nb\nc\nd", 'mixed -> LF' );
    done_testing();
};

subtest 'Windows scripts keep CRLF by default' => sub {
    my $tmp = newtmp();
    my $bat = File::Spec->catfile( $tmp, 'run.bat' );
    write_raw( $bat, "echo hi\r\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--line-endings', $tmp );
    is( $rc,             0,             'exit 0' );
    is( slurp_raw($bat), "echo hi\r\n", 'CRLF preserved' );
    done_testing();
};

subtest '--windows-scripts-lf converts bat to LF' => sub {
    my $tmp = newtmp();
    my $bat = File::Spec->catfile( $tmp, 'run.bat' );
    write_raw( $bat, "echo hi\r\n" );
    my ( $rc, undef ) =
      run_capture( '--apply', '--line-endings', '--windows-scripts-lf', $tmp );
    is( $rc,             0,           'exit 0' );
    is( slurp_raw($bat), "echo hi\n", 'converted to LF' );
    done_testing();
};

# ------------------------------------------------------- binary safety

subtest 'binary by extension is untouched' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'image.png' );
    my $data = "\x89PNG\r\n\x1a\n\x00binary\r\nbytes";
    write_raw( $path, $data );
    my ( $rc, undef ) =
      run_capture( '--apply', '--encoding', '--line-endings', $tmp );
    is( $rc,              0,     'exit 0' );
    is( slurp_raw($path), $data, 'bytes identical despite CRLF/NUL' );
    done_testing();
};

subtest 'text extension with binary content is not rewritten' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'looks-like.txt' );
    my $data = "text\x00\x01\x02\r\nmore\x00";
    write_raw( $path, $data );
    my ( $rc, undef ) =
      run_capture( '--apply', '--encoding', '--line-endings', $tmp );
    is( $rc,              0,     'exit 0' );
    is( slurp_raw($path), $data, 'NUL makes it binary; bytes untouched' );
    done_testing();
};

# ------------------------------------------------------- symlinks

subtest 'symlinks are not followed and targets are untouched' => sub {
    my $tmp    = newtmp();
    my $target = File::Spec->catfile( $tmp, 'Target File.txt' );
    write_raw( $target, "data\n" );
    my $link = File::Spec->catfile( $tmp, 'Link Name' );
    my $made = eval { symlink( $target, $link ) };
    if ( !$made ) {
        plan skip_all => 'symlinks not supported here';
    }
    my ( $rc, undef ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 0, 'exit 0' );
    is( slurp_raw( File::Spec->catfile( $tmp, 'target-file.txt' ) ),
        "data\n", 'target content preserved under its new name' );
    ok(
        -l File::Spec->catfile( $tmp, 'link-name' ),
        'the symlink itself was renamed (still a link)'
    );
    done_testing();
};

# ------------------------------------------------------- idempotence + report

subtest 'idempotence after apply' => sub {
    my $tmp = newtmp();
    my $sub = File::Spec->catdir( $tmp, 'Tema 1' );
    make_path($sub);
    write_raw( File::Spec->catfile( $sub, 'Ámbito y Ñ.txt' ), "hola\r\n" );
    write_raw( File::Spec->catfile( $tmp, 'BOM.md' ), "\xEF\xBB\xBFx\r\n" );
    my @mode = ( '--rename', '--encoding', '--line-endings' );
    my ( $rc1, undef ) = run_capture( '--apply', @mode, $tmp );
    is( $rc1, 0, 'first apply exits 0' );
    my ( $rc2, $out2 ) = run_capture( '--apply', @mode, $tmp );
    is( $rc2, 0, 'second apply exits 0' );
    like( $out2, qr/No changes required/i, 'second apply reports no changes' );
    my ( $rc3, $out3 ) = run_capture( '--dry-run', @mode, $tmp );
    is( $rc3, 0, 'dry-run afterwards exits 0' );
    done_testing();
};

subtest '--report writes UTF-8 with LF' => sub {
    my $tmp    = newtmp();
    my $report = File::Spec->catfile( $tmp, 'report.txt' );
    write_raw( File::Spec->catfile( $tmp, 'A B.txt' ), "x\r\n" );
    my ( $rc, undef ) =
      run_capture( '--dry-run', '--rename', '--report', $report, $tmp );
    ok( -e $report, 'report written' );
    my $bytes = slurp_raw($report);
    unlike( $bytes, qr/\r/, 'report uses LF only' );
    ok( eval { decode( 'UTF-8', $bytes, Encode::FB_CROAK() ); 1 },
        'report is valid UTF-8' );
    done_testing();
};

subtest 'usage errors exit 3' => sub {
    my ( $rc, undef ) = run_capture( 'one', 'two' );
    is( $rc, 3, 'too many arguments' );
    done_testing();
};

# ------------------------------------ regression: repository safety fixes

subtest '.git is excluded even when it is a file' => sub {
    my $tmp  = newtmp();
    my $git  = File::Spec->catfile( $tmp, '.git' );
    my $text = File::Spec->catfile( $tmp, 'a.txt' );
    write_raw( $git,  "gitdir: ../elsewhere\r\n" );
    write_raw( $text, "a\r\nb\r\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--line-endings', $tmp );
    is( $rc,              0,                          'exit 0' );
    is( slurp_raw($git),  "gitdir: ../elsewhere\r\n", '.git file untouched' );
    is( slurp_raw($text), "a\nb\n",                   'normal file converted' );
    done_testing();
};

subtest '.gitattributes and .editorconfig are never modified' => sub {
    my $tmp = newtmp();
    my $ga  = File::Spec->catfile( $tmp, '.gitattributes' );
    my $ec  = File::Spec->catfile( $tmp, '.editorconfig' );
    my $txt = File::Spec->catfile( $tmp, 'a.txt' );
    write_raw( $ga,  "*.txt text\r\n" );
    write_raw( $ec,  "root = true\r\n[*]\r\nend_of_line = lf\r\n" );
    write_raw( $txt, "a\r\nb\r\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--line-endings', $tmp );
    is( $rc,            0,                'exit 0' );
    is( slurp_raw($ga), "*.txt text\r\n", '.gitattributes untouched' );
    is(
        slurp_raw($ec),
        "root = true\r\n[*]\r\nend_of_line = lf\r\n",
        '.editorconfig untouched'
    );
    done_testing();
};

subtest 'read-only files are skipped, never made writable' => sub {
    if ($WINDOWS) { plan skip_all => 'POSIX permission bits are used here' }
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'ro.txt' );
    write_raw( $path, "a\r\nb\r\n" );
    chmod 0444, $path;
    my ($mode_before) = ( stat($path) )[2] & 07777;
    my ( $rc, undef ) = run_capture( '--apply', '--line-endings', $tmp );
    is( $rc,              2,            'exit 2: intervention required' );
    is( slurp_raw($path), "a\r\nb\r\n", 'content untouched' );
    my ($mode_after) = ( stat($path) )[2] & 07777;
    is( $mode_after, $mode_before, 'read-only bit preserved' );
    chmod 0644, $path;
    done_testing();
};

subtest 'BOM-prefixed binary that decodes to NUL is skipped' => sub {
    my $tmp  = newtmp();
    my $path = File::Spec->catfile( $tmp, 'weird.txt' );
    my $data = "\xFE\xFF" . pack( 'n*', 0x0000, 0x0041, 0x0042 );
    write_raw( $path, $data );
    my ( $rc, undef ) = run_capture( '--apply', '--encoding', $tmp );
    is( $rc,              0,     'exit 0' );
    is( slurp_raw($path), $data, 'not converted' );
    done_testing();
};

subtest 'staging leaves no temporary files behind' => sub {
    my $tmp = newtmp();
    write_raw( File::Spec->catfile( $tmp, 'README.TXT' ), "hi\n" );
    my ( $rc, undef ) = run_capture( '--apply', '--rename', $tmp );
    is( $rc, 0, 'exit 0' );
    opendir my $dh, $tmp or die "opendir $tmp: $!";
    my @left = grep { m{^\.norm-} } readdir $dh;
    closedir $dh;
    is( scalar @left, 0, 'no .norm-* leftovers' );
    done_testing();
};

subtest 'partial rename failure rolls the group back' => sub {
    my $tmp = newtmp();
    my $fx  = File::Spec->catfile( $tmp, 'X' );
    write_raw( $fx, "alpha\n" );
    my $cfg = NormalizeFiles::default_config();
    my @ops = (
        {
            parent_raw => $tmp,
            parent_rel => '',
            old_raw    => 'X',
            old_char   => 'X',
            new_raw    => 'x',
            new_char   => 'x',
            rel        => 'X',
            is_dir     => 0,
            depth      => 0,
        },
        {
            parent_raw => $tmp,
            parent_rel => '',
            old_raw    => 'MISSING',
            old_char   => 'MISSING',
            new_raw    => 'y',
            new_char   => 'y',
            rel        => 'MISSING',
            is_dir     => 0,
            depth      => 0,
        },
    );
    my $R = NormalizeFiles::reset_report();
    NormalizeFiles::execute_rename_group( $cfg, $tmp, \@ops, $R );
    ok( $R->{errors} > 0, 'error recorded for the failing rename' );
    ok( -e $fx,           'original name restored' );
    ok( !-e File::Spec->catfile( $tmp, 'x' ), 'renamed name removed' );
    is( slurp_raw($fx),        "alpha\n", 'content preserved' );
    is( $R->{renames_applied}, 0,         'no rename reported as applied' );
    done_testing();
};

subtest 'undecodable file name: content processed, rename skipped' => sub {
    my $tmp = newtmp();
    my $raw = pack( 'C*', 0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74 );
    my $p   = File::Spec->catfile( $tmp, $raw );
    write_raw( $p, "a\r\nb\r\n" );
    my ( $rc, undef ) =
      run_capture( '--apply', '--line-endings', '--encoding', $tmp );
    is( $rc,           0,        'exit 0' );
    is( slurp_raw($p), "a\nb\n", 'content normalized despite weird name' );
    ok( -e $p, 'name left untouched' );
    done_testing();
};

subtest 'OpenBSD sandbox is a no-op on other systems' => sub {
    plan skip_all => 'OpenBSD only' if $^O eq 'openbsd';
    my $tmp = newtmp();
    my $cfg = NormalizeFiles::default_config();
    my $ok  = eval {
        NormalizeFiles::setup_openbsd_sandbox( $cfg, $tmp, undef );
        1;
    };
    ok( $ok, 'returns without dying outside OpenBSD' );
    done_testing();
};

subtest '--version reports the project version' => sub {
    my ( $rc, $out ) = run_capture('--version');
    is( $rc, 0, 'exit 0' );
    like( $out, qr/^normalize-files \S+/, 'prints name and version' );
    my $vfile = File::Spec->catfile( $dirs, '..', 'VERSION' );
    if ( -f $vfile ) {
        open my $fh, '<:raw', $vfile or die "open $vfile: $!";
        my $v = <$fh>;
        close $fh;
        $v =~ s/\s+\z//;
        like( $out, qr/\Q$v\E/, 'matches the VERSION file' );
    }
    done_testing();
};

done_testing();
