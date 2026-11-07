#!/usr/bin/env perl

# Exercise website staging filters against disposable filesystem trees.
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
  env_with
  extract_function
  find_command
  list_tree
  new_tempdir
  repo_root
  run_command
  shell_quote
  slurp
  write_file
);

my $REPOSITORY_ROOT = repo_root();

my @INTERNAL_PATHS = (
    'README.md',                 'CODE_OF_CONDUCT.md',
    'CODEOFCONDUCT.md',          'CONTRIBUTING.md',
    'AGENTS.md',                 'CLAUDE.md',
    'GEMINI.md',                 'copilot-instructions.md',
    '.git/config',               '.github/workflows/archive.yml',
    '.agents/skills/example.md', '.claude/settings.json',
    '.codex/settings.json',      '.gitignore',
    '.gitattributes',            '.gitmodules',
    '.editorconfig',             '.htmltest.yml',
    '.perlcriticrc',             '.stylelintrc.json',
    'dprint.json',               'docs/ARCHITECTURE.md',
    't/check.t',                 'tests/check.pl',
    'tmp/cache-entry',           'tmp_archive/old.tar',
    '.cache/cache-entry',        'nested/AGENTS.md',
    'scripts/openbsd-tools.txt', 'scripts/validate-agent-knowledge.pl',
    'editor.swp',                'backup~',
);

my @PUBLIC_PATHS = (
    'index.html',             'styles.css',
    'CNAME',                  'robots.txt',
    'sitemap.xml',            '.well-known/security.txt',
    'articles/readme.md',     'data/articles.json',
    'feeds/site.xml',         'images/logo.svg',
    'scripts/linked-tool.pl', 'templates/reference.html',
    'files/download.img',
);

my @SYNC_IMPLEMENTATIONS = (
    [ 'debian/sync-website.bash', 'bash' ],
    [ 'openbsd/sync-website.ksh', 'ksh' ],
);

sub common_functions {
    my ($text) = @_;
    return join "\n\n", map { extract_function( $text, $_ ) } qw(
      filter_site_tree
      has_repo_content
      reject_source_symlinks
      copy_from_source
      stage_from_source
    );
}

sub stage_fixture {
    my ( $shell, $functions, $transfer_mode, $destination_state ) = @_;
    my $root        = new_tempdir('website-sync-test-');
    my $source      = "$root/source";
    my $destination = "$root/public";
    make_path( $source, $destination );
    my $external_target = "$root/external-target";
    write_file( $external_target, 'must not be followed' );

    for my $relative_path ( @INTERNAL_PATHS, @PUBLIC_PATHS ) {
        write_file( "$source/$relative_path", 'fixture' );
    }
    my $nested_repository_link = "$source/nested/.git";
    make_path("$source/nested");
    symlink( $external_target, $nested_repository_link )
      or die "cannot create $nested_repository_link: $!";

    if ( $destination_state eq 'update' ) {
        for my $relative_path (
            'README.md',                '.git/config',
            '.github/old-workflow.yml', '.agents/old-instructions.md',
            'docs/old-guide.md',        'stale-page.html',
          )
        {
            write_file( "$destination/$relative_path", 'stale' );
        }
        my $old_repository_link = "$destination/nested/.git";
        make_path("$destination/nested");
        symlink( $external_target, $old_repository_link )
          or die "cannot create $old_repository_link: $!";
    }

    my $lock = "$destination/.sync.lock";
    make_path($lock);
    write_file( "$lock/pid", 'active' );

    my $command = join "\n",
      'SRC=' . shell_quote($source),
      'WWW_DIR=' . shell_quote($destination),
      'warn() { :; }',
      $functions,
      'stage_from_source "$SRC"',
      '';

    my $environment;
    if ( $transfer_mode eq 'copy' ) {
        my $isolated_path = "$root/path";
        make_path($isolated_path);
        for my $utility (qw(find rm cp)) {
            my $target = find_command($utility);
            die "$utility is required" unless defined $target;
            symlink( $target, "$isolated_path/$utility" )
              or die "cannot link $utility: $!";
        }
        $environment = env_with( PATH => $isolated_path );
    }
    else {
        $environment = env_with();
    }

    my $result = run_command(
        cmd     => [ $shell, '-c', $command ],
        env     => $environment,
        timeout => 20,
    );
    is( $result->{returncode}, 0, "$transfer_mode/$destination_state stages" )
      or diag $result->{stderr};

    my @published = list_tree($destination);
    my %published = map { $_ => 1 } @published;
    my @leaked    = grep {
        my $path = $_;
        grep { $path eq $_ || index( $path, "$_/" ) == 0 } @INTERNAL_PATHS
    } @published;
    my @missing = grep { !$published{$_} } @PUBLIC_PATHS;

    is_deeply( \@leaked, [],
        "$transfer_mode/$destination_state hides internals" );
    is_deeply( \@missing, [],
        "$transfer_mode/$destination_state keeps public files" );
    ok( $published{'.sync.lock/pid'}, 'active lock survives staging' );
    if ( $destination_state eq 'update' ) {
        ok( !$published{'stale-page.html'}, 'stale page is removed on update' );
    }
    ok( -e $external_target, 'external symlink target is untouched' );
    return;
}

