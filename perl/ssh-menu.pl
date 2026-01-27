#!/usr/bin/env perl

# Interactive SSH launcher using entries from ~/.ssh/known_hosts:
#  - Exports SSH_ASKPASS/SSH_ASKPASS_REQUIRE for ksshaskpass GUI password prompts
#  - Parses known_hosts and builds a de-duplicated list of hosts (and custom ports)
#  - Shows an interactive numbered menu to choose a server
#  - Prompts for the SSH username
#  - Executes ssh to the selected host (with -p if a custom port is present)
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

if ( !-f $known_hosts ) {
    error("$known_hosts not found.");
}

#######################################
# 1. Export environment variables     #
#######################################

# Simple PATH search for ksshaskpass (no extra modules needed)
sub find_in_path {
    my ($prog) = @_;
    for my $dir ( split /:/, $ENV{PATH} || '' ) {
        next unless length $dir;
        my $full = "$dir/$prog";
        return $full if -x $full;
    }
    return;
}

my $ksshaskpass = find_in_path('ksshaskpass');

if ($ksshaskpass) {
    $ENV{SSH_ASKPASS}         = $ksshaskpass;
    $ENV{SSH_ASKPASS_REQUIRE} = 'prefer';    # or 'force' if you want always GUI
}
else {
    logw('ksshaskpass not found in PATH; continuing without SSH_ASKPASS');
}

#######################################
# 2. Build host list from known_hosts #
#######################################

my @entries;
my %seen;
my $hashed_count = 0;
my %freq;
my $freq_file_exists = -f $freq_file ? 1 : 0;

if ($freq_file_exists) {
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

open my $fh, '<', $known_hosts
  or error("cannot open $known_hosts: $!");

while ( my $line = <$fh> ) {
    chomp $line;
    next if $line =~ /^\s*$/;
    next if $line =~ /^\s*#/;

    if ( $line =~ /^\s*\|/ ) {
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

    my $key = join ':', $host, ( $port || 'default' );
    next if $seen{$key}++;

    my $display;
    if ( @parts > 1 ) {
        my @aliases   = @parts[ 1 .. $#parts ];
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

    push @entries,
      {
        host    => $host,
        port    => $port,
        display => $display,
        freq    => $freq{$key} // 0,
      };
}
close $fh;

if ( !@entries ) {
    if ( $hashed_count > 0 ) {
        error(  "No valid plain hosts found in $known_hosts.\n"
              . "It looks like your known_hosts file contains only hashed entries.\n"
              . "This script cannot recover hostnames from hashed lines.\n"
              . "Consider keeping a separate non-hashed file (e.g. ~/.ssh/known_hosts.menu)\n"
              . "for use with this menu script." );
    }
    else {
        error("No valid hosts found in $known_hosts.");
    }
}

if ($freq_file_exists) {
    @entries = sort {
             ( $b->{freq} <=> $a->{freq} )
          || ( lc $a->{display} cmp lc $b->{display} )
    } @entries;
}
else {
    @entries = sort { lc $a->{display} cmp lc $b->{display} } @entries;
}

logw("Skipped $hashed_count hashed known_hosts entries.")
  if $hashed_count > 0;

##########################################
# 3. Interactive menu to choose a server #
##########################################

logi("Select a server to connect to:");
print "\n";
for my $i ( 0 .. $#entries ) {
    printf "  ${CYAN}%2d)${RESET} ${BOLD}%s${RESET}\n", $i + 1,
      $entries[$i]{display};
}
printf "  ${CYAN}%2d)${RESET} ${BOLD}Quit${RESET}\n\n", scalar(@entries) + 1;

my $selected_idx;
while (1) {
    print "Choice [1-", scalar(@entries) + 1, "]: ";
    my $input = <STDIN>;
    defined $input or error("Input closed.");
    chomp $input;
    if ( $input =~ /^[qQ]$/ ) {
        logi("Exiting.");
        exit 0;
    }

    next if $input !~ /^\d+$/;

    my $num = int($input);

    if ( $num == scalar(@entries) + 1 ) {
        logi("Exiting.");
        exit 0;
    }

    if ( $num >= 1 && $num <= scalar(@entries) ) {
        $selected_idx = $num - 1;
        last;
    }

    logw("Invalid option. Please try again.");
}

my $selected_host    = $entries[$selected_idx]{host};
my $selected_port    = $entries[$selected_idx]{port};
my $selected_display = $entries[$selected_idx]{display};
my $selected_key = join ':', $selected_host, ( $selected_port || 'default' );

logi("Selected server: $selected_display");

#######################
# 4. Ask for SSH user #
#######################

my $default_user = $ENV{SSH_MENU_USER} // $ENV{USER} // '';

print "${BOLD}SSH user${RESET}"
  . ( length $default_user ? " [${CYAN}$default_user${RESET}]" : '' ) . ": ";
my $ssh_user = <STDIN>;
defined $ssh_user or error("Input closed.");
chomp $ssh_user;

if ( !length $ssh_user ) {
    if ( length $default_user ) {
        $ssh_user = $default_user;
    }
    else {
        error("Empty user. Aborting.");
    }
}

if ( $ssh_user =~ /^\s+$/ ) {
    error("Empty user. Aborting.");
}

######################
# 5. Connect via SSH #
######################

my @cmd;
if ($selected_port) {
    logi("Connecting to $ssh_user\@$selected_host (port $selected_port)...");
    @cmd = ( 'ssh', '-p', $selected_port, "$ssh_user\@$selected_host" );
}
else {
    logi("Connecting to $ssh_user\@$selected_host ...");
    @cmd = ( 'ssh', "$ssh_user\@$selected_host" );
}

$freq{$selected_key} = ( $freq{$selected_key} // 0 ) + 1;
eval {
    my ($dir) = $freq_file =~ m{^(.*)/[^/]+$};
    make_path($dir) if defined $dir && length $dir;
    if ( open my $ffh, '>', $freq_file ) {
        for my $k ( sort keys %freq ) {
            printf $ffh "%s %d\n", $k, $freq{$k};
        }
        close $ffh;
    }
    else {
        logw("Could not write frequency file $freq_file: $!");
    }
};
if ($@) {
    logw("Could not persist frequency file: $@");
}

exec @cmd or error("Failed to exec ssh: $!");
