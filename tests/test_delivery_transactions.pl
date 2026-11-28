#!/usr/bin/env perl

# Exercise delivery transactions only in temporary paths with mocked services.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use strict;
use warnings;

use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use FindBin     qw($Bin);
use JSON::PP    ();
use lib $Bin;
use Test::More;

use TestHarness qw(
  env_with
  extract_function
  find_command
  find_matching
  functions_without_main
  is_linux
  matching_entries
  new_tempdir
  repo_root
  run_command
  run_concurrent
  shell_quote
  slurp
  trim
  write_file
);

my $REPOSITORY_ROOT = repo_root();

subtest 'APT key checks admit exactly one approved primary key' => sub {
    my $awk = find_command('awk');
    plan skip_all => 'awk is unavailable' unless $awk;
    my $pin     = 'A' x 40;
    my $primary = join ':', 'fpr', ( ('') x 8 ), $pin, '';
    my $subkey  = join ':', 'fpr', ( ('') x 8 ), ( 'B' x 40 ), '';
    for my $repository (qw(gh-cli i2pd lynis tor)) {
        my $source = slurp("$REPOSITORY_ROOT/debian/add-$repository-repo.bash");
        my ($filter) = $source =~ /awk -F: '(\s*\$1 == "pub".*?\})'\)/s;
        ok( defined $filter, "$repository reads primary key records" )
          or next;
        my $allowed = "pub\n$primary\nsub\n$subkey\n";
        for my $case ( [ $allowed, $pin ], [ "$allowed\npub\n$subkey\n", '' ] )
        {
            my ( $input, $expected ) = @$case;
            my $root   = new_tempdir('apt-key-fixture-');
            my $file   = write_file( "$root/key-list", $input );
            my $result = run_command(
                cmd     => [ $awk, '-F:', $filter, $file ],
                timeout => 15,
            );
            is( $result->{returncode}, 0, "$repository key records parsed" );
            is( trim( $result->{stdout} ),
                $expected, "$repository selects a single primary fingerprint" );
        }
    }
};

subtest 'repository synchronization retains local Git metadata' => sub {
    plan skip_all => 'SecureBlue synchronization targets Linux'
      unless is_linux();
    plan skip_all => 'Git is unavailable' unless find_command('git');
    my $root = new_tempdir('github-sync-');
    my $program =
      functions_without_main("$REPOSITORY_ROOT/secureblue/sync-gh-repos.bash");
    my $commands = <<'SH';
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_COMMITTER_NAME=Fixture
export GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_EMAIL=fixture@example.invalid
git init -q -b main "$TEST_ROOT/upstream"
printf 'remote\n' >"$TEST_ROOT/upstream/file"
git -C "$TEST_ROOT/upstream" add file
git -C "$TEST_ROOT/upstream" commit -qm initial
mkdir "$TEST_ROOT/work"
BASE_DIR="$TEST_ROOT/work"
sync_single_repo repository "$TEST_ROOT/upstream" main
git -C "$BASE_DIR/repository" branch local-history
printf 'local\n' >"$BASE_DIR/repository/file"
if sync_single_repo repository "$TEST_ROOT/missing" main; then exit 1; fi
git -C "$BASE_DIR/repository" show-ref --verify refs/heads/local-history
sync_single_repo repository "$TEST_ROOT/upstream" main
for backup in "$BASE_DIR"/.repository.backup.*; do
    git -C "$backup/checkout" show-ref --verify refs/heads/local-history
done
test ! -e "$BASE_DIR/.repository.sync.lock"
SH
    my $result = run_command(
        cmd     => [ 'bash', '-c', "$program\n$commands" ],
        env     => env_with( TEST_ROOT => $root ),
        timeout => 30,
    );
    is( $result->{returncode}, 0, 'sync backs up local metadata' )
      or diag $result->{stdout} . $result->{stderr};
    is( slurp("$root/work/repository/file"),
        "local\n", 'published worktree preserves local changes' );
};

# Drive the Arti installer through its real entry point. Fake service state
# and downloads, and use paths with metacharacters to exercise unit rendering.
sub run_installer {
    my ( $root, %options ) = @_;
    my $mocks = "$root/mocks";
    make_path($mocks);

    my %bodies = (
        'systemd-analyze' => "#!/bin/sh\nexit 0\n",
        'systemctl'       => <<'SH',
#!/bin/sh
case "$*" in
*is-active*|*is-enabled*) exit 1;;
*enable*--now*) [ "$FAIL_START" = 0 ] || exit 1;;
esac
exit 0
SH
        'curl' => <<'SH',
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; target=$1; fi
    shift
