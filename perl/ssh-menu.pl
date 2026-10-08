#!/usr/bin/env perl

# Interactive SSH launcher using entries from ~/.ssh/known_hosts:
#  - Exports SSH_ASKPASS/SSH_ASKPASS_REQUIRE for ksshaskpass GUI
#  - Parses known_hosts and de-duplicates hosts (including custom ports)
#  - Presents a numbered menu to choose a server
#  - questions for SSH username (default SSH_MENU_USER or $USER)
#  - Remembers the last SSH username used and reuses it as default
#  - Persists usage frequencies to sort frequently used hosts to top
#  - Supports custom aliases via a separate alias file
#  - Supports known_hosts entry deletion and alias management via menus
#  - Executes ssh to the selected host (with -p for custom port)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);

sub is_windows { return $^O eq 'MSWin32'; }
sub is_openbsd { return $^O eq 'openbsd'; }

sub logi { print "[INFO] $_[0]\n"; }
sub logw { print STDERR "[WARN] $_[0]\n"; }
sub loge { print STDERR "[ERROR] $_[0]\n"; }

sub die_tool {
    my ($msg) = @_;
    loge($msg);
    exit 1;
}

sub require_cmd {
    my ($cmd) = @_;
    return if defined $cmd && length $cmd && find_in_path($cmd);
    die_tool("Required command '$cmd' not found in PATH.");
}

sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME};
    return $ENV{USERPROFILE}
      if defined $ENV{USERPROFILE} && length $ENV{USERPROFILE};
    die_tool(
        "Cannot determine home: " . "neither HOME nor USERPROFILE is set." );
}

my $home        = home_dir();
my $known_hosts = $ENV{SSH_MENU_KNOWN_HOSTS} // "$home/.ssh/known_hosts";
my $freq_file = $ENV{SSH_MENU_FREQ_FILE} // "$home/.cache/ssh-menu/frequencies";
my $alias_file = $ENV{SSH_MENU_ALIAS_FILE} // "$home/.cache/ssh-menu/aliases";
my $last_user_file = $ENV{SSH_MENU_LAST_USER_FILE}
  // "$home/.cache/ssh-menu/last-user";

my @entries;
my %seen;
my $hashed_count;
my %freq;
my $freq_file_exists;
my %alias;
my $alias_file_exists;
my %last_user;

########################
# 0. Small helper bits #
########################

sub parent_dir {
    my ($path) = @_;
    return unless defined $path && length $path;
    my ( $vol, $dirs, $file ) = File::Spec->splitpath($path);
    return unless length $file;
    $dirs =~ s{[\\/]\z}{} if length $dirs;
    return File::Spec->catpath( $vol, $dirs );
}

sub entry_key {
    my ( $host, $port ) = @_;
    return join ':', $host, ( $port || 'default' );
}

# Small PATH search for ksshaskpass (no extra modules needed)
sub find_in_path {
    my ($prog) = @_;
    my $sep = is_windows() ? ';' : ':';
    for my $dir ( split /\Q$sep\E/, $ENV{PATH} || '' ) {
        next unless length $dir;
        my $full = File::Spec->catfile( $dir, $prog );
        return $full if -x $full;
        if ( is_windows() ) {
            my $full_exe = "$full.exe";
            return $full_exe if -x $full_exe;
        }
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
        logw('ksshaskpass not found in PATH; no SSH_ASKPASS');
    }
}

