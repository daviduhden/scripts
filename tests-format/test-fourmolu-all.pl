#!/usr/bin/env perl

# Exercise Haskell file discovery, bundled-style enforcement and failure
# propagation in fourmolu-all.sh in isolation.
# Usage: perl tests-format/test-fourmolu-all.pl
# Uses only Perl core modules; no installed formatters are required.
# See the LICENSE file at the top of the project tree for copyright details.

use strict;
use warnings;

use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $source = dirname( abs_path(__FILE__) );

sub write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $text or die "write $path: $!";
    close $fh         or die "close $path: $!";
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "close $path: $!";
    return $text // '';
}

sub remove_file {
    my ($path) = @_;
    unlink $path or die "unlink $path: $!";
}

sub mock {
    my ( $ctx, $tool, $status ) = @_;
    $status //= 0;
    my $path = "$ctx->{bin}/$tool";
    write_file( $path,
            '#!/bin/sh' . "\n"
          . 'printf "%s\n" "$0 $*" >> "$CALLS"'
          . "\nexit $status\n" );
    chmod 0755, $path or die "chmod $path: $!";
}

sub fixture {
    my $root = tempdir( 'fourmolu-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $ctx  = {
        root    => $root,
        bin     => "$root/bin",
        project => "$root/project with spaces",
        calls   => "$root/calls",
        script  => "$source/fourmolu-all.sh",
    };
    mkdir $ctx->{bin}     or die "mkdir $ctx->{bin}: $!";
    mkdir $ctx->{project} or die "mkdir $ctx->{project}: $!";
    for my $tool (qw(find sed grep dirname)) {
        my ($path) = grep { -f $_ && -x _ }
          map { File::Spec->rel2abs( File::Spec->catfile( $_, $tool ) ) }
          split /:/, ( $ENV{PATH} // '' );
        defined $path or die "required tool missing: $tool";
        symlink $path, "$ctx->{bin}/$tool" or die "symlink $tool: $!";
    }
    write_file( "$ctx->{project}/Sample.hs",
        "module Sample where\n\nsample :: Int\nsample = 1\n" );
    mock( $ctx, 'fourmolu' );
    return $ctx;
}

sub run_script {
    my ( $ctx, $success, @args ) = @_;
    my $pid = fork();
    defined $pid or die "fork: $!";
    if ( $pid == 0 ) {
        $ENV{PATH}   = $ctx->{bin};
        $ENV{CALLS}  = $ctx->{calls};
        $ENV{TMPDIR} = $ctx->{root};
        chdir $ctx->{project} or die "chdir $ctx->{project}: $!";
        open STDOUT, '>', "$ctx->{root}/stdout" or die "stdout: $!";
        open STDERR, '>', "$ctx->{root}/stderr" or die "stderr: $!";
        exec '/bin/sh', $ctx->{script}, @args;
        die "exec /bin/sh: $!";
    }
    waitpid( $pid, 0 ) == $pid or die "waitpid: $!";
    my $status = $?;
    my $passed = is( $status == 0 ? 1 : 0,
        $success, $success ? 'script succeeds' : 'script fails' );
    unless ($passed) {
        diag("child status: $status");
        diag( read_file("$ctx->{root}/stderr") );
        opendir my $dir, $ctx->{root} or die "opendir: $!";
        my @logs = grep { /\.log\z/ } readdir $dir;
        closedir $dir or die "closedir: $!";
        diag( read_file("$ctx->{root}/$_") ) for sort @logs;
    }
    return -f $ctx->{calls} ? read_file( $ctx->{calls} ) : '';
}

subtest 'bundled style is used for Haskell sources' => sub {
    my $ctx   = fixture();
    my $calls = run_script( $ctx, 1, $ctx->{project} );
    like(
        $calls,
        qr/fourmolu --config \Q$source\E\/fourmolu-all\.yaml -i .*Sample\.hs/,
        'fourmolu formats Sample.hs with the bundled style'
    );
    like(
        $calls,
qr/fourmolu --config \Q$source\E\/fourmolu-all\.yaml --stdin-input-file/,
        'bundled style is validated before formatting'
    );
};

subtest 'project-local fourmolu.yaml is ignored' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{project}/fourmolu.yaml", "not: a valid style\n" );
    my $calls = run_script( $ctx, 1, $ctx->{project} );
    like(
        $calls,
        qr/--config \Q$source\E\/fourmolu-all\.yaml/,
        'bundled style wins over the project-local file'
    );
    unlike(
        $calls,
        qr/\Q$ctx->{project}\E\/fourmolu\.yaml/,
        'project-local fourmolu.yaml is never passed to fourmolu'
    );
};

subtest 'discovery selects Haskell sources only' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{project}/Sig.hsig",     "signature Sig where\n" );
    write_file( "$ctx->{project}/Boot.hs-boot", "module Boot where\n" );
    write_file( "$ctx->{project}/Literate.lhs", "> module Literate where\n" );
    write_file( "$ctx->{project}/notes.txt",    "not Haskell\n" );
    my $calls = run_script( $ctx, 1, $ctx->{project} );
    like( $calls, qr/Sample\.hs/,    'plain modules are formatted' );
    like( $calls, qr/Sig\.hsig/,     'signature files are formatted' );
    like( $calls, qr/Boot\.hs-boot/, 'boot files are formatted' );
    unlike( $calls, qr/Literate\.lhs/, 'literate Haskell is left alone' );
    unlike( $calls, qr/notes\.txt/,    'non-Haskell files are left alone' );
};

subtest 'git metadata is pruned' => sub {
    my $ctx = fixture();
    my $git = "$ctx->{project}/.git";
    mkdir $git or die "mkdir $git: $!";
    write_file( "$git/ignored.hs", "module Ignored where\n" );
    my $calls = run_script( $ctx, 1, $ctx->{project} );
    unlike( $calls, qr/ignored\.hs/, '.git files are not formatted' );
};

subtest 'no Haskell files skips formatting' => sub {
    my $ctx   = fixture();
    my $empty = "$ctx->{project}/empty";
    mkdir $empty or die "mkdir $empty: $!";
    is( run_script( $ctx, 1, $empty ),
        '', 'no fourmolu call when no Haskell files are found' );
};

subtest 'missing fourmolu skips formatting' => sub {
    my $ctx = fixture();
    remove_file("$ctx->{bin}/fourmolu");
    is( run_script( $ctx, 1, $ctx->{project} ),
        '', 'no tools skips formatting and succeeds' );
};

subtest 'formatter failure propagates' => sub {
    my $ctx = fixture();
    mock( $ctx, 'fourmolu', 1 );
    run_script( $ctx, 0, $ctx->{project} );
};

subtest 'installed script uses the installed style' => sub {
    my $ctx = fixture();
    $ctx->{script} = "$ctx->{bin}/fourmolu-all";
    copy( "$source/fourmolu-all.sh", $ctx->{script} )
      or die "copy script: $!";
    my $style = "$ctx->{bin}/fourmolu-all.yaml";
    copy( "$source/fourmolu-all.yaml", $style ) or die "copy style: $!";
    like(
        run_script( $ctx, 1, $ctx->{project} ),
        qr/--config \Q$style\E/,
        'installed style path is resolved next to the installed script'
    );
    remove_file($style);
    run_script( $ctx, 0, $ctx->{project} );
};

done_testing();