done
if [ "$BAD_TOML" = 1 ]; then printf '[broken' >"$target"; else printf '[storage]\n' >"$target"; fi
SH
        'arti' => "#!/bin/sh\nprintf \"arti 1.4.0\\n\"\n",
    );

    for my $name ( keys %bodies ) {
        my $executable = "$mocks/$name";
        write_file( $executable, $bodies{$name} );
        chmod oct("755"), $executable or die "cannot chmod $executable: $!";
    }

    my $environment = env_with(
        HOME            => $root,
        XDG_CONFIG_HOME => "$root/config & # % \$ space",
        XDG_DATA_HOME   => "$root/data & # % \$ space",
        XDG_STATE_HOME  => "$root/state & # % \$ space",
        XDG_CACHE_HOME  => "$root/cache & # % \$ space",
        FAIL_START      => $options{fail}      ? '1' : '0',
        BAD_TOML        => $options{malformed} ? '1' : '0',
    );
    $environment->{PATH} = $mocks . ':' . $ENV{PATH};

    my @arguments =
      ( 'bash', "$REPOSITORY_ROOT/secureblue/install-arti-service.bash" );
    push @arguments, '--replace-config' if $options{replace};

    return run_command(
        cmd     => \@arguments,
        env     => $environment,
        timeout => 30,
    );
}

sub create_tar_gz {
    my ( $path, $entries ) = @_;
    local $Archive::Tar::DO_NOT_USE_PREFIX = 1;
    my $tar = Archive::Tar->new();
    for my $entry (@$entries) {
        my $type =
            $entry->{kind} eq 'symlink'  ? Archive::Tar::SYMLINK
          : $entry->{kind} eq 'hardlink' ? Archive::Tar::HARDLINK
          :                                Archive::Tar::FILE;
        my $linkname = $entry->{kind} eq 'symlink' ? '/etc/passwd'  : '';
        my $data     = $entry->{kind} eq 'regular' ? $entry->{data} : '';
        $tar->add_data(
            $entry->{name},
            $data,
            {
                mode     => oct("755"),
                type     => $type,
                linkname => $linkname,
            }
        ) or die $tar->error;
    }
    $tar->write( $path, Archive::Tar::COMPRESS_GZIP ) or die $tar->error;
    return $path;
}

subtest 'arti install transactions' => sub {
    plan skip_all => 'SecureBlue helper targets Linux' unless is_linux();

    subtest 'preserves config and escapes paths' => sub {
        my $root   = new_tempdir('arti-install-');
        my $config = "$root/config & # % \$ space/arti/arti.toml";
        write_file( $config, "# retained\n[storage]\n" );
        my $result = run_installer($root);
        is( $result->{returncode}, 0, 'installer succeeds' )
          or diag $result->{stderr} . $result->{stdout};
        is( slurp($config), "# retained\n[storage]\n", 'config is preserved' );

        my $unit =
          slurp("$root/config & # % \$ space/systemd/user/arti.service");
        ok(
            index( $unit, '%% $$ space/arti/arti.toml" proxy' ) >= 0,
            'unit escapes percent, spaces, and command dollars'
        );
        ok( index( $unit, '%h/' ) < 0,
            'unit has no unresolved home placeholder' );
    };

    subtest 'activation failure restores both files' => sub {
        my $root   = new_tempdir('arti-rollback-');
        my $base   = "$root/config & # % \$ space";
        my $config = "$base/arti/arti.toml";
        my $unit   = "$base/systemd/user/arti.service";
        write_file( $config, "# original\n[storage]\n" );
        write_file( $unit,   "# original unit\n" );
        my $result = run_installer( $root, fail => 1, replace => 1 );
        isnt( $result->{returncode}, 0, 'activation failure fails the run' );
        is( slurp($config), "# original\n[storage]\n", 'config is restored' );
        is( slurp($unit),   "# original unit\n",       'unit is restored' );
        is_deeply( [ find_matching( $base, qr/\.new\./ ) ],
            [], 'no destination temporaries remain' );
    };

    subtest 'malformed download does not replace unit' => sub {
        my $root = new_tempdir('arti-malformed-');
        my $unit = "$root/config & # % \$ space/systemd/user/arti.service";
        write_file( $unit, "# original unit\n" );
        my $result = run_installer( $root, malformed => 1 );
        isnt( $result->{returncode}, 0, 'malformed download fails the run' );
        is( slurp($unit), "# original unit\n", 'unit is unchanged' );
    };
};