sub setup_openbsd_sandbox {
    return unless is_openbsd();

    # Unveil PATH for exec, and state/cache dirs for read/write.
    my @path_dirs = grep { defined $_ && length $_ }
      split /:/, ( $ENV{PATH} || '' );
    my @rw_dirs;
    my $known_hosts_dir = parent_dir($known_hosts);
    my $freq_dir        = parent_dir($freq_file);
    my $alias_dir       = parent_dir($alias_file);
    my $last_user_dir   = parent_dir($last_user_file);

    push @rw_dirs, $known_hosts_dir if defined $known_hosts_dir;
    push @rw_dirs, $freq_dir        if defined $freq_dir;
    push @rw_dirs, $alias_dir       if defined $alias_dir;
    push @rw_dirs, $last_user_dir   if defined $last_user_dir;

    my %uniq;
    @rw_dirs =
      grep { defined $_ && length $_ && !$uniq{$_}++ } @rw_dirs;

    eval {
        require OpenBSD::Pledge;
        require OpenBSD::Unveil;

        # The binding returns false and sets $! on failure; collect failures
        # instead of silently running with an incomplete veil.
        # See OpenBSD::Unveil(3p).
        my @uv_failed;
        for my $dir (@path_dirs) {
            next unless -d $dir;
            next if OpenBSD::Unveil::unveil( $dir, 'rx' );
            push @uv_failed, "$dir (rx)";
        }

        # unveil(2) requires every directory in the path to exist. For a state
        # directory that has not been created yet, unveil the nearest existing
        # ancestor so the program can still create it.
        for my $dir (@rw_dirs) {
            my $target = $dir;
            my $ok     = 0;
            while (1) {
                if ( OpenBSD::Unveil::unveil( $target, 'rwc' ) ) {
                    $ok = 1;
                    last;
                }
                my $parent = parent_dir($target);
                last
                  unless defined $parent
                  && length $parent
                  && $parent ne $target;
                $target = $parent;
            }
            push @uv_failed, "$dir (rwc)" unless $ok;
        }

        OpenBSD::Unveil::unveil()
          or die "unveil lock failed: $!";

        # The binding takes a list of promises and always adds 'stdio';
        # see OpenBSD::Pledge(3p).
        OpenBSD::Pledge::pledge(
            qw(stdio rpath wpath cpath fattr exec proc inet dns unix))
          or die "pledge failed: $!";

        die 'unveil failed for: ' . join( ', ', @uv_failed ) . "\n"
          if @uv_failed;
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
    my $dir = parent_dir($alias_file);
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
    my $dir = parent_dir($freq_file);
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

sub write_last_user_file {
    my ($last_ref) = @_;
    return unless defined $last_ref;

    my $dir = parent_dir($last_user_file);
    make_path($dir) if defined $dir && length $dir;

    if ( open my $ufh, '>', $last_user_file ) {
        for my $k ( sort keys %{$last_ref} ) {
            printf $ufh "%s %s\n", $k, $last_ref->{$k};
        }
        close $ufh;
    }
    else {
        logw("Could not write last user file $last_user_file: $!");
    }
}

sub reset_state {
    @entries           = ();
    %seen              = ();
    $hashed_count      = 0;
    %freq              = ();
    %alias             = ();
    %last_user         = ();
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

sub load_last_user_file {
    return unless -f $last_user_file;

    if ( open my $ufh, '<', $last_user_file ) {
        while ( my $line = <$ufh> ) {
            chomp $line;
            next if $line =~ /^\s*$/;
            my ( $k, $v ) = split /\s+/, $line, 2;
            next unless defined $k && defined $v;
            $last_user{$k} = $v;
        }
        close $ufh;
    }
    else {
        logw("Could not read last user file $last_user_file: $!");
    }
}

sub load_state_from_disk {
    reset_state();
    load_freq_file();
    load_alias_file();
    load_last_user_file();
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

        # Marker lines (@cert-authority ..., @revoked ...) define
        # trust/revocations, not connectable hosts; skip them.
        next if $line =~ /^\s*@/;

        my ( $field, $rest ) = split ' ', $line, 2;
        next unless defined $field && length $field;

        # Require a key type (a bare host token is not a valid entry).
        next unless defined $rest && $rest =~ /\S/;

        my @parts =
          grep { defined $_ && length $_ && $_ !~ /^\s*#/ && $_ !~ /^\s*\|/ }
          split /,/, $field;

        next unless @parts;

        my $primary = $parts[0];

        # Host patterns (wildcards) and negations are not connectable hosts.
        next if $primary =~ /^!/ || $primary =~ /[*?]/;

        my $host = $primary;
        my $port = '';

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

    # Keep freq/alias data consistent with current host list.
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

    my $pruned_last_user = 0;
    for my $k ( keys %last_user ) {
        if ( !$valid_keys{$k} ) {
            delete $last_user{$k};
            $pruned_last_user = 1;
        }
    }

    write_freq_file( \%freq )           if $pruned_freq;
    write_alias_file( \%alias )         if $pruned_alias;
    write_last_user_file( \%last_user ) if $pruned_last_user;
}

sub ensure_entries_present {
    if ( !@entries ) {
        if ( $hashed_count > 0 ) {
            die_tool( "No valid plain hosts in $known_hosts.\n"
                  . "Your known_hosts contains only hashed entries.\n"
                  . "Cannot recover hostnames from hashed lines.\n"
                  . "Keep a non-hashed file (~/.ssh/known_hosts.menu)\n"
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
        @entries =
          sort { lc $a->{display} cmp lc $b->{display} } @entries;
    }
}

# Reload state and re-read known_hosts. Used at startup and after a mutating
# menu action so the menu never offers stale/removed hosts.
sub refresh_entries {
    load_state_from_disk();
    parse_known_hosts();
    ensure_entries_present();
    prune_stale_data();
    sort_entries();
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
        printf "  %2d) %s\n", $i + 1, $entries[$i]{display};
    }
    printf "  %2d) Cancel\n\n", scalar(@entries) + 1;

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
        logi('Alias saved. List refreshed.');
        return;
    }
}

sub remove_known_host_entry {
    my ( $host, $port ) = @_;
    return 0   unless defined $host && length $host;
    $port = '' unless defined $port;

    # Keep every line that is not the requested plain host entry. Comments,
    # marker lines (@cert-authority, @revoked) and hashed entries are left
    # untouched.
    my @kept;
    my $removed = 0;
    my $fh;
    if ( !open $fh, '<', $known_hosts ) {
        logw("Could not read $known_hosts: $!");
        return 0;
    }
    while ( my $line = <$fh> ) {
        my $probe = $line;
        my ($eol) = $probe =~ /(\r?\n)\z/;
        $probe =~ s/\r?\n\z//;
        my $matches = 0;
        my $rewrite;
        if ( $probe !~ /^\s*(?:#|\||@)/ && $probe =~ /\S/ ) {
            my ( $field, $rest ) = split ' ', $probe, 2;
            if ( defined $field && length $field && defined $rest ) {
                my @remain;
                for my $cand ( split /,/, $field, -1 ) {
                    my ( $h, $p ) = ( $cand, '' );
                    if ( $h =~ /^\[(.+)\]:(\d+)$/ ) { $h = $1; $p = $2; }
                    if ( $h eq $host && $p eq $port ) {
                        $matches = 1;
                        next;
                    }
                    push @remain, $cand;
                }

                # Keep the line (and its key) when other names remain.
                if ( $matches && @remain ) {
                    $rewrite = join( ',', @remain ) . ' ' . $rest;
                    $rewrite .= $eol if defined $eol;
                }
            }
        }
        if ($matches) { $removed++; next unless defined $rewrite; }
        push @kept, defined $rewrite ? $rewrite : $line;
    }
    close $fh;

    return 0 unless $removed;

    # Replace the file atomically, preserving its permission bits.
    my $dir = parent_dir($known_hosts);
    $dir = '.' unless defined $dir && length $dir;

    my ( $tfh, $tmp ) =
      tempfile( 'known_hosts.XXXXXX', DIR => $dir, UNLINK => 0 );
    if ( !$tfh ) {
        logw("Could not create a temporary file in $dir: $!");
        return 0;
    }
    print {$tfh} @kept;
    close $tfh;

    if ( my @st = stat($known_hosts) ) {
        chmod( $st[2] & 07777, $tmp );
    }
    if ( !rename $tmp, $known_hosts ) {
        logw("Could not replace $known_hosts: $!");
        unlink $tmp;
        return 0;
    }
    return $removed;
}

sub manage_known_hosts_menu {
    if ( !@entries ) {
        logw('No entries available to delete.');
        return;
    }

    logi('Delete a host from known_hosts');
    for my $i ( 0 .. $#entries ) {
        printf "  %2d) %s\n", $i + 1, $entries[$i]{display};
    }
    printf "  %2d) Cancel\n\n", scalar(@entries) + 1;

    while (1) {
        print "Delete which entry [1-",
          scalar(@entries) + 1, "] (q to cancel): ";
        my $input = <STDIN>;
        defined $input or die_tool('Input closed.');
        chomp $input;

        return if $input =~ /^[qQ]$/;
        next   if $input !~ /^\d+$/;
        my $num = int($input);
        return if $num == scalar(@entries) + 1;
        next   if $num < 1 || $num > scalar(@entries);

        my $idx  = $num - 1;
        my $host = $entries[$idx]{host};
        my $port = $entries[$idx]{port};

        print "Delete $host"
          . ( $port ? " (port $port)" : '' )
          . " from $known_hosts? [y/N]: ";
        my $confirm = <STDIN>;
        defined $confirm or die_tool('Input closed.');
        chomp $confirm;
        return if $confirm !~ /^[yY]/;

        my $removed = remove_known_host_entry( $host, $port );
        if ($removed) {
            logi("Removed $removed line(s) for $host from $known_hosts.");
        }
        else {
            logw("No matching line found for $host in $known_hosts.");
        }
        logi('List refreshed.');
        return;
    }
}

sub print_entry_menu {
    logi("Select a server to connect to:");
    print "\n";
    for my $i ( 0 .. $#entries ) {
        printf "  %2d) %s\n", $i + 1, $entries[$i]{display};
    }
    printf "  %2d) Manage known_hosts (delete)\n", scalar(@entries) + 1;
    printf "  %2d) Add custom name (alias)\n",     scalar(@entries) + 2;
    printf "  %2d) Quit\n\n",                      scalar(@entries) + 3;
}

sub select_entry_menu {

    # Returns the selected entry index after handling menu actions.
    print_entry_menu();

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
            refresh_entries();
            print_entry_menu();
            next;
        }

        if ( $num == scalar(@entries) + 2 ) {
            add_alias_menu();
            refresh_entries();
            print_entry_menu();
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

sub question_ssh_user {
    my ($selected_key) = @_;
    my $per_host_user = $last_user{$selected_key} if defined $selected_key;
    my $default_user =
         $per_host_user
      || $ENV{SSH_MENU_USER}
      || $ENV{USER}
      || $ENV{USERNAME}
      || '';

    print "SSH user"
      . (
        length $default_user
        ? " [$default_user]"
        : ''
      ) . ": ";
    my $ssh_user = <STDIN>;
    defined $ssh_user or die_tool("Input closed.");
    chomp $ssh_user;
    $ssh_user =~ s/^\s+|\s+$//g;

    if ( !length $ssh_user ) {
        if ( length $default_user ) {
            $ssh_user = $default_user;
        }
        else {
            die_tool("Empty user. Aborting.");
        }
    }

    $last_user{$selected_key} = $ssh_user;
    write_last_user_file( \%last_user );

    return $ssh_user;
}

sub build_ssh_command {
    my ( $ssh_path, $ssh_user, $selected_host, $selected_port ) = @_;
    my @cmd;

    # The user name is inserted into the ssh destination; reject anything
    # that could be parsed as an ssh option (for example "-oProxyCommand=...").
    if ( !defined $ssh_user || $ssh_user !~ /\A[A-Za-z0-9._-]+\z/ ) {
        die_tool("Invalid SSH user name: '$ssh_user'.");
    }

    if ($selected_port) {
        logi(   "Connecting to $ssh_user\@$selected_host"
              . " (port $selected_port)..." );
        @cmd = ( $ssh_path, '-p', $selected_port, "$ssh_user\@$selected_host" );
    }
    else {
        logi("Connecting to $ssh_user\@$selected_host ...");
        @cmd = ( $ssh_path, "$ssh_user\@$selected_host" );
    }

    return @cmd;
}

sub update_frequency {
    my ($selected_key) = @_;
    $freq{$selected_key} = ( $freq{$selected_key} // 0 ) + 1;
    eval { write_freq_file( \%freq ); };
    if ($@) { logw("Could not persist frequency file: $@"); }
}

sub exec_ssh_command {
    my @cmd     = @_;
    my $program = $cmd[0];

    # Win32 Perl serializes argv into a command line without quoting argv[0].
    # An SSH path under Program Files would otherwise become extra arguments.
    # Keep the executable path separate from its Windows-only quoted argv[0].
    if ( is_windows() ) {
        $cmd[0] = qq{"$program"};

        # Win32 exec does not wait for the child; keep the terminal attached
        # and propagate SSH's exit status instead of returning immediately.
        my $status = system {$program} @cmd;
        die_tool("Failed to launch ssh: $!") if $status == -1;
        exit( $status >> 8 );
    }
    exec {$program} @cmd or die_tool("Failed to exec ssh: $!");
}

sub main {

    require_cmd('ssh');
    my $ssh_path = find_in_path('ssh');

    ensure_known_hosts_exists();
    setup_ssh_askpass();
    setup_openbsd_sandbox();

    # Loads state, parses known_hosts, validates before pruning, then sorts.
    refresh_entries();

    logw("Skipped $hashed_count hashed known_hosts entries.")
      if $hashed_count > 0;

    my $selected_idx     = select_entry_menu();
    my $selected_host    = $entries[$selected_idx]{host};
    my $selected_port    = $entries[$selected_idx]{port};
    my $selected_display = $entries[$selected_idx]{display};
    my $selected_key     = entry_key( $selected_host, $selected_port );

    logi("Selected server: $selected_display");

    my $ssh_user = question_ssh_user($selected_key);
    my @cmd =
      build_ssh_command( $ssh_path, $ssh_user, $selected_host, $selected_port );

    update_frequency($selected_key);
    exec_ssh_command(@cmd);
}

main() unless caller;

__END__

=head1 NAME

ssh-menu.pl - interactive SSH launcher built from F<~/.ssh/known_hosts>

=head1 SYNOPSIS

  perl ssh-menu.pl

  SSH_MENU_KNOWN_HOSTS=~/.ssh/known_hosts.menu perl ssh-menu.pl

=head1 DESCRIPTION

B<ssh-menu.pl> reads an OpenSSH F<known_hosts> file, lists the hosts it
contains and lets you pick one to connect to with C<ssh>. It is fully
interactive and takes no command-line options.

Plain host lines are used; marker lines (C<@cert-authority>, C<@revoked>) and
hashed entries (C<|1|...>) are ignored because they do not name a connectable
host. Duplicate host/port pairs are collapsed.

For every host it can remember a custom alias and the last SSH user, and it
tracks how often each host is used so that recurrent hosts move to the top of
the menu. Aliases, frequencies and last users are stored under F<~/.cache/ssh-menu/>.

When L<ksshaskpass> is found in C<PATH>, C<SSH_ASKPASS> and
C<SSH_ASKPASS_REQUIRE> are exported so C<ssh> can use a graphical passphrase
prompt.

=head1 ENVIRONMENT

=over 4

=item B<SSH_MENU_KNOWN_HOSTS>

Path to the F<known_hosts> file to read. Default: F<~/.ssh/known_hosts>.

=item B<SSH_MENU_FREQ_FILE>

Frequency database. Default: F<~/.cache/ssh-menu/frequencies>.

=item B<SSH_MENU_ALIAS_FILE>

Alias database. Default: F<~/.cache/ssh-menu/aliases>.

=item B<SSH_MENU_LAST_USER_FILE>

Last-used SSH user per host. Default: F<~/.cache/ssh-menu/last-user>.

=item B<SSH_MENU_USER>

Default SSH user offered when neither a remembered user nor C<USER> is set.

=item B<SSH_ASKPASS>, B<SSH_ASKPASS_REQUIRE>

Set automatically for C<ssh> when L<ksshaskpass> is available.

=item B<HOME>

Used to locate the default files; on Windows, C<USERPROFILE> is used instead.

=back

=head1 FILES

=over 4

=item F<~/.ssh/known_hosts>

Source of the host list.

=item F<~/.cache/ssh-menu/frequencies>

C<host:port count> lines (C<default> is used when there is no port).

=item F<~/.cache/ssh-menu/aliases>

C<host:port alias> lines.

=item F<~/.cache/ssh-menu/last-user>

C<host:port user> lines.

=back

=head1 MENU

The menu lists numbered hosts followed by three action entries:

  N+1) Manage known_hosts (delete)
  N+2) Add custom name (alias)
  N+3) Quit

Entering a number selects that server. Entering C<q> at a selection prompt
quits; the SSH-user and alias text prompts treat it as literal input.
Deleting an entry asks for confirmation (C<y>) and rewrites the
F<known_hosts> file atomically, preserving its permissions and keeping
comments, markers and hashed lines.

=head1 SSH

Once a host is chosen, the program asks for the SSH user (pre-filled with the
remembered user, then C<SSH_MENU_USER>, then C<USER>/C<USERNAME>) and launches:

  ssh [-p PORT] USER@HOST

The connection therefore uses the user's normal SSH configuration, keys and
known_hosts verification.

=head1 OPENBSD SANDBOX

On OpenBSD the program unveils the directories in C<PATH> (read/execute) and
the directories holding its state files (read/write/create), then locks the
veil and pledges C<stdio rpath wpath cpath fattr exec proc inet dns unix>.
Sandbox setup is best-effort: a failure is reported as a warning and the
program continues.

=head1 EXIT STATUS

  0  quit cleanly from the menu
  1  missing ssh, missing known_hosts, closed input, or another fatal error

When C<ssh> is launched, the process is replaced on Unix. On Windows the
launcher waits for C<ssh> to finish and forwards its exit status.

=head1 DEPENDENCIES

Core modules only: L<File::Path>, L<File::Spec>, L<File::Temp>. The external
C<ssh> client is required. L<ksshaskpass> is optional.

=head1 EXAMPLES

  # Use the default ~/.ssh/known_hosts
  perl ssh-menu.pl

  # Use a dedicated, non-hashed host file
  SSH_MENU_KNOWN_HOSTS=~/.ssh/known_hosts.menu perl ssh-menu.pl

=head1 LIMITATIONS

=over 4

=item * Hashed F<known_hosts> entries cannot be decoded and are skipped (with a
warning); only plain host lines can be listed and deleted.

=item * Aliases, frequencies and last users are keyed by C<host:port>; editing
C<known_hosts> by other means leaves stale keys that are pruned on the next
run.

=item * There is no X11/SSH-agent management: it simply runs C<ssh> with the
selected host and user.

=back

=cut