sub exercise_implementation {
    my ( $relative_script, $shell_name ) = @_;
    my $shell = find_command($shell_name);
    ok( defined $shell, "$shell_name is available" )
      or return;
    my $source_text = slurp("$REPOSITORY_ROOT/$relative_script");
    my $functions   = common_functions($source_text);

    for my $transfer_mode (qw(rsync copy)) {
        next if $transfer_mode eq 'rsync' && !defined find_command('rsync');
        for my $destination_state (qw(initial update)) {
            subtest "$relative_script $transfer_mode $destination_state" =>
              sub {
                stage_fixture( $shell, $functions, $transfer_mode,
                    $destination_state );
              };
        }
    }
    return;
}

subtest 'debian filter and staging paths' => sub {
    plan skip_all => 'Debian sync script is exercised on Linux'
      if $^O eq 'openbsd';
    exercise_implementation( @{ $SYNC_IMPLEMENTATIONS[0] } );
};

subtest 'openbsd filter and staging paths' => sub {
    my ( $relative_script, $shell_name ) = @{ $SYNC_IMPLEMENTATIONS[1] };
    plan skip_all => "$shell_name is not installed"
      unless defined find_command($shell_name);
    exercise_implementation( $relative_script, $shell_name );
};

subtest 'public symlink is rejected' => sub {
    for my $implementation (@SYNC_IMPLEMENTATIONS) {
        my ( $relative_script, $shell_name ) = @$implementation;
        next if $^O eq 'openbsd' && $relative_script =~ m{^debian/};
        my $shell = find_command($shell_name);
        next unless defined $shell;

        my $root        = new_tempdir('website-link-test-');
        my $source      = "$root/source";
        my $destination = "$root/public";
        make_path( $source, $destination );
        write_file( "$source/index.html", 'ok' );
        my $external = "$root/external";
        write_file( $external, 'secret' );
        symlink( $external, "$source/public-link" )
          or die "cannot create symlink: $!";

        my $source_text = slurp("$REPOSITORY_ROOT/$relative_script");
        my $command     = join "\n",
          'SRC=' . shell_quote($source),
          'WWW_DIR=' . shell_quote($destination),
          'warn() { :; }',
          'error() { printf \'%s\\n\' "$*" >&2; }',
          common_functions($source_text),
          'stage_from_source "$SRC"',
          '';
        my $result = run_command(
            cmd     => [ $shell, '-c', $command ],
            timeout => 20,
        );
        isnt( $result->{returncode}, 0,
            "$relative_script rejects a public symlink" )
          or diag $result->{stderr};
    }
};

done_testing();
