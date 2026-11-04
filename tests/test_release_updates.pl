#!/usr/bin/env perl

# Offline release-update regressions; no administrative entry point is run.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use strict;
use warnings;

use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use FindBin     qw($Bin);
use JSON::PP;
use lib $Bin;
use Test::More;

use TestHarness qw(
  env_with
  find_command
  functions_without_main
  is_linux
  matching_entries
  new_tempdir
  repo_root
  run_command
  slurp
  trim
  write_file
);

plan skip_all => 'Linux release updaters require GNU/Linux' unless is_linux();

my $ROOT = repo_root();

sub run_shell {
    my ( $root, $path, $body, %extra ) = @_;
    my $environment = env_with(
        TEST_ROOT      => $root,
        PERL_CMD       => find_command('perl') // 'perl',
        RELEASE_HELPER => "$ROOT/scripts/release-verify.pl",
        %extra,
    );
    return run_command(
        cmd => [
            'bash', '-c', functions_without_main("$ROOT/$path") . "\n" . $body
        ],
        env     => $environment,
        timeout => 20,
    );
}

sub archive {
    my ( $root, $entries ) = @_;
    my $path = "$root/fixture.tar.gz";
    unlink $path if -e $path;
    local $Archive::Tar::DO_NOT_USE_PREFIX = 1;
    my $tar = Archive::Tar->new();
    for my $entry (@$entries) {
        my ( $name, $data, $kind ) = @$entry;
        my $type =
            $kind eq 'symlink'  ? Archive::Tar::SYMLINK
          : $kind eq 'hardlink' ? Archive::Tar::HARDLINK
          :                       Archive::Tar::FILE;
        my $linkname = $kind eq 'symlink' ? '/etc/passwd' : '';
        $tar->add_data(
            $name,
            $kind eq 'regular' ? $data : '',
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

subtest 'release helper parses JSON without inline Perl' => sub {
    my $helper  = "$ROOT/scripts/release-verify.pl";
    my $payload = {
        tag_name => 'v1.2.3',
        assets   => [
            {
                name                 => 'edit-1.2.3-amd64-linux-gnu.tar.gz',
                browser_download_url => 'https://example.invalid/release',
                digest               => 'sha256:' . ( 'a' x 64 ),
            }
        ],
    };
    my $json = JSON::PP->new->utf8->encode($payload);
    my $perl = find_command('perl') // 'perl';

    my $tag = run_command(
        cmd   => [ $perl, $helper, 'json-tag' ],
        stdin => $json,
    );
    is( $tag->{returncode},     0, 'json-tag succeeds' ) or diag $tag->{stderr};
    is( trim( $tag->{stdout} ), 'v1.2.3', 'json-tag prints the release tag' );

    my $url = run_command(
        cmd => [
            $perl,            $helper,
            'json-asset-url', 'edit-1.2.3-amd64-linux-gnu.tar.gz'
        ],
        stdin => $json,
    );
    is( $url->{returncode}, 0, 'json-asset-url succeeds' )
      or diag $url->{stderr};
    is(
        trim( $url->{stdout} ),
        'https://example.invalid/release',
        'json-asset-url prints the matching URL'
    );
};

subtest 'msedit checks digest and exact entry' => sub {
    for my $kind (qw(valid digest duplicate link)) {
        subtest $kind => sub {
            my $root = new_tempdir('release-msedit-');
            my $work = "$root/work";
            make_path($work);
            unlink "$work/edit" if -e "$work/edit";
            my $binary = "$root/bin/edit";
            write_file( $binary, 'previous' );

            my @entries = ( [ 'edit', 'new', 'regular' ] );
            @entries = ( @entries, @entries )        if $kind eq 'duplicate';
            @entries = ( [ 'edit', '', 'symlink' ] ) if $kind eq 'link';
            my $fixture = archive( $root, \@entries );
            my $digest  = sha256_hex( slurp($fixture) );
            $digest = '0' x 64 if $kind eq 'digest';

            my $result = run_shell(
                $root,
                'debian/update-msedit.bash',
                <<'SH',
WORK_DIR="$TEST_ROOT/work"
INSTALL_DIR="$TEST_ROOT/bin"
net_curl() { cp -- "$FIXTURE" "${@: -1}"; }
run_root() { "$@"; }
install_msedit https://github.com/microsoft/edit/releases/download/v2.0.0/fixture "$DIGEST"
SH
                FIXTURE => $fixture,
                DIGEST  => 'sha256:' . $digest,
            );

            my $valid = $kind eq 'valid';
            is(
                $result->{returncode} == 0 ? 1 : 0,
                $valid                     ? 1 : 0,
                "$kind archive outcome"
            ) or diag $result->{stderr};
            is(
                slurp($binary),
                $valid ? 'new' : 'previous',
                "$kind keeps the expected binary"
            );
        };
    }
};

subtest 'btop fallback requires exact safe source tree' => sub {
    for my $kind (qw(valid traversal duplicate link hardlink wrong-root)) {
        subtest $kind => sub {
            my $root    = new_tempdir('release-btop-');
            my @entries = ( [ 'btop-1.0.0/Makefile', "all:\n", 'regular' ] );
            push @entries, [ 'btop-1.0.0/../../outside', 'bad', 'regular' ]
              if $kind eq 'traversal';
            @entries = ( @entries, @entries ) if $kind eq 'duplicate';
            push @entries, [ 'btop-1.0.0/link', '', 'symlink' ]
              if $kind eq 'link';
            push @entries, [ 'btop-1.0.0/link', '', 'hardlink' ]
              if $kind eq 'hardlink';
            @entries = ( [ 'other/Makefile', 'wrong', 'regular' ] )
              if $kind eq 'wrong-root';

            my $fixture     = archive( $root, \@entries );
            my $destination = "$root/source-$kind";
            my $stale       = "$destination/btop-stale";
            write_file( "$stale/Makefile", 'stale' );

            my $result = run_shell(
                $root,
                'debian/update-btop.bash',
                <<'SH',
git() { return 1; }
curl() { cp -- "$FIXTURE" "${@: -1}"; }
fetch_source v1.0.0 "$DESTINATION"
SH
                FIXTURE     => $fixture,
                DESTINATION => $destination,
            );

            my $valid = $kind eq 'valid';
            is(
                $result->{returncode} == 0 ? 1 : 0,
                $valid                     ? 1 : 0,
                "$kind archive outcome"
            ) or diag $result->{stderr};
            if ($valid) {
                my $source = trim( $result->{stdout} );
                isnt( $source, $stale, 'fresh source tree is selected' );
                is( slurp("$source/Makefile"),
                    "all:\n", 'source content is intact' );
            }
            else {
                is_deeply(
                    [ matching_entries( $destination, qr/^btop-source\./ ) ],
                    [], "$kind leaves no source temporary" );
            }
            ok( !-e "$root/outside",
                'nothing is written outside the destination' );
        };
    }
};

subtest 'btop preparation failure is checked in conditional context' => sub {
    my $root = new_tempdir('release-btop-failure-');
    my $fixture =
      archive( $root, [ [ 'btop-1.0.0/Makefile', 'safe', 'regular' ] ] );

    for my $failure (qw(download mktemp)) {
        subtest $failure => sub {
            my $destination = "$root/$failure";
            make_path($destination);
            write_file( "$destination/btop.tar.gz", slurp($fixture) );

            my $result = run_shell(
                $root,
                'debian/update-btop.bash',
                <<'SH',
cd "$TEST_ROOT"
git() { return 1; }
curl() {
    [[ $FAILURE != download ]] || return 1
    cp -- "$FIXTURE" "${@: -1}"
}
mktemp() { return 1; }
if fetch_source v1.0.0 "$DESTINATION"; then exit 99; fi
SH
                FIXTURE     => $fixture,
                DESTINATION => $destination,
                FAILURE     => $failure,
            );

            is( $result->{returncode}, 0,
                "$failure is handled in a conditional" )
              or diag $result->{stderr};
            ok( !-e "$root/btop-1.0.0",
                "$failure does not leave a source tree" );
        };
    }
};

subtest 'rustup native installer checks digest before execution' => sub {
    my $root      = new_tempdir('release-rustup-');
    my $installer = "$root/rustup-fixture";
    write_file( $installer, <<'SH' );
#!/bin/sh
mkdir -p "$HOME/.cargo/bin"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.cargo/bin/cargo"
chmod 700 "$HOME/.cargo/bin/cargo"
: >"$HOME/rustup-executed"
SH
    my $digest = sha256_hex( slurp($installer) );

    for my $valid ( 0, 1 ) {
        my $label = $valid ? 'valid' : 'invalid';
        subtest $label => sub {
            my $home = "$root/home-$valid";
            make_path( $home, "$home/tmp" );

            my $result = run_shell(
                $root,
                'secureblue/update-arti-oniux.bash',
                <<'SH',
HOME=$FAKE_HOME
export HOME TMPDIR="$HOME/tmp"
ensure_brew_path() { return 0; }
command() {
    if [[ ${1:-} == -v ]]; then
        case "${2:-}" in
        cargo) [[ -f $HOME/rustup-executed ]] || return 1 ;;
        rustc|brew|brew-proxy) return 1 ;;
        esac
    fi
    builtin command "$@"
}
uname() { printf 'x86_64\n'; }
curl() {
    printf '%s\n' "$*" >>"$HOME/downloads"
    if [[ $* == *rustup-init.sha256* ]]; then
        printf '%s  rustup-init\n' "$DIGEST" >"${@: -1}"
    else cp -- "$FIXTURE" "${@: -1}"; fi
}
RUSTUP_VERSION=1.29.3
ensure_rust
SH
                FIXTURE   => $installer,
                DIGEST    => $valid ? $digest : ( '0' x 64 ),
                FAKE_HOME => $home,
            );

            is(
                $result->{returncode} == 0 ? 1 : 0,
                $valid                     ? 1 : 0,
                'digest outcome'
            ) or diag $result->{stderr};
            is(
                -e "$home/rustup-executed" ? 1 : 0,
                $valid                     ? 1 : 0,
                'installer only runs with a valid digest'
            );
            like(
                slurp("$home/downloads"),
qr{/rustup/archive/1\.29\.3/x86_64-unknown-linux-gnu/rustup-init},
                'release URL uses the requested version and architecture'
            );
            is_deeply( [ matching_entries( "$home/tmp", qr/./ ) ],
                [], 'temporary directory is cleaned' );
        };
    }
};

subtest 'argon validates both scripts before first execution' => sub {
    my $root   = new_tempdir('release-argon-two-');
    my $script = "$root/first.sh";
    write_file( $script, "#!/bin/sh\n: >\"\$TEST_ROOT/executed\"\n" );
    my $digest = sha256_hex( slurp($script) );

    my $result = run_shell(
        $root,
        'debian/update-argon-one-v3.bash',
        <<'SH',
EEPROM_SHA256=$DIGEST
CONTROL_SHA256=$(printf '%064d' 0)
ARGON_EEPROM_SCRIPT=$FIXTURE
ARGON_CONTROL_SCRIPT=$FIXTURE
ask_reboot() { :; }
run_update
SH
        DIGEST  => $digest,
        FIXTURE => $script,
    );

    isnt( $result->{returncode}, 0, 'control script digest failure is fatal' );
    ok( !-e "$root/executed", 'neither script is executed' );
};

sub go_update {
    my ( $root, $failure, $bad_digest ) = @_;
    my $installation = "$root/install";
    write_file( "$installation/go/previous", 'keep' );
    my $fixture = archive(
        $root,
        [
            [
                'go/bin/go',
                "#!/bin/sh\nprintf 'go version go1.99.1 linux/amd64\\n'\n",
                'regular'
            ]
        ]
    );
    my $digest   = sha256_hex( slurp($fixture) );
    my $metadata = "$root/release.json";
    write_file(
        $metadata,
        JSON::PP->new->utf8->encode(
            [
                {
                    files => [
                        {
                            filename => 'go1.99.1.linux-amd64.tar.gz',
                            sha256   => $bad_digest ? ( '0' x 64 ) : $digest,
                        }
                    ],
                }
            ]
        )
    );

    my $result = run_shell(
        $root,
        'debian/update-golang.bash',
        <<'SH',
INSTALL_DIR="$TEST_ROOT/install"
GO_ROOT="$INSTALL_DIR/go"
get_latest_go_version() { printf 'go1.99.1'; }
detect_go_arch() { printf 'amd64'; }
ensure_go_path_in_etc_profile() { :; }
net_curl() {
    if [[ $* == *mode=json* ]]; then cp -- "$METADATA" "${@: -1}";
    else cp -- "$FIXTURE" "${@: -1}"; fi
}
mv() {
    if [[ $FAILURE == activate && ${3:-} == *'.go-install.'*/go ]]; then return 1; fi
    command mv "$@"
    if [[ $FAILURE == signal && ${3:-} == "$GO_ROOT" ]]; then kill -TERM "$$"; fi
}
run_golang_update
SH
        FIXTURE  => $fixture,
        METADATA => $metadata,
        FAILURE  => $failure // '',
    );
    return ( $result, $installation );
}

subtest 'go success preserves backup and cleans transaction' => sub {
    my $root = new_tempdir('release-go-success-');
    my ( $result, $installation ) = go_update($root);
    is( $result->{returncode}, 0, 'update succeeds' ) or diag $result->{stderr};
    ok( -f "$installation/go/bin/go", 'new Go binary is active' );
    my @backups       = matching_entries( $installation, qr/^\.go-backup\./ );
    my @with_previous = grep { -f "$installation/$_/go/previous" } @backups;
    is( scalar @with_previous, 1, 'one backup contains the previous Go tree' );
    is_deeply( [ matching_entries( $installation, qr/^\.go-install\./ ) ],
        [], 'staging directory is removed' );
    ok( !-e "$installation/.go-update.lock", 'update lock is released' );
};

subtest 'go activation failure restores original' => sub {
    my $root = new_tempdir('release-go-activate-');
    my ( $result, $installation ) = go_update( $root, 'activate' );
    isnt( $result->{returncode}, 0, 'activation failure is fatal' );
    is( slurp("$installation/go/previous"),
        'keep', 'previous tree is restored' );
    ok( !-e "$installation/.go-update.lock", 'update lock is released' );
};

subtest 'go signal during activation restores original' => sub {
    my $root = new_tempdir('release-go-signal-');
    my ( $result, $installation ) = go_update( $root, 'signal' );
    is( $result->{returncode}, 143, 'TERM exits with status 143' )
      or diag $result->{stderr};
    is( slurp("$installation/go/previous"),
        'keep', 'previous tree is restored' );
    ok( !-e "$installation/.go-update.lock", 'update lock is released' );
};

subtest 'go digest failure keeps original' => sub {
    my $root = new_tempdir('release-go-digest-');
    my ( $result, $installation ) = go_update( $root, '', 1 );
    isnt( $result->{returncode}, 0, 'digest failure is fatal' );
    is( slurp("$installation/go/previous"),
        'keep', 'previous tree is preserved' );
};

subtest 'argon local reviewed scripts require matching digest' => sub {
    my $root   = new_tempdir('release-argon-local-');
    my $source = "$root/reviewed.sh";
    write_file( $source, "#!/bin/bash\nexit 0\n" );
    my $digest = sha256_hex( slurp($source) );

    for my $expected ( $digest, '0' x 64 ) {
        my $result = run_shell(
            $root,
            'debian/update-argon-one-v3.bash',
'download_remote_script unused "$TEST_ROOT/pending.sh" "$DIGEST" "$FIXTURE"',
            DIGEST  => $expected,
            FIXTURE => $source,
        );
        my $valid = $expected eq $digest;
        is(
            $result->{returncode} == 0 ? 1         : 0,
            $valid                     ? 1         : 0,
            $valid ? 'matching digest is accepted' : 'wrong digest is rejected'
        ) or diag $result->{stderr};
    }
};

done_testing();
