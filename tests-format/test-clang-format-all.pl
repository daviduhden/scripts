#!/usr/bin/env perl

# Exercise formatter selection and installed-style resolution in isolation.
# Usage: perl tests-format/test-clang-format-all.pl
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
    my $root = tempdir( 'format-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $ctx  = {
        root    => $root,
        bin     => "$root/bin",
        project => "$root/project with spaces",
        calls   => "$root/calls",
        script  => "$source/clang-format-all.sh",
    };
    mkdir $ctx->{bin}     or die "mkdir $ctx->{bin}: $!";
    mkdir $ctx->{project} or die "mkdir $ctx->{project}: $!";
    for my $tool (qw(uname find sed grep awk dirname)) {
        my ($path) = grep { -f $_ && -x _ }
          map { File::Spec->rel2abs( File::Spec->catfile( $_, $tool ) ) }
          split /:/, ( $ENV{PATH} // '' );
        defined $path or die "required tool missing: $tool";
        symlink $path, "$ctx->{bin}/$tool" or die "symlink $tool: $!";
    }
    write_file( "$ctx->{project}/sample.c", "int main(void) { return 0; }\n" );
    mock( $ctx, $_ ) for qw(knfmt clang-format);
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
        delete $ENV{C_FORMAT_STANDARD};
        $ENV{C_FORMAT_STANDARD} = $ctx->{standard} if exists $ctx->{standard};
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

subtest 'Makefile standards' => sub {
    my $ctx = fixture();
    for my $std (qw(c11 c17 c23 c18 c2x gnu11 gnu17 gnu23)) {
        write_file( "$ctx->{project}/Makefile", "CFLAGS += -std=$std\n" );
        my $calls = run_script( $ctx, 1, $ctx->{project} );
        like(
            $calls,
            qr/clang-format -i -style=file:\Q$source\E\/clang-format/,
            "$std selects clang-format with the bundled style"
        );
        unlike( $calls, qr/knfmt -i/, "$std does not select knfmt" );
        remove_file( $ctx->{calls} );
    }
};

subtest 'old, unknown and commented standards' => sub {
    my $ctx = fixture();
    for my $flags ( '', '-std=c99', '# -std=c23', '-std=c++23' ) {
        write_file( "$ctx->{project}/Makefile", "$flags\n" );
        like( run_script( $ctx, 1, $ctx->{project} ),
            qr/knfmt -i/, "knfmt selected for '$flags'" );
        remove_file( $ctx->{calls} );
    }
};

subtest 'other build metadata' => sub {
    my $ctx = fixture();
    for my $metadata (
        [ 'CMakeLists.txt', 'set(CMAKE_C_STANDARD 17)' ],
        [ 'meson.build', "project('x', 'c', default_options: ['c_std=c23'])" ],
        [ 'compile_commands.json', '[{"command": "cc -std=c11 sample.c"}]' ],
      )
    {
        my ( $name, $text ) = @$metadata;
        my $path = "$ctx->{project}/$name";
        write_file( $path, $text );
        like(
            run_script( $ctx, 1, $ctx->{project} ),
            qr/clang-format -i/,
            "$name selects clang-format"
        );
        remove_file( $ctx->{calls} );
        remove_file($path);
    }
};

subtest 'BSD Makefile.inc in ancestor directories' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{project}/Makefile.inc",
        "CFLAGS_COMMON = -std=c23 -Wall\n" );
    my $child = "$ctx->{project}/fvwm";
    mkdir $child or die "mkdir $child: $!";
    write_file( "$child/Makefile", ".include \"../Makefile.inc\"\n" );
    write_file( "$child/decorations.c",
"void f(int n) { switch (n) { case 0: [[fallthrough]]; default: break; } }\n"
    );
    my $calls = run_script( $ctx, 1, $child );
    like( $calls, qr/clang-format -i/, 'inherited C23 selects clang-format' );
    unlike( $calls, qr/knfmt -i/, 'C23 attributes are not passed to knfmt' );
    remove_file( $ctx->{calls} );
    write_file( "$child/Makefile", "CFLAGS = -std=c99\n" );
    like( run_script( $ctx, 1, $child ),
        qr/knfmt -i/, 'local standard overrides ancestor Makefile.inc' );
};

subtest 'nearest standard and override' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{project}/Makefile", "CFLAGS=-std=c23\n" );
    my $child = "$ctx->{project}/child";
    mkdir $child or die "mkdir $child: $!";
    write_file( "$child/Makefile", "CFLAGS=-std=c99\n" );
    write_file( "$child/child.c",  "int child;\n" );
    like( run_script( $ctx, 1, $child ), qr/knfmt -i/,
        'nearest standard wins' );
    remove_file( $ctx->{calls} );
    $ctx->{standard} = 'c11';
    unlike( run_script( $ctx, 1, $child ), qr/knfmt -i/, 'override wins' );
};

subtest 'repository boundary and git pruning' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{root}/Makefile", "CFLAGS=-std=c23\n" );
    my $git = "$ctx->{project}/.git";
    mkdir $git or die "mkdir $git: $!";
    write_file( "$git/ignored.c", "ignored\n" );
    my $calls = run_script( $ctx, 1, $ctx->{root} );
    like( $calls, qr/knfmt -i/, 'standard outside repository ignored' );
    unlike( $calls, qr/ignored\.c/, '.git files ignored' );
};

subtest 'missing tools' => sub {
    my $ctx = fixture();
    write_file( "$ctx->{project}/Makefile", "CFLAGS=-std=c23\n" );
    remove_file("$ctx->{bin}/clang-format");
    like( run_script( $ctx, 1, $ctx->{project} ),
        qr/knfmt -i/, 'fallback to knfmt' );
    remove_file( $ctx->{calls} );
    remove_file("$ctx->{bin}/knfmt");
    is( run_script( $ctx, 1, $ctx->{project} ),
        '', 'no tools skips formatting' );
    mock( $ctx, 'clang-format' );
    like(
        run_script( $ctx, 1, $ctx->{project} ),
        qr/clang-format -i/,
        'clang-format works without knfmt'
    );
};

subtest 'installed style and default directory' => sub {
    my $ctx = fixture();
    $ctx->{script} = "$ctx->{bin}/clang-format-all";
    copy( "$source/clang-format-all.sh", $ctx->{script} )
      or die "copy script: $!";
    my $style = "$ctx->{bin}/clang-format-all.yaml";
    copy( "$source/clang-format", $style ) or die "copy style: $!";
    write_file( "$ctx->{project}/.clang-format", "invalid local style\n" );
    $ctx->{standard} = 'c23';
    like(
        run_script( $ctx, 1 ),
        qr/-style=file:\Q$style\E/,
        'installed style used'
    );
    remove_file($style);
    run_script( $ctx, 0 );
};

subtest 'formatter failure propagates' => sub {
    my $ctx = fixture();
    mock( $ctx, 'knfmt', 1 );
    run_script( $ctx, 0, $ctx->{project} );
    mock( $ctx, 'clang-format', 1 );
    $ctx->{standard} = 'c23';
    run_script( $ctx, 0, $ctx->{project} );
};

done_testing();
