#!/usr/bin/env perl

# Interactive SSH launcher using entries from ~/.ssh/known_hosts:
#  - Exports SSH_ASKPASS/SSH_ASKPASS_REQUIRE for ksshaskpass GUI prompts
#  - Parses known_hosts and de-duplicates hosts (including custom ports)
#  - Presents a numbered menu to choose a server
#  - Prompts for the SSH username (default from SSH_MENU_USER or $USER)
#  - Persists usage frequencies to sort frequently used hosts to the top
#  - Supports custom aliases via a separate alias file
#  - Supports known_hosts entry deletion and alias management via menus
#  - Executes ssh to the selected host (with -p when a custom port exists)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;
use File::Path qw(make_path);

my $no_color  = 0;
my $is_tty    = ( -t STDOUT )             ? 1 : 0;
my $use_color = ( !$no_color && $is_tty ) ? 1 : 0;

my ( $GREEN, $YELLOW, $RED, $CYAN, $BOLD, $RESET ) = ( "", "", "", "", "", "" );
if ($use_color) {
    $GREEN  = "\e[32m";
    $YELLOW = "\e[33m";
    $RED    = "\e[31m";
    $CYAN   = "\e[36m";
    $BOLD   = "\e[1m";
    $RESET  = "\e[0m";
}

sub logi { print "${GREEN}✅ [INFO]${RESET} $_[0]\n"; }
sub logw { print STDERR "${YELLOW}⚠️ [WARN]${RESET} $_[0]\n"; }
sub loge { print STDERR "${RED}❌ [ERROR]${RESET} $_[0]\n"; }

sub die_tool {
    my ($msg) = @_;
    loge($msg);
    exit 1;
}

my $known_hosts = $ENV{SSH_MENU_KNOWN_HOSTS} // "$ENV{HOME}/.ssh/known_hosts";
my $freq_file   = $ENV{SSH_MENU_FREQ_FILE}
  // "$ENV{HOME}/.cache/ssh-menu/frequencies";
my $alias_file = $ENV{SSH_MENU_ALIAS_FILE}
  // "$ENV{HOME}/.cache/ssh-menu/aliases";

my @entries;
my %seen;
my $hashed_count;
my %freq;
my $freq_file_exists;
my %alias;
my $alias_file_exists;

########################
# 0. Small helper bits #
########################

sub parent_dir {
    my ($path) = @_;
    return unless defined $path && length $path;
    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    return $dir;
}

sub entry_key {
    my ( $host, $port ) = @_;
    return join ':', $host, ( $port || 'default' );
}

# Small PATH search for ksshaskpass (no extra modules needed)
sub find_in_path {
    my ($prog) = @_;
    for my $dir ( split /:/, $ENV{PATH} || '' ) {
        next unless length $dir;
        my $full = "$dir/$prog";
        return $full if -x $full;
    }
    return;
}

##########################
# 1. Setup and validation #
##########################

sub ensure_known_hosts_exists {
    if ( !-f $known_hosts ) {
        die_tool("$known_hosts not found.");
    }
}

sub setup_ssh_askpass {
    my $ksshaskpass = find_in_path('ksshaskpass');

    if ($ksshaskpass) {
        $ENV{SSH_ASKPASS}         = $ksshaskpass;
        $ENV{SSH_ASKPASS_REQUIRE} = 'prefer';
    }
    else {
        logw('ksshaskpass not found in PATH; continuing without SSH_ASKPASS');
    }
}

