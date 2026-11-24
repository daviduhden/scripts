#!/usr/bin/env perl

# Offline regressions for Linux AI CLI selection and update verification.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use 5.010_001;
use strict;
use warnings;

use File::Path qw(make_path);
use FindBin    qw($Bin);
use lib $Bin;
use Test::More;

use TestHarness qw(
  env_with find_command is_linux new_tempdir repo_root run_command slurp
  write_file
);

my $bash = find_command('bash');
plan skip_all => 'Linux and Bash are required' unless is_linux() && $bash;

my $repository = repo_root();
my $fixture    = "$Bin/fixtures/mock-ai-cli-updater.bash";
my $updater    = "$repository/scripts/update-ai-clis-linux.bash";

sub sandbox {
    my $root = new_tempdir('ai-cli-updater-');
    make_path( "$root/bin", "$root/home", "$root/other" );
    write_file( "$root/events", '' );
    return $root;
}

sub run_updater {
    my ( $root, $variables, @arguments ) = @_;
    return run_command(
        cmd => [ $bash, $fixture, $updater, @arguments ],
        env => env_with(
            %$variables,
            HOME         => "$root/home",
            FIXTURE_ROOT => $root
        ),
        timeout => 20,
    );
}

sub executable {
    my ( $directory, $name, $version ) = @_;
    my $path = "$directory/$name";
    write_file( $path, "#!/bin/sh\nprintf '%s\\n' '$version'\n" );
    chmod 0755, $path or die "cannot chmod $path: $!";
}

subtest 'invalid selectors are rejected before processing any target' => sub {
    my $root = sandbox();
    my $run  = run_updater( $root, {}, 'codex', 'unknown-agent' );
    is( $run->{returncode},    2,  'invalid arguments return usage error' );
    is( slurp("$root/events"), '', 'no package or executable was touched' );
};

subtest 'install, preview replacement, and repeated selective updates' => sub {
    my $root = sandbox();
    executable( "$root/bin", 'claude', '2.0.0-rc.10 (Claude Code)' );
    my $run = run_updater( $root, {}, 'codex', 'claude', 'codex' );
    is( $run->{returncode}, 0, 'mixed installation and upgrade succeed' )
      or diag $run->{stdout} . $run->{stderr};
    like(
        $run->{stdout},
        qr/^codex\t.*\t2\.0\.0\t2\.0\.0\tinstalled$/m,
        'reports newly installed version'
    );
    like(
        $run->{stdout},
        qr/^claude\t2\.0\.0-rc\.10\t2\.0\.0\t2\.0\.0\tupdated$/m,
        'reports the replaced prerelease and verified stable version'
    );
    my @installs = slurp("$root/events") =~ /^(install .+)$/mg;
    is_deeply(
        \@installs,
        [ 'install codex', 'install claude' ],
        'only selected agents run and duplicate selections are collapsed'
    );

    write_file( "$root/events", '' );
    $run = run_updater( $root, {}, 'codex', 'claude' );
    is( $run->{returncode}, 0, 'repeat succeeds' )
      or diag $run->{stdout} . $run->{stderr};
    unlike( slurp("$root/events"), qr/^install /m, 'repeat does not install' );
    unlike(
        slurp("$root/events"),
        qr/^dependencies /m,
        'current agents do not require an APT dependency operation'
    );
};

subtest 'dependency, network, package and final checks propagate failure' =>
  sub {
    for my $variable (
        qw(FIXTURE_DEPENDENCIES_FAIL FIXTURE_OFFLINE FIXTURE_INSTALL_FAIL
        FIXTURE_INSTALL_NOOP FIXTURE_PATH_FAIL FIXTURE_PERMISSION_FAIL)
      )
    {
        my $root = sandbox();
        executable( "$root/bin", 'codex', 'codex-cli 1.9.1' );
        my $run = run_updater( $root, { $variable => 'codex' }, 'codex' );
        is( $run->{returncode}, 1, "$variable causes an operational failure" )
          or diag $run->{stdout} . $run->{stderr};
        like(
            $run->{stdout},
            qr/^codex\t1\.9\.1\t.*\tfailed$/m,
            "$variable leaves a failure in the summary"
        );
    }
  };

subtest 'duplicate installations fail before replacing either copy' => sub {
    my $root = sandbox();
    executable( "$root/bin",   'codex', 'codex-cli 1.0.1' );
    executable( "$root/other", 'codex', 'codex-cli 1.0.2' );
    my $run = run_updater( $root, {}, 'codex' );
    is( $run->{returncode}, 1, 'conflicting installations fail' );
    like(
        $run->{stderr},
        qr/Multiple installations of codex/,
        'reports the conflict'
    );
    unlike( slurp("$root/events"), qr/^install /m,
        'no installation attempted' );
};

subtest 'all skips an unsupported agent, explicit selection fails' => sub {
    my $root = sandbox();
    my $vars = { FIXTURE_UNSUPPORTED => 'opencode' };
    my $run  = run_updater( $root, $vars, 'all' );
    is( $run->{returncode}, 0, 'all skips unavailable agents' )
      or diag $run->{stdout} . $run->{stderr};
    like(
        $run->{stdout},
        qr/^opencode\t.*\tunsupported$/m,
        'summary explains the unsupported target'
    );
    $run = run_updater( $root, $vars, 'opencode' );
    is( $run->{returncode}, 1, 'explicit unsupported target fails' );
};