subtest 'website transaction helpers' => sub {
    subtest 'term exits and releases owned lock' => sub {
        plan skip_all => 'bash is not installed'
          unless defined find_command('bash');
        my $script    = slurp("$REPOSITORY_ROOT/debian/sync-website.bash");
        my $functions = join "\n\n",
          map { extract_function( $script, $_ ) }
          qw(acquire_lock cleanup_lock rollback_publication finish_git_stage);
        my $root     = new_tempdir('website-term-');
        my $commands = <<'SH';
WWW_DIR=$1
ATOMIC_PREVIOUS=''
acquire_lock
trap cleanup_lock EXIT
trap 'exit 143' TERM
kill -TERM $$
touch "$2"
SH
        my $marker = "$root/continued";
        my $result = run_command(
            cmd => [
                'bash', '-eu',          '-c', $functions . "\n" . $commands,
                'test', "$root/public", $marker
            ],
            timeout => 20,
        );
        is( $result->{returncode}, 143, 'TERM exits with status 143' )
          or diag $result->{stderr};
        ok( !-e $marker,                   'commands after TERM are not run' );
        ok( !-e "$root/.public.sync.lock", 'owned lock is released' );
    };

    subtest 'post update steps fails when chmod fails' => sub {
        my $script   = slurp("$REPOSITORY_ROOT/debian/sync-website.bash");
        my $function = extract_function( $script, 'post_update_steps' );
        my $root     = new_tempdir('website-chmod-');
        my $commands = <<'SH';
log() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
chown() { :; }
find() { return 1; }
systemctl() { :; }
WWW_DIR=$1
OWNER_USER=unused
OWNER_GROUP=unused
SERVICE_NAME=unused
if post_update_steps; then exit 99; fi
SH
        my $result = run_command(
            cmd => [
                'bash', '-eu', '-c', $function . "\n" . $commands,
                'test', $root
            ],
            timeout => 20,
        );
        is( $result->{returncode}, 0, 'conditional failure is handled' )
          or diag $result->{stderr};
        unlike( $result->{stdout}, qr/exit 99/, 'failure is not masked' );
    };

    subtest 'certificate reload failure is reported' => sub {
        my $root     = new_tempdir('website-cert-restart-');
        my $script   = slurp("$REPOSITORY_ROOT/debian/sync-website.bash");
        my $function = extract_function( $script, 'post_update_steps' );
        my $commands = <<'SH';
log() { :; }
warn() { :; }
error() { :; }
chown() { :; }
find() { :; }
systemctl() { :; }
certbot() { :; }
restart_web_service() { return 1; }
WWW_DIR=$1
OWNER_USER=unused
OWNER_GROUP=unused
SERVICE_NAME=apache2
post_update_steps
SH
        my $result = run_command( cmd =>
              [ 'bash', '-eu', '-c', "$function\n$commands", 'test', $root ], );
        isnt( $result->{returncode}, 0, 'failed second restart fails rollout' );
    };

    subtest 'atomic publication and rollback' => sub {
        plan skip_all => 'Debian helper uses GNU mv' unless is_linux();
        exercise_atomic( 'debian/sync-website.bash', 'bash' );
    };

    subtest 'openbsd atomic publication and rollback' => sub {
        plan skip_all => 'ksh is not installed'
          unless defined find_command('ksh');
        exercise_atomic( 'openbsd/sync-website.ksh', 'ksh' );
    };
};

sub exercise_atomic {
    my ( $relative_script, $shell ) = @_;
    my $script    = slurp("$REPOSITORY_ROOT/$relative_script");
    my $functions = join "\n\n", map { extract_function( $script, $_ ) } qw(
      filter_site_tree
      has_repo_content
      reject_source_symlinks
      copy_from_source
      check_atomic_target
      replace_public_link
      rollback_publication
      stage_from_source
      acquire_lock
      cleanup_lock
      finish_git_stage
    );
    my $root   = new_tempdir('website-atomic-');
    my $old    = "$root/old";
    my $source = "$root/source";
    make_path( $old, $source );
    write_file( "$old/index.html",    'old' );
    write_file( "$source/index.html", 'new' );
    write_file( "$source/AGENTS.md",  'private' );
    my $public = "$root/public";
    symlink( $old, $public ) or die "cannot create public symlink: $!";

    my $commands = <<'SH';
log() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
chown() { :; }
restart_web_service() { :; }
ATOMIC_DEPLOY=1
ATOMIC_PREVIOUS=''
ATOMIC_RELEASE=''
OWNER_USER=unused
OWNER_GROUP=unused
WWW_DIR=$1
acquire_lock
[ "$LOCKDIR" != "$WWW_DIR/.sync.lock" ]
status=0
acquire_lock || status=$?
[ "$status" -eq 2 ]
stage_from_source "$2"
[ "$(cat "$WWW_DIR/index.html")" = new ]
[ ! -e "$WWW_DIR/AGENTS.md" ]
rollback_publication
[ "$(cat "$WWW_DIR/index.html")" = old ]
cleanup_lock
[ ! -e "$LOCKDIR" ]
SH

    my $environment = env_with(
        PERL_CMD      => find_command('perl') // 'perl',
        RENAME_HELPER => "$REPOSITORY_ROOT/openbsd/rename-link.pl",
    );
    my $result = run_command(
        cmd => [
            $shell, '-eu',   '-c', $functions . "\n" . $commands,
            'test', $public, $source
        ],
        env     => $environment,
        timeout => 20,
    );
    is( $result->{returncode}, 0, "$relative_script publishes and rolls back" )
      or diag $result->{stderr} . $result->{stdout};
    return;
}

subtest 'xerj publication' => sub {
    plan skip_all => 'SecureBlue helper targets Linux' unless is_linux();

    my $script    = slurp("$REPOSITORY_ROOT/secureblue/update-xerj.bash");
    my $functions = join "\n\n",
      map { extract_function( $script, $_ ) } qw(error log install_xerj);
    my $root     = new_tempdir('xerj-publication-');
    my $fixtures = "$root/fixtures";
    make_path($fixtures);

    my $asset      = 'xerj-1.0.0-x86_64-unknown-linux-musl.tar.gz';
    my $executable = "#!/bin/sh\nprintf '%s\\n' 'xerj v1.0.0'\n";
    create_tar_gz(
        "$fixtures/$asset",
        [
            {
                name => 'xerj-1.0.0-x86_64-unknown-linux-musl/xerj',
                data => $executable,
                kind => 'regular',
            }
        ]
    );
    my $digest = sha256_hex( slurp("$fixtures/$asset") );
    write_file( "$fixtures/$asset.sha256", "$digest  $asset\n" );

    my $mocks = "$root/mocks";
    make_path($mocks);
    write_file( "$mocks/curl", <<'SH' );
#!/bin/sh
while [ "$#" -gt 0 ]; do
 case "$1" in
 https://*) url=$1;;
 -o) shift; target=$1;;
 esac
 shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