sub setup_openbsd_sandbox {
    return unless $^O eq 'openbsd';

    # Unveil PATH for exec, and state/cache dirs for read/write.
    my @path_dirs = grep { defined $_ && length $_ }
      split /:/, ( $ENV{PATH} || '' );
    my @rw_dirs;
    my $known_hosts_dir = parent_dir($known_hosts);
    my $freq_dir        = parent_dir($freq_file);
    my $alias_dir       = parent_dir($alias_file);

    push @rw_dirs, $known_hosts_dir if defined $known_hosts_dir;
    push @rw_dirs, $freq_dir        if defined $freq_dir;
    push @rw_dirs, $alias_dir       if defined $alias_dir;

    my %uniq;
    @rw_dirs = grep { defined $_ && length $_ && !$uniq{$_}++ } @rw_dirs;

    eval {
        require OpenBSD::Pledge;
        require OpenBSD::Unveil;

        for my $dir (@path_dirs) {
            OpenBSD::Unveil::unveil( $dir, 'rx' );
        }
        for my $dir (@rw_dirs) {
            OpenBSD::Unveil::unveil( $dir, 'rwc' );
        }

        OpenBSD::Unveil::unveil();
        OpenBSD::Pledge::pledge(
            'stdio rpath wpath cpath fattr exec proc inet dns unix')
          or die "pledge failed";
        1;
    } or do {
        logw("OpenBSD pledge/unveil setup failed: $@");
    };
}

########################
# 2. State persistence #
########################

sub write_alias_file {
    my ($aliases_ref) = @_;
    my ($dir)         = $alias_file =~ m{^(.*)/[^/]+$};
    make_path($dir) if defined $dir && length $dir;
    if ( open my $afh, '>', $alias_file ) {
        for my $k ( sort keys %{$aliases_ref} ) {
            printf $afh "%s %s\n", $k, $aliases_ref->{$k};
        }
        close $afh;
    }
    else {
        logw("Could not write alias file $alias_file: $!");
    }
}

sub write_freq_file {
    my ($freq_ref) = @_;
    my ($dir)      = $freq_file =~ m{^(.*)/[^/]+$};
    make_path($dir) if defined $dir && length $dir;
    if ( open my $ffh, '>', $freq_file ) {
        for my $k ( sort keys %{$freq_ref} ) {
            printf $ffh "%s %d\n", $k, $freq_ref->{$k};
        }
        close $ffh;
    }
    else {
        logw("Could not write frequency file $freq_file: $!");
    }
}

sub reset_state {
    @entries           = ();
    %seen              = ();
    $hashed_count      = 0;
    %freq              = ();
    %alias             = ();
    $freq_file_exists  = -f $freq_file  ? 1 : 0;
    $alias_file_exists = -f $alias_file ? 1 : 0;
}

sub load_freq_file {
    return unless $freq_file_exists;

    if ( open my $ffh, '<', $freq_file ) {
        while ( my $line = <$ffh> ) {
            chomp $line;
            next if $line =~ /^\s*$/;
            my ( $k, $v ) = split /\s+/, $line, 2;
            next unless defined $k && defined $v;
            next unless $v =~ /^\d+$/;
            $freq{$k} = $v;
        }
        close $ffh;
    }
    else {
        logw("Could not read frequency file $freq_file: $!");
    }
}

sub load_alias_file {
    return unless $alias_file_exists;

    if ( open my $afh, '<', $alias_file ) {
        while ( my $line = <$afh> ) {
            chomp $line;
            next if $line =~ /^\s*$/;
            my ( $k, $v ) = split /\s+/, $line, 2;
            next unless defined $k && defined $v;
            $alias{$k} = $v;
        }
        close $afh;
    }
    else {
        logw("Could not read alias file $alias_file: $!");
    }
}

sub load_state_from_disk {
    reset_state();
    load_freq_file();
    load_alias_file();
}

###########################
# 3. known_hosts handling #
###########################

