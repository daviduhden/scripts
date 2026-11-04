#!/usr/bin/env perl

# Offline checks for validator immutability and installer error propagation.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use strict;
use warnings;

use File::Path qw(make_path);
use FindBin    qw($Bin);
use lib $Bin;
use Test::More;

use TestHarness qw(
  collect_output
  dir_entries
  env_with
  files_under
  find_command
  find_files
  new_tempdir
  read_line
  repo_root
  run_command
  slurp
  spawn_command
  trim
  write_file
);

my $REPO = repo_root();

sub build_fixture {
    my $base = new_tempdir('tooling-tests-');
    my $bin  = "$base/bin";
    my $logs = "$base/logs";
    make_path( $bin, $logs );

    for my $name (
        qw(
        uname find sed grep mktemp rm sort wc tr awk dirname mkdir sh bash
        perl
        )
      )
    {
        my $command = find_command($name);
        next unless defined $command;
        symlink( $command, "$bin/$name" )
          or die "cannot link $name: $!";
    }

    unlink "$bin/uname" if -e "$bin/uname" || -l "$bin/uname";
    write_file( "$bin/uname", "#!/bin/sh\nprintf '%s\\n' Linux\n" );
    chmod 0755, "$bin/uname" or die "cannot chmod uname mock: $!";

    my $perl = find_command('perl') // $^X;
    my $mock = slurp("$REPO/tests/fixtures/mock-command.pl");
    $mock =~ s/__PERL__/$perl/;
    for my $name (qw(shfmt perltidy mbake perlcritic checkmake bmake)) {
        write_file( "$bin/$name", $mock );
        chmod 0755, "$bin/$name" or die "cannot chmod $name mock: $!";
    }

    my $checkbashisms = slurp("$REPO/tests/fixtures/mock-checkbashisms.pl");
    $checkbashisms =~ s/__PERL__/$perl/;
    write_file( "$bin/checkbashisms", $checkbashisms );
    chmod 0755, "$bin/checkbashisms"
      or die "cannot chmod checkbashisms mock: $!";

    my $shell = find_command('sh');
    die 'sh is required' unless defined $shell;
    symlink( $shell, "$bin/ksh" ) or die "cannot link ksh: $!";

    my $environment = env_with(
        PATH           => $bin,
        TMPDIR         => $logs,
        PERL_LOCAL_LIB => "$base/missing",
    );
    return {
        base => $base,
        bin  => $bin,
        logs => $logs,
        env  => $environment,
    };
}

sub run_validator {
    my ( $fixture, $kind, $root, @flags ) = @_;
    return run_command(
        cmd =>
          [ '/bin/sh', "$REPO/tests-format/validate-$kind.sh", @flags, $root ],
        env     => $fixture->{env},
        timeout => 30,
    );
}

subtest 'check never rewrites and format is explicit' => sub {
    my $fixture = build_fixture();
    for my $case (
        [
            'shell', 'sample.sh',
            "#!/bin/sh\n# UNFORMATTED\nprintf '%s\\n' ok\n"
        ],
        [ 'perl', 'sample.pl', "# UNFORMATTED\nuse strict; use warnings;\n" ],
        [ 'make', 'Makefile',  "# UNFORMATTED\nall:\n\t\@true\n" ],
      )
    {
        my ( $kind, $name, $content ) = @$case;
        subtest $kind => sub {
            my $root = "$fixture->{base}/$kind";
            make_path($root);
            my $source = "$root/$name";
            write_file( $source,                 $content );
            write_file( "$root/.cache/sentinel", 'keep' );

            my $before = files_under($root);
            my $check  = run_validator( $fixture, $kind, $root, '--check' );
            is( $check->{returncode}, 2, 'check mode reports drift' )
              or diag $check->{stdout} . $check->{stderr};
            is_deeply( files_under($root), $before,
                'check mode rewrites nothing' );

            my $format = run_validator( $fixture, $kind, $root, '--format' );
            is( $format->{returncode}, 2,
                'format mode reports rewritten drift' )
              or diag $format->{stdout} . $format->{stderr};
            unlike( slurp($source), qr/UNFORMATTED/,
                'format removes the marker' );

            my $clean = run_validator( $fixture, $kind, $root );
            is( $clean->{returncode}, 0, 'clean source passes default check' )
              or diag $clean->{stdout} . $clean->{stderr};
        };
    }
};

