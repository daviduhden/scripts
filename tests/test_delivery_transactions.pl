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
use lib $Bin;
use Test::More;

use TestHarness qw(
  env_with
  extract_function
  find_command
  find_matching
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
          qw(acquire_lock cleanup_lock rollback_publication);
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
if acquire_lock; then exit 10; fi
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
    my $executable = "#!/bin/sh\nexit 0\n";
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
cp "$FIXTURES/${url##*/}" "$target"
SH
    chmod oct("755"), "$mocks/curl" or die "cannot chmod curl mock: $!";

    my $environment = env_with(
        HOME           => $root,
        FIXTURES       => $fixtures,
        PERL_CMD       => find_command('perl') // 'perl',
        RELEASE_HELPER => "$REPOSITORY_ROOT/scripts/release-verify.pl",
    );
    $environment->{PATH} = $mocks . ':' . $ENV{PATH};

    my $commands =
      "\nVERSION=v1.0.0\nTMP_DIR=''\nBINARY_STAGE=''\ninstall_xerj\n";
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
    is_deeply( [ matching_entries( "$root/.local/bin", qr/^xerj\.new/ ) ],
        [], 'no destination temporaries remain' );
};

done_testing();