sub build_display {
    my ( $host, $port, $parts_ref, $alias_name ) = @_;

    my $display;
    if ( @{$parts_ref} > 1 ) {
        my @aliases   = @{$parts_ref}[ 1 .. $#{$parts_ref} ];
        my $alias_str = join ', ', @aliases;
        if ($port) {
            $display = "$host (port $port; aliases: $alias_str)";
        }
        else {
            $display = "$host (aliases: $alias_str)";
        }
    }
    else {
        if ($port) {
            $display = "$host (port $port)";
        }
        else {
            $display = $host;
        }
    }

    if ( defined $alias_name && length $alias_name ) {
        $display = "$alias_name -> $display";
    }

    return $display;
}

sub parse_known_hosts {
    open my $fh, '<', $known_hosts
      or die_tool("cannot open $known_hosts: $!");

    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;

        if ( $line =~ /^\s*\|/ ) {

            # Hashed known_hosts entries cannot be decoded.
            $hashed_count++;
            next;
        }

        my ($field) = split /\s+/, $line, 2;
        next unless defined $field && length $field;

        my @parts =
          grep { defined $_ && length $_ && $_ !~ /^\s*#/ && $_ !~ /^\s*\|/ }
          split /,/, $field;

        next unless @parts;

        my $primary = $parts[0];
        my $host    = $primary;
        my $port    = '';

        if ( $host =~ /^\[(.+)\]:(\d+)$/ ) {
            $host = $1;
            $port = $2;
        }

        my $key = entry_key( $host, $port );
        next if $seen{$key}++;

        my $display = build_display( $host, $port, \@parts, $alias{$key} );

        push @entries,
          {
            host    => $host,
            port    => $port,
            display => $display,
            freq    => $freq{$key} // 0,
          };
    }
    close $fh;
}

sub prune_stale_data {

    # Keep frequency and alias data consistent with the current host list.
    my %valid_keys =
      map { entry_key( $_->{host}, $_->{port} ) => 1 } @entries;

    my $pruned_freq = 0;
    for my $k ( keys %freq ) {
        if ( !$valid_keys{$k} ) {
            delete $freq{$k};
            $pruned_freq = 1;
        }
    }

    my $pruned_alias = 0;
    for my $k ( keys %alias ) {
        if ( !$valid_keys{$k} ) {
            delete $alias{$k};
            $pruned_alias = 1;
        }
    }

    write_freq_file( \%freq )   if $pruned_freq;
    write_alias_file( \%alias ) if $pruned_alias;
}

sub ensure_entries_present {
    if ( !@entries ) {
        if ( $hashed_count > 0 ) {
            die_tool( "No valid plain hosts found in $known_hosts.\n"
                  . "It looks like your known_hosts file contains only hashed entries.\n"
                  . "This script cannot recover hostnames from hashed lines.\n"
                  . "Consider keeping a separate non-hashed file (e.g. ~/.ssh/known_hosts.menu)\n"
                  . "for use with this menu script." );
        }
        else {
            die_tool("No valid hosts found in $known_hosts.");
        }
    }
}

sub sort_entries {
    if ($freq_file_exists) {
        @entries = sort {
                 ( $b->{freq} <=> $a->{freq} )
              || ( lc $a->{display} cmp lc $b->{display} )
        } @entries;
    }
    else {
        @entries = sort { lc $a->{display} cmp lc $b->{display} } @entries;
    }
}

###################
# 4. Menu actions #
###################

sub add_alias_menu {
    if ( !@entries ) {
        logw('No entries available to alias.');
        return;
    }

    logi('Add custom name (alias) for a host');
    for my $i ( 0 .. $#entries ) {
        printf "  ${CYAN}%2d)${RESET} ${BOLD}%s${RESET}\n", $i + 1,
          $entries[$i]{display};
    }
    printf "  ${CYAN}%2d)${RESET} ${BOLD}Cancel${RESET}\n\n",
      scalar(@entries) + 1;

    while (1) {
        print "Alias which entry [1-", scalar(@entries) + 1,
          "] (q to cancel): ";
        my $input = <STDIN>;
        defined $input or die_tool('Input closed.');
        chomp $input;

        return if $input =~ /^[qQ]$/;
        next   if $input !~ /^\d+$/;
        my $num = int($input);
        if ( $num == scalar(@entries) + 1 ) {
            return;
        }
        next if $num < 1 || $num > scalar(@entries);

        my $idx  = $num - 1;
        my $host = $entries[$idx]{host};
        my $port = $entries[$idx]{port};
        my $key  = join ':', $host, ( $port || 'default' );

        print "Enter custom name (alias) for $host"
          . ( $port ? " (port $port)" : '' )
          . " [blank to cancel]: ";
        my $alias_val = <STDIN> // '';
        chomp $alias_val;
        return if $alias_val !~ /\S/;

        $alias{$key} = $alias_val;
        write_alias_file( \%alias );
        logi('Alias saved. Please re-run ssh-menu to refresh the list.');
        return;
    }
}

sub select_entry_menu {

    # Returns the selected entry index after handling menu actions.
    logi("Select a server to connect to:");
    print "\n";
    for my $i ( 0 .. $#entries ) {
        printf "  ${CYAN}%2d)${RESET} ${BOLD}%s${RESET}\n", $i + 1,
          $entries[$i]{display};
    }
    printf "  ${CYAN}%2d)${RESET} ${BOLD}Manage known_hosts (delete)${RESET}\n",
      scalar(@entries) + 1;
    printf "  ${CYAN}%2d)${RESET} ${BOLD}Add custom name (alias)${RESET}\n",
      scalar(@entries) + 2;
    printf "  ${CYAN}%2d)${RESET} ${BOLD}Quit${RESET}\n\n",
      scalar(@entries) + 3;

    my $selected_idx;
    while (1) {
        print "Choice [1-", scalar(@entries) + 3, "]: ";
        my $input = <STDIN>;
        defined $input or die_tool("Input closed.");
        chomp $input;
        if ( $input =~ /^[qQ]$/ ) {
            logi("Exiting.");
            exit 0;
        }

        next if $input !~ /^\d+$/;

        my $num = int($input);

        if ( $num == scalar(@entries) + 3 ) {
            logi("Exiting.");
            exit 0;
        }

        if ( $num == scalar(@entries) + 1 ) {
            manage_known_hosts_menu();
            next;
        }

        if ( $num == scalar(@entries) + 2 ) {
            add_alias_menu();
            next;
        }

        if ( $num >= 1 && $num <= scalar(@entries) ) {
            $selected_idx = $num - 1;
            last;
        }

        logw("Invalid option. Please try again.");
    }

    return $selected_idx;
}

#####################
# 5. SSH connection #
#####################

sub prompt_ssh_user {
    my $default_user = $ENV{SSH_MENU_USER} // $ENV{USER} // '';

    print "${BOLD}SSH user${RESET}"
      . ( length $default_user ? " [${CYAN}$default_user${RESET}]" : '' )
      . ": ";
    my $ssh_user = <STDIN>;
    defined $ssh_user or die_tool("Input closed.");
    chomp $ssh_user;

    if ( !length $ssh_user ) {
        if ( length $default_user ) {
            $ssh_user = $default_user;
        }
        else {
            die_tool("Empty user. Aborting.");
        }
    }

    if ( $ssh_user =~ /^\s+$/ ) {
        die_tool("Empty user. Aborting.");
    }

    return $ssh_user;
}

sub build_ssh_command {
    my ( $ssh_user, $selected_host, $selected_port ) = @_;
    my @cmd;

    if ($selected_port) {
        logi(
            "Connecting to $ssh_user\@$selected_host (port $selected_port)...");
        @cmd = ( 'ssh', '-p', $selected_port, "$ssh_user\@$selected_host" );
    }
    else {
        logi("Connecting to $ssh_user\@$selected_host ...");
        @cmd = ( 'ssh', "$ssh_user\@$selected_host" );
    }

    return @cmd;
}

sub update_frequency {
    my ($selected_key) = @_;
    $freq{$selected_key} = ( $freq{$selected_key} // 0 ) + 1;
    eval { write_freq_file( \%freq ); };
    if ($@) { logw("Could not persist frequency file: $@"); }
}

sub main {

    ensure_known_hosts_exists();
    setup_ssh_askpass();
    setup_openbsd_sandbox();

    load_state_from_disk();
    parse_known_hosts();
    prune_stale_data();
    ensure_entries_present();
    sort_entries();

    logw("Skipped $hashed_count hashed known_hosts entries.")
      if $hashed_count > 0;

    my $selected_idx     = select_entry_menu();
    my $selected_host    = $entries[$selected_idx]{host};
    my $selected_port    = $entries[$selected_idx]{port};
    my $selected_display = $entries[$selected_idx]{display};
    my $selected_key     = entry_key( $selected_host, $selected_port );

    logi("Selected server: $selected_display");

    my $ssh_user = prompt_ssh_user();
    my @cmd = build_ssh_command( $ssh_user, $selected_host, $selected_port );

    update_frequency($selected_key);
    exec @cmd or die_tool("Failed to exec ssh: $!");
}

main();