subtest 'strict rejects missing optional tools' => sub {
    my $fixture = build_fixture();
    my $root    = "$fixture->{base}/source";
    make_path($root);
    write_file( "$root/sample.sh", "#!/bin/sh\nexit 0\n" );
    unlink "$fixture->{bin}/shfmt"
      if -e "$fixture->{bin}/shfmt" || -l "$fixture->{bin}/shfmt";

    is( run_validator( $fixture, 'shell', $root )->{returncode},
        0, 'missing optional tool is a normal skip' );
    is( run_validator( $fixture, 'shell', $root, '--strict' )->{returncode},
        2, 'strict mode fails on a missing optional tool' );
    my @logs = dir_entries("$fixture->{logs}");
    my $found_skip =
      grep { index( slurp("$fixture->{logs}/$_"), '[SKIP] shfmt' ) >= 0 } @logs;
    ok( $found_skip, 'skip is recorded in the log' );
};

subtest 'predictable legacy symlinks are not followed' => sub {
    my $fixture = build_fixture();
    for my $case (
        [ 'perl', 'sample.pl', "# UNFORMATTED\nuse strict; use warnings;\n" ],
        [ 'make', 'Makefile',  "# UNFORMATTED\nall:\n\t\@true\n" ],
      )
    {
        my ( $kind, $name, $content ) = @$case;
        subtest $kind => sub {
            my $root = "$fixture->{base}/legacy-$kind";
            make_path($root);
            write_file( "$root/$name", $content );
            my $victim = "$fixture->{base}/victim-$kind";
            write_file( $victim, 'preserve' );

            my $process = spawn_command(
                cmd => [
                    '/bin/sh',
                    '-c',
                    'printf "%s\n" "$$"; read -r ready;'
                      . ' exec /bin/sh "$1" --check "$2"',
                    'driver',
                    "$REPO/tests-format/validate-$kind.sh",
                    $root,
                ],
                env => $fixture->{env},
            );
            my ( $pid_line, $remaining ) = read_line( $process->{out}, 20 );
            ok( defined $pid_line, 'validator reported its pid' )
              or return;
            my $pid = trim($pid_line);

            for my $legacy ( "validate-$kind-$pid.log",
                "validate-$kind-fails-$pid.txt",
                "unformatted-$kind-$pid.txt", )
            {
                unlink "$fixture->{logs}/$legacy"
                  if -e "$fixture->{logs}/$legacy"
                  || -l "$fixture->{logs}/$legacy";
                symlink( $victim, "$fixture->{logs}/$legacy" )
                  or die "cannot create $legacy: $!";
            }
            print { $process->{in} } "\n";
            close $process->{in};

            my $result = collect_output( $process, 20, stdout => $remaining );
            is( $result->{returncode}, 2, 'drift is still reported' )
              or diag $result->{stderr};
            is( slurp($victim), 'preserve', 'symlink target is untouched' );
        };
    }
};

subtest 'strict rejects unloadable Perl modules' => sub {
    my $fixture = build_fixture();
    my $root    = "$fixture->{base}/perl-modules";
    make_path($root);
    write_file( "$root/sample.pl",
        "use ToolingFixture::DeliberatelyMissing;\n" );

    is( run_validator( $fixture, 'perl', $root )->{returncode},
        0, 'missing module is a normal skip' );
    is( run_validator( $fixture, 'perl', $root, '--strict' )->{returncode},
        2, 'strict mode fails on an unloadable module' );
};

subtest 'make execution is opt in' => sub {
    my $fixture = build_fixture();
    my $root    = "$fixture->{base}/make-source";
    make_path($root);
    write_file( "$root/Makefile", "all:\n\t\@true\n" );
    my $marker = "$fixture->{base}/make-executed";
    write_file( "$fixture->{bin}/bmake", "#!/bin/sh\n: > '$marker'\n" );
    chmod 0755, "$fixture->{bin}/bmake"
      or die "cannot chmod bmake mock: $!";

    is( run_validator( $fixture, 'make', $root )->{returncode},
        0, 'default validation passes' );
    ok( !-e $marker, 'make is not executed by default' );
    is(
        run_validator( $fixture, 'make', $root, '--make-dry-run' )
          ->{returncode},
        0,
        'opted-in dry run passes'
    );
    ok( -e $marker, '--make-dry-run executes the trusted Makefile' );
};