case "$url" in
 https://github.com/xerj-org/xerj/releases/latest)
  printf '%s' "$RELEASE_URL"
  exit "$LATEST_EXIT";;
 https://github.com/xerj-org/xerj/releases/download/v1.0.0/*) ;;
 *) exit 22;;
esac
cp "$FIXTURES/${url##*/}" "$target"
SH
    chmod oct("755"), "$mocks/curl" or die "cannot chmod curl mock: $!";
    write_file( "$mocks/gh", <<'SH' );
#!/bin/sh
[ "$#" = 6 ] && [ "$1 $2 $3 $4 $5" = 'release verify-asset -R github.com/xerj-org/xerj v1.0.0' ] &&
 [ -f "$6" ] && [ "${ATTEST_OK:-0}" = 1 ]
SH
    chmod oct("755"), "$mocks/gh" or die "cannot chmod gh mock: $!";

    my $environment = env_with(
        HOME               => $root,
        FIXTURES           => $fixtures,
        VERIFY_ATTESTATION => 0,
        CURL_LOG           => "$root/curl.log",
        RELEASE_URL => 'https://github.com/xerj-org/xerj/releases/tag/v1.0.0',
        LATEST_EXIT => 0,
        PERL_CMD    => find_command('perl') // 'perl',
        RELEASE_HELPER => "$REPOSITORY_ROOT/scripts/release-verify.pl",
    );
    $environment->{PATH} = $mocks . ':' . $ENV{PATH};

    my $commands =
      "\nVERSION=v1.0.0\nTMP_DIR=''\nBINARY_STAGE=''\ninstall_xerj\n";
    make_path("$root/.local/bin");
    write_file( "$root/.local/bin/xerj", "old binary\n" );
    my $attest = sub {
        my ($valid) = @_;
        return run_command(
            cmd => [ 'bash', '-eu', '-c', $functions . $commands ],
            env =>
              { %$environment, VERIFY_ATTESTATION => 1, ATTEST_OK => $valid }
        )->{returncode};
    };
    isnt( $attest->(0), 0, 'failed attestation rejects the replacement' );
    is( slurp("$root/.local/bin/xerj"), "old binary\n", 'old binary intact' );
    is( $attest->(1),                   0, 'verified replacement succeeds' );
    my $results = run_concurrent(
        [
            map {
                {
                    cmd => [ 'bash', '-eu', '-c', $functions . $commands ],
                    env => $environment,
                }
            } 1 .. 2
        ],
        20,
    );

    for my $index ( 0 .. $#$results ) {
        is( $results->[$index]{returncode},
            0, "concurrent installer $index succeeds" )
          or diag $results->[$index]{stdout} . $results->[$index]{stderr};
    }
    is( slurp("$root/.local/bin/xerj"),
        $executable, 'published binary is intact' );
    is_deeply( [ matching_entries( "$root/.local/bin", qr/./ ) ],
        ['xerj'], 'only the new binary remains after replacement' );
    unlike( slurp("$root/curl.log"), qr{/releases/latest},
        'pinned versions bypass release discovery' );

    my $latest_commands =
      "\nVERSION=''\nTMP_DIR=''\nBINARY_STAGE=''\ninstall_xerj\n";
    my $latest = run_command(
        cmd => [ 'bash', '-eu', '-c', $functions . $latest_commands ],
        env => $environment,
    );
    is( $latest->{returncode}, 0, 'latest installs without GitHub API' )
      or diag $latest->{stdout} . $latest->{stderr};
    like(
        slurp("$root/curl.log"),
        qr{https://github.com/xerj-org/xerj/releases/latest},
        'latest uses public release redirect'
    );

    for my $url (
        'https://example.com/xerj-org/xerj/releases/tag/v1.0.0',
        'https://github.com/xerj-org/xerj/releases/latest',
        'https://github.com/xerj-org/xerj/releases/tag/v1.0.0?x=1',
      )
    {
        write_file( "$root/curl.log", '' );
        my $result = run_command(
            cmd => [ 'bash', '-eu', '-c', $functions . $latest_commands ],
            env => { %$environment, RELEASE_URL => $url },
        );
        isnt( $result->{returncode}, 0, 'unexpected release URL rejected' );
        unlike( slurp("$root/curl.log"), qr{/download/},
            'invalid redirect does not download assets' );
        is( slurp("$root/.local/bin/xerj"),
            $executable, 'invalid redirect preserves installed binary' );
    }
    my $failure = run_command(
        cmd => [ 'bash', '-eu', '-c', $functions . $latest_commands ],
        env => { %$environment, LATEST_EXIT => 22 },
    );
    isnt( $failure->{returncode}, 0, 'release lookup failure is propagated' );
    is( slurp("$root/.local/bin/xerj"),
        $executable, 'lookup failure preserves installed binary' );

    create_tar_gz(
        "$fixtures/$asset",
        [
            {
                name => 'xerj-1.0.0-x86_64-unknown-linux-musl/xerj',
                data => "#!/bin/sh\nprintf '%s\\n' 'xerj v9.9.0'\n",
                kind => 'regular',
            }
        ]
    );
    $digest = sha256_hex( slurp("$fixtures/$asset") );
    write_file( "$fixtures/$asset.sha256", "$digest  $asset\n" );
    my $wrong_version = run_command(
        cmd => [ 'bash', '-eu', '-c', $functions . $commands ],
        env => $environment,
    );
    isnt( $wrong_version->{returncode},
        0, 'binary version mismatch is rejected' );
    is( slurp("$root/.local/bin/xerj"),
        $executable, 'version mismatch preserves installed binary' );
    is_deeply( [ matching_entries( "$root/.local/bin", qr/^xerj\.new/ ) ],
        [], 'failed version check removes staging file' );
};