subtest 'Copilot terminal punctuation is excluded from the version' => sub {
    my $root = sandbox();
    executable( "$root/bin", 'copilot', 'GitHub Copilot CLI 2.0.0.' );
    my $run = run_updater( $root, {}, 'copilot-cli' );
    is( $run->{returncode}, 0, 'Copilot version is recognized' )
      or diag $run->{stdout} . $run->{stderr};
    like(
        $run->{stdout},
        qr/^copilot-cli\t2\.0\.0\t2\.0\.0\t2\.0\.0\tcurrent$/m,
        'summary excludes the trailing period'
    );
};

subtest 'build metadata and newer version cores never trigger a reinstall' =>
  sub {
    for my $case (
        [ '2.0.0+build.7', 'current' ],
        [ '10.0.0',        'newer' ],
        [ '2.1.0-rc.1',    'newer' ],
      )
    {
        my ( $version, $result ) = @$case;
        my $root = sandbox();
        executable( "$root/bin", 'codex', "codex-cli $version" );
        my $run = run_updater( $root, {}, 'codex' );
        is( $run->{returncode}, 0, "$version is preserved" )
          or diag $run->{stdout} . $run->{stderr};
        like(
            $run->{stdout},
            qr/^codex\t\Q$version\E\t.*\t$result$/m,
            "summary reports $result for $version"
        );
        unlike( slurp("$root/events"), qr/^install /m, 'no reinstall' );
    }
  };

subtest 'APT upgrades required tools and reuses shared dependencies' => sub {
    my $root = sandbox();
    my $run  = run_updater( $root, {}, '--test-dependencies', 'codex',
        'claude', 'opencode' );
    is( $run->{returncode}, 0, 'missing and outdated tools are installed' )
      or diag $run->{stdout} . $run->{stderr};
    my $events  = slurp("$root/events");
    my @refresh = $events =~ /^(refresh)$/mg;
    is( scalar @refresh, 1, 'APT metadata refreshed once' );
    my @packages = sort( $events =~ /^package (.+)$/mg );
    is_deeply(
        \@packages,
        [qw(cosign curl jq openssl perl)],
        'only missing or outdated tools are installed, once each'
    );
    write_file( "$root/events", '' );
    $run = run_updater( $root, { FIXTURE_INCOMPATIBLE => 'openssl' },
        '--test-dependencies', 'opencode' );
    is( $run->{returncode}, 1, 'no compatible dependency candidate fails' );
    unlike( slurp("$root/events"), qr/^package /m,
        'dependency failure prevents an incomplete install' );
};

subtest 'fresh shell PATH persists once and confirms the expected binary' =>
  sub {
    my $root     = sandbox();
    my $launcher = <<'SH';
#!/bin/sh
[ "$1" = -lc ] || exit 2
shift
command=$1
shift
exec /bin/bash --noprofile --norc -c '
if [ -f "$HOME/.profile" ]; then . "$HOME/.profile"; fi
'"$command" "$@"
SH
    my $shell = write_file( "$root/bin/bash", $launcher );
    chmod 0755, $shell or die "cannot chmod $shell: $!";
    my $profile = write_file( "$root/home/.profile", "# existing profile\n" );
    executable( "$root/bin", 'codex', 'codex-cli 2.0.0' );
    for ( 1 .. 2 ) {
        my $run = run_updater( $root, {}, '--test-session' );
        is( $run->{returncode}, 0, 'fresh shell sees the installed executable' )
          or diag $run->{stdout} . $run->{stderr};
    }
    my $contents = slurp($profile);
    my @markers  = $contents =~ /^(# update-ai-clis PATH .+)$/mg;
    is( scalar @markers, 1, 'adds only one persistent PATH entry' );
    like( $contents, qr/\A# existing profile\n/, 'preserves existing profile' );

    executable( "$root/other", 'codex', 'codex-cli 2.0.0' );
    my $conflict = "export PATH='$root/other':\$PATH\n$contents";
    write_file( $profile, $conflict );
    my $run = run_updater( $root, {}, '--test-session' );
    is( $run->{returncode}, 1, 'a different same-version executable fails' );
    is( slurp($profile),    $conflict, 'preserves conflicting profile entry' );
  };

subtest 'Homebrew selects official casks and scopes package operations' => sub {
    my $jq = find_command('jq');
    plan skip_all => 'jq is required to parse Homebrew metadata' unless $jq;
    my $root = sandbox();
    my $run  = run_updater( $root, {}, '--test-homebrew', $jq );
    is( $run->{returncode}, 0, 'Homebrew cask install and upgrade succeed' )
      or diag $run->{stdout} . $run->{stderr};
    my @events = split /\n/, slurp("$root/events");
    is_deeply(
        \@events,
        [
            'update',
            'info --json=v2 --cask homebrew/cask/codex',
            'install --cask --require-sha homebrew/cask/codex',
            'info --json=v2 --cask homebrew/cask/claude-code',
            'upgrade --cask --require-sha --greedy homebrew/cask/claude-code',
        ],
        'refreshes once and applies one checksum-enforced operation per cask'
    );
};

done_testing();