subtest 'install accepts destination with spaces' => sub {
    my $fixture = build_fixture();
    my $root    = "$fixture->{base}/installation";
    make_path($root);
    write_file( "$root/Makefile",     slurp("$REPO/Makefile") );
    write_file( "$root/fixture.bash", "#!/bin/bash\nexit 0\n" );
    my $install = find_command('install');
    ok( defined $install, 'install is installed' ) or return;
    symlink( $install, "$fixture->{bin}/install" )
      or die "cannot link install: $!";
    my $destination = "$root/with spaces";
    my $make        = find_command('make');
    ok( defined $make, 'make is installed' ) or return;

    my $result = run_command(
        cmd => [
            $make,                         'install-debian',
            'DEBIAN_SCRIPTS=fixture.bash', "BINDIR=$destination",
        ],
        cwd     => $root,
        env     => $fixture->{env},
        timeout => 30,
    );
    is( $result->{returncode}, 0, 'installation succeeds' )
      or diag $result->{stderr};
    ok( -f "$destination/fixture",
        'installed name omits the source extension' );
};

subtest 'shell install restores attribute after copy failure' => sub {
    my $fixture = build_fixture();
    my $root    = "$fixture->{base}/shell-installation";
    make_path($root);
    write_file( "$root/Makefile", slurp("$REPO/Makefile") );
    my $destination = "$root/bash config";
    make_path($destination);
    my $marker = "$fixture->{base}/chattr-calls";
    write_file( "$fixture->{bin}/chattr",
        "#!/bin/sh\nprintf '%s\\n' \"\$1\" >> '$marker'\n" );
    chmod 0755, "$fixture->{bin}/chattr"
      or die "cannot chmod chattr mock: $!";
    write_file( "$fixture->{bin}/install", "#!/bin/sh\nexit 1\n" );
    chmod 0755, "$fixture->{bin}/install"
      or die "cannot chmod install mock: $!";
    my $make = find_command('make');
    ok( defined $make, 'make is installed' ) or return;

    my $result = run_command(
        cmd => [
            $make,                 'install-shell-bash',
            'BASH_CONF_FILES=bad', "BASH_CONF_DST_DIR=$destination",
        ],
        cwd     => $root,
        env     => $fixture->{env},
        timeout => 30,
    );
    isnt( $result->{returncode}, 0, 'copy failure fails the target' );
    is_deeply(
        [ split /\n/, slurp($marker) ],
        [ '-i',       '+i' ],
        'immutable attribute is restored after failure'
    );
};

subtest 'no Python source files are present' => sub {
    my @files = find_files( $REPO, qr{\.py\z} );
    is_deeply( \@files, [], 'no Python source files remain' );
};

subtest 'install loop stops at first failure' => sub {
    my $fixture = build_fixture();
    my $make    = find_command('make');
    ok( defined $make, 'make is installed' ) or return;
    my $root = "$fixture->{base}/installation";
    make_path($root);
    write_file( "$root/Makefile", slurp("$REPO/Makefile") );
    my $marker = "$fixture->{base}/late-install";
    write_file( "$fixture->{bin}/install",
            "#!/bin/sh\n"
          . "case \"\$*\" in\n"
          . "*-d*) exit 0 ;;\n"
          . "*bad*) exit 1 ;;\n"
          . "*) : > '$marker' ;;\n"
          . "esac\n" );
    chmod 0755, "$fixture->{bin}/install"
      or die "cannot chmod install mock: $!";

    my $result = run_command(
        cmd => [
            $make,
            'install-debian',
            'DEBIAN_SCRIPTS=bad.bash later.bash',
            'BINDIR=' . "$root/with spaces",
        ],
        cwd     => $root,
        env     => $fixture->{env},
        timeout => 30,
    );
    isnt( $result->{returncode}, 0, 'installation failure is propagated' );
    ok( !-e $marker, 'a later success does not hide installation failure' );
};

done_testing();