subtest 'xerj client configuration stages edits without backups' => sub {
    plan skip_all => 'The configuration helper uses Linux directory locks'
      unless is_linux();
    my $root   = new_tempdir('xerj-config-');
    my $helper = "$REPOSITORY_ROOT/secureblue/xerj-config.pl";
    for my $client (qw(crush opencode)) {
        my $dir = "$root/$client";
        make_path($dir);
        my $config = $client eq 'crush' ? "$dir/crushrc" : "$dir/opencode.json";
        my $content =
          $client eq 'crush' ? "# retained\n" : '{"theme":"retained"}';
        write_file( $config,                $content );
        write_file( "$config.bak.previous", 'previous copy' );
        my $cmd = [
            $^X, $helper, $client, '/tmp/path with spaces/xerj',
            'http://127.0.0.1:9200'
        ];
        my $env   = env_with( XDG_CONFIG_HOME => $root, HOME => $root );
        my $first = run_command( cmd => $cmd, env => $env );
        is( $first->{returncode}, 0, "configure $client" )
          or diag $first->{stderr};
        my $published = slurp($config);
        like( $published, qr/retained/, "$client retains existing settings" );
        my $second = run_command( cmd => $cmd, env => $env );
        is( $second->{returncode}, 0,  "configure $client again" );
        is( $second->{stdout},     '', "$client skips the unchanged write" );
        is( slurp($config),        $published, "$client settings are stable" );
        is_deeply(
            [ matching_entries( $dir, qr/\.bak\./ ) ],
            [
                ( $client eq 'crush' ? 'crushrc' : 'opencode.json' )
                . '.bak.previous'
            ],
            "$client creates no backups"
        );
        is(
            slurp("$config.bak.previous"),
            'previous copy',
            "$client preserves existing backup contents"
        );
        is_deeply( [ matching_entries( $dir, qr/^\.xerj-/ ) ],
            [], "$client leaves no staging files" );
    }
};

subtest 'Swival TOML registration validates private candidates' => sub {
    plan skip_all => 'The configuration helper uses Linux directory locks'
      unless is_linux();
    my $root   = new_tempdir('xerj-swival-');
    my $client = "$root/swival";
    my $config = "$root/xdg/swival/config.toml";
    my $helper = "$REPOSITORY_ROOT/secureblue/xerj-config.pl";
    make_path("$root/xdg/swival");
    write_file( $client, <<'SWIVAL' );
#!/bin/sh
set -eu
[ "$1" = --list-profiles ] && [ "$2" = --base-dir ] && [ -d "$3" ]
case "$XDG_CONFIG_HOME" in */.xerj-swival-*) ;; *) exit 5 ;; esac
file="$XDG_CONFIG_HOME/swival/config.toml"
if grep -q INVALID_TOML "$file"; then exit 6; fi
[ "$(grep -c '^\[mcp_servers\.xerj\]$' "$file")" -lt 2 ]
SWIVAL
    chmod oct('700'), $client or die "$client: $!";
    my $run = sub {
        my ($endpoint) = @_;
        return run_command(
            cmd => [
                $^X,       $helper,
                'swival',  '/opt/xerj test/xerj',
                $endpoint, $client
            ],
            env => env_with(
                HOME            => $root,
                XDG_CONFIG_HOME => "$root/xdg",
                XERJ_AUTH       => 'synthetic-secret'
            ),
        );
    };
    my $url = 'http://localhost:9200';
    is( $run->($url)->{returncode}, 0, 'created missing Swival config' );
    is( ( stat($config) )[2] & oct('777'),
        oct('600'), 'new Swival configuration is private' );
    my $original = <<'TOML';
commands = "ask"
[profiles.local]
provider = "generic"
model = "retained"
base_url = "http://127.0.0.1:8080"
TOML
    write_file( $config, $original );
    is( $run->($url)->{returncode}, 0, 'registered Swival' );
    my $first = slurp($config);
    is( substr( $first, 0, length($original) ), $original, 'retained TOML' );
    like( $first, qr/\[mcp_servers\.xerj\]/, 'uses native schema' );
    unlike( $first, qr/synthetic-secret/, 'does not write credentials' );
    is( $run->($url)->{returncode}, 0,      'same endpoint is idempotent' );
    is( slurp($config),             $first, 'no duplicate Swival block' );
    is( $run->('https://example.org')->{returncode}, 0, 'updated endpoint' );
    like( slurp($config), qr{https://example\.org}, 'replaced managed URL' );
    my $read_only = slurp($config);
    chmod oct('400'), $config or die "$config: $!";
    isnt( $run->($url)->{returncode}, 0, 'read-only config fails safely' );
    is( slurp($config), $read_only, 'read-only TOML stays intact' );
    chmod oct('600'), $config or die "$config: $!";

    for
      my $bad ( "INVALID_TOML\n", "[mcp_servers.xerj]\ncommand = \"other\"\n" )
    {
        write_file( $config, $bad );
        isnt( $run->($url)->{returncode}, 0, 'unsafe config is rejected' );
        is( slurp($config), $bad, 'unsafe config remains byte-identical' );
    }
    is_deeply( [ matching_entries( "$root/xdg/swival", qr/^\.xerj-/ ) ],
        [], 'validation and update leave no staging artifacts' );
};

subtest 'xerj MCP selections and ownership checks' => sub {
    plan skip_all => 'The xerj updaters require Linux' unless is_linux();
    my $root   = new_tempdir('xerj-mcp-');
    my $helper = "$REPOSITORY_ROOT/secureblue/xerj-config.pl";
    my $binary = '/opt/Tool Path/xerj';
    my $url    = 'http://127.0.0.1:9200';
    my $env    = env_with(
        HOME                => $root,
        XDG_CONFIG_HOME     => "$root/config",
        COPILOT_HOME        => "$root/copilot",
        CLAUDE_CONFIG_DIR   => "$root/claude",
        CRUSH_GLOBAL_CONFIG => "$root/crush",
    );
    my $run = sub {
        my ( $client, $endpoint, $stdin ) = @_;
        return run_command(
            cmd   => [ $^X, $helper, $client, $binary, $endpoint // $url ],
            env   => $env,
            stdin => $stdin,
        );
    };
    for my $spec (
        [ 'copilot-cli', 'copilot/mcp-config.json', 'local' ],
        [ 'claude',      'claude/.claude.json',     'stdio' ],
      )
    {
        my ( $client, $relative, $transport ) = @$spec;
        my $path = "$root/$relative";
        is( $run->($client)->{returncode}, 0, "$client registers new server" );
        my $data   = JSON::PP::decode_json( slurp($path) );
        my $server = $data->{mcpServers}{xerj};
        is( $server->{type},    $transport, "$client uses official transport" );
        is( $server->{command}, $binary,    "$client stores absolute command" );
        is_deeply( $server->{args}, [ 'mcp', '--url', $url ], "$client args" );
        $server->{timeout} = 321;
        $data->{other}     = { retained => JSON::PP::true };
        write_file( $path, JSON::PP::encode_json($data) );
        my $new_url = 'https://example.org:9201/search';
        is( $run->( $client, $new_url )->{returncode},
            0, "$client updates URL" );
        $data = JSON::PP::decode_json( slurp($path) );
        is( $data->{mcpServers}{xerj}{args}[2], $new_url, "$client new URL" );
        is( $data->{mcpServers}{xerj}{timeout}, 321,
            "$client retains timeout" );
        ok( $data->{other}{retained}, "$client retains unrelated settings" );
        my $foreign =
          '{"mcpServers":{"xerj":{"type":"http","url":"https://localhost"}}}';
        write_file( $path, $foreign );
        isnt( $run->($client)->{returncode}, 0,
            "$client rejects foreign xerj" );
        is( slurp($path), $foreign, "$client leaves foreign server untouched" );
    }
    my $opencode = "$root/config/opencode/opencode.json";
    make_path("$root/config/opencode");
    my $legacy = {
        mcp => {
            xerj => {
                type    => 'local',
                command => [ $binary, 'mcp', '--url', $url ],
                enabled => JSON::PP::false,
            }
        },
    };
    write_file( $opencode, JSON::PP::encode_json($legacy) );
    is( $run->('opencode2')->{returncode},
        0, 'OpenCode 2 migrates known entry' );
    my $data = JSON::PP::decode_json( slurp($opencode) );
    ok( !exists $data->{mcp}{xerj}, 'OpenCode legacy entry removed' );
    ok( $data->{mcp}{servers}{xerj}{disabled}, 'OpenCode stays disabled' );
    my $ambiguous = '{"mcp":{"servers":{},"servers":{}}}';
    write_file( $opencode, $ambiguous );
    isnt( $run->('opencode2')->{returncode}, 0, 'Duplicate JSON key rejected' );
    is( slurp($opencode), $ambiguous,     'Duplicate-key file preserved' );
    is( $run->('crush')->{returncode}, 0, 'Crush honors config directory' );
    my $crush    = "$root/crush/crushrc";
    my $previous = slurp($crush);
    write_file( "$root/crush/crush.json", '{"mcp":{"xerj":{}}}' );
    isnt( $run->('crush')->{returncode},
        0, 'Crush refuses shadowing legacy xerj' );
    is( slurp($crush), $previous, 'Crush preserves existing managed block' );
    write_file( "$root/crush/crush.json", '{}' );
    my $bad_shell = "if true; then\n# possible secret\n";
    write_file( $crush, $bad_shell );
    my $bad_config = $run->('crush');
    isnt( $bad_config->{returncode}, 0,
        'Crush rejects malformed shell config' );
    unlike( $bad_config->{stderr}, qr/secret/,
        'Syntax check hides file content' );
    is( slurp($crush), $bad_shell, 'Malformed Crush config stays untouched' );
    my $codex = {
        transport => {
            type    => 'stdio',
            command => $binary,
            args    => [ 'mcp', '--url', $url ],
        },
    };
    my $result = $run->( 'codex-check', $url, JSON::PP::encode_json($codex) );
    is( $result->{stdout}, "current\n", 'Codex exact tuple is a no-op' );
    my $payload = JSON::PP::encode_json($codex);
    $result = $run->( 'codex-check', 'http://localhost:9300', $payload );
    isnt( $result->{returncode}, 0, 'Codex changed URL requires manual edit' );
    $codex->{transport}{args}[1] = '--unrelated';
    $result = $run->( 'codex-check', $url, JSON::PP::encode_json($codex) );
    isnt( $result->{returncode}, 0,
        'Codex exact command with foreign args fails' );

    for my $platform (qw(debian secureblue)) {
        my $script = "$REPOSITORY_ROOT/$platform/update-xerj.bash";
        for my $args (
            [qw(all claude)],
            [qw(--binary-only copilot-cli)],
            [ '--url', 'https://token@localhost' ],
            [ '--url', 'http://localhost:99999' ]
          )
        {
            $result = run_command( cmd => [ $script, @$args ], env => $env );
            is( $result->{returncode}, 2,
                "$platform rejects invalid selection" );
            unlike( $result->{stderr}, qr/token\@/, "$platform hides raw URL" );
        }
    }
    my $clients = "$REPOSITORY_ROOT/scripts/xerj-clients.bash";
    my $probe   = write_file( "$root/version-probe", <<'SH' );
#!/bin/sh
test "$1" = --version || exit 1
printf '%s\n' "$XERJ_TEST_BANNER"
SH
    chmod oct('755'), $probe or die "cannot chmod version probe: $!";
    my $invoke = '. "$1"; xerj_config_kind "$2" "$3"';
    for my $case (
        [ 'opencode', 'opencode v2.4.1',             0, 'opencode2' ],
        [ 'opencode', '1.0.0',                       0, 'opencode1' ],
        [ 'opencode', 'opencode v3.0.0',             2, '' ],
        [ 'crush',    "logo\ncrush version v0.88.0", 0, 'crush' ],
        [ 'crush',    'crush version v0.87.0',       2, '' ],
      )
    {
        my ( $agent, $banner, $status, $schema ) = @$case;
        $result = run_command(
            cmd => [ 'bash', '-c', $invoke, 'xerj', $clients, $agent, $probe ],
            env => { %$env, XERJ_TEST_BANNER => $banner },
        );
        is( $result->{returncode}, $status, "$banner compatibility status" );
        is( trim( $result->{stdout} ), $schema,
            "$banner configuration schema" );
    }
    $result = run_command(
        cmd => [
            'bash', '-c',
            '. "$1"; xerj_select --binary-only; xerj_validate_selection',
            'xerj', $clients
        ],
        env => { %$env, XERJ_URL => 'http://user:secret@localhost' },
    );
    is( $result->{returncode}, 0,
        'binary-only ignores irrelevant endpoint env' );
};

subtest 'xerj Debian package selection and verification' => sub {
    plan skip_all => 'The Debian updater targets Linux' unless is_linux();
    my $root   = new_tempdir('xerj-apt-');
    my $script = "$REPOSITORY_ROOT/debian/update-xerj.bash";
    my $code   = functions_without_main($script);
    $code =~ s{readonly XERJ_BIN=/usr/bin/xerj}
              {readonly XERJ_BIN="\${TEST_ROOT}/xerj"};
    my $musl   = 'xerj-1.2.3-rc.7-x86_64-unknown-linux-musl';
    my $native = 'xerj-1.2.3-rc.7-x86_64-unknown-linux-gnu.deb';
    make_path("$root/bin");
    my $perl = find_command('perl') // die 'Cannot locate the harness Perl';
    symlink $perl, "$root/bin/perl" or die "cannot link Perl: $!";
    write_file( "$root/$native", "fake upstream package\n" );
    create_tar_gz(
        "$root/$musl.tar.gz",
        [
            map {
                {
                    name => "$musl/$_",
                    data => "fixture $_\n",
                    kind => 'regular'
                }
            } qw(xerj README.md LICENSE)
        ]
    );
    for my $asset ( $native, "$musl.tar.gz" ) {
        my $digest = sha256_hex( slurp("$root/$asset") );
        write_file( "$root/$asset.sha256", "$digest  $asset\n" );
    }
    my $mock = write_file( "$root/bin/mock", <<'SH' );
#!/bin/sh
set -eu
case ${0##*/} in
curl)
	while [ "$#" -gt 0 ]; do
		case $1 in
		https://github.com/xerj-org/xerj/releases/download/v1.2.3-rc.7/*) url=$1 ;;
		--output) shift; output=$1 ;;
		esac
		shift
	done
	[ "${CURL_OK:-true}" = true ] || exit 22
	if [ "${BAD_CHECKSUM:-false}" = true ] && [ "${url%.sha256}" != "$url" ]; then
		printf 'incorrect checksum\n' >"$output"
	else
		cp "$TEST_ROOT/${url##*/}" "$output"
	fi ;;
dpkg)
	[ "$1" = --compare-versions ]
	case $3 in
	ge) [ "${NATIVE_OK:-true}" = true ] ;;
	gt) false ;;
	*) exit 98 ;;
	esac ;;
dpkg-deb)
	case $1 in
	-f)
		case $3 in
		Package) printf '%s\n' "${PACKAGE_NAME:-xerj}" ;;
		Architecture) printf 'amd64\n' ;;
		Version) printf '1.2.3~rc.7\n' ;;
		Depends) printf 'libc6 (>= 2.43), libgcc-s1\n' ;;
		*) exit 98 ;;
		esac ;;
	--root-owner-group)
		[ "$2" = --build ]
		grep -qx 'Version: 1.2.3~rc.7' "$3/DEBIAN/control"
		grep -qx 'fixture xerj' "$3/usr/bin/xerj"
		grep -qx 'fixture LICENSE' "$3/usr/share/doc/xerj/LICENSE"
		printf 'static Debian package\n' >"$4" ;;
	*) exit 98 ;;
	esac ;;
dpkg-query)
	if [ "$1" = -S ]; then
		printf 'xerj: %s\n' "$2"
	else
		case $3 in
		libc6:amd64) printf 'install ok installed\t2.41\n' ;;
		perl) printf 'install ok installed\t5.40\n' ;;
		xerj) [ -f "$TEST_ROOT/version" ]; printf 'install ok installed\t'; cat "$TEST_ROOT/version" ;;
		*) exit 98 ;;
		esac
	fi ;;
apt-get)
	printf '%s\n' "$*" >>"$TEST_ROOT/apt.log"
	case " $* " in
	*" install "*)
		[ "${APT_OK:-true}" = true ] || exit 100
		printf '1.2.3~rc.7\n' >"$TEST_ROOT/version"
		printf '#!/bin/sh\nprintf "xerj %s\\n"\n' "${TEST_BANNER:-v1.2.3-rc.7}" >"$TEST_ROOT/xerj"
		chmod 0755 "$TEST_ROOT/xerj" ;;
	esac ;;
gh)
	[ "$1 $2 $3 $4 $5" = 'release verify-asset -R github.com/xerj-org/xerj v1.2.3-rc.7' ]
	[ -f "$6" ]
	[ "${ATTEST_OK:-true}" = true ] ;;
sudo)
	[ "$1 $2 $3 $4" = '-H -u fixture-user --' ]
	shift 4
	exec "$@" ;;
*) exit 99 ;;
esac
SH
    chmod oct('755'), $mock or die "cannot chmod xerj mock: $!";
    for my $cmd (qw(curl dpkg dpkg-deb dpkg-query apt-get gh sudo)) {
        link $mock, "$root/bin/$cmd" or die "cannot link $cmd: $!";
    }
    my $baseline = env_with( TEST_ROOT => $root, SUDO_USER => 'fixture-user' );
    $code .= <<'SH';
export PATH="$TEST_ROOT/bin:$PATH"
VERSION=v1.2.3-rc.7
VERIFY_ATTESTATION=${ATTEST:-0}
install_xerj amd64 x86_64
SH
    my $run = sub {
        my (%options) = @_;
        return run_command(
            cmd => [ 'bash', '-c', $code, $script ],
            env => { %$baseline, %options }
        );
    };
    for my $case (
        [ 'network failure',    CURL_OK      => 'false' ],
        [ 'wrong package name', PACKAGE_NAME => 'something-else' ],
        [ 'wrong checksum',     BAD_CHECKSUM => 'true' ],
        [ 'bad attestation',    ATTEST       => 1, ATTEST_OK => 'false' ],
      )
    {
        my ( $label, %options ) = @$case;
        isnt( $run->(%options)->{returncode}, 0, "$label is rejected" );
        ok( !-e "$root/apt.log", "$label leaves APT untouched" );
    }
    isnt( $run->( APT_OK => 'false' )->{returncode},
        0, 'APT failure reaches caller' );
    ok( !-e "$root/xerj", 'failed APT transaction installs nothing' );
    my $installed = $run->( NATIVE_OK => 'false', ATTEST => 1 );
    is( $installed->{returncode}, 0, 'incompatible glibc selects static build' )
      or diag $installed->{stderr} . $installed->{stdout};
    like( slurp("$root/apt.log"), qr/xerj-static\.deb/,
        'APT installs locally packaged static binary' );
    my $apt_calls = slurp("$root/apt.log");
    is( $run->()->{returncode}, 0,          'repeat run succeeds' );
    is( slurp("$root/apt.log"), $apt_calls, 'current binary skips APT' );
    write_file( "$root/version", "1.2.3~rc.6\n" );
    my $updated = $run->();
    is( $updated->{returncode}, 0, 'older release updates via native package' )
      or diag $updated->{stderr};
    like( slurp("$root/apt.log"), qr/\Q$native\E\n\z/,
        'APT receives upstream native Debian package when compatible' );
    write_file( "$root/version", "1.2.3~rc.6\n" );
    isnt( $run->( TEST_BANNER => 'v1.2.3-rc.6' )->{returncode},
        0, 'wrong executable banner makes the update fail' );
};

done_testing();
