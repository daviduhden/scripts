#!/usr/bin/env perl

#
# Interactive SSH launcher using entries from ~/.ssh/known_hosts:
#  - Exports SSH_ASKPASS/SSH_ASKPASS_REQUIRE for ksshaskpass GUI password prompts
#  - Parses known_hosts and builds a de-duplicated list of hosts (and custom ports)
#  - Shows an interactive numbered menu to choose a server
#  - Prompts for the SSH username
#  - Executes ssh to the selected host (with -p if a custom port is present)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

use strict;
use warnings;

use File::Basename;

my $known_hosts = "$ENV{HOME}/.ssh/known_hosts";

if ( !-f $known_hosts ) {
    die "Error: $known_hosts not found.\n";
}

###################################################
# 1. Export environment variables for ksshaskpass #
###################################################

# Simple PATH search for ksshaskpass (no extra modules needed)
sub find_in_path {
    my ($prog) = @_;
    for my $dir (split /:/, $ENV{PATH} || '') {
        next unless length $dir;
        my $full = "$dir/$prog";
        return $full if -x $full;
    }
    return;
}

my $ksshaskpass = find_in_path('ksshaskpass') // '/usr/bin/ksshaskpass';

$ENV{SSH_ASKPASS}         = $ksshaskpass;
$ENV{SSH_ASKPASS_REQUIRE} = 'prefer';  # or 'force' if you want always GUI

#######################################
# 2. Build host list from known_hosts #
#######################################

my @hosts;
my @ports;
my @displays;
my %seen;
my $hashed_count = 0;

open my $fh, '<', $known_hosts
  or die "Error: cannot open $known_hosts: $!\n";

while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*$/;        # skip empty
    next if $line =~ /^\s*#/;        # skip comments

    if ( $line =~ /^\s*\|/ ) {       # hashed entries
        $hashed_count++;
        next;
    }

    # Take first field (host spec: host1,host2,ip,...)
    my ($field) = split /\s+/, $line, 2;
    next unless defined $field && length $field;

    # Split by comma and clean elements
    my @parts = grep {
        defined $_ && length $_ && $_ !~ /^\s*#/ && $_ !~ /^\s*\|/
    } split /,/, $field;

    next unless @parts;

    # Primary host is the first element
    my $primary = $parts[0];
    my $host    = $primary;
    my $port    = '';

    # Match [host]:port
    if ( $host =~ /^\[(.+)\]:(\d+)$/ ) {
        $host = $1;
        $port = $2;
    }

    my $key = join ':', $host, ($port || 'default');

    # Skip duplicates for the same host:port
    next if $seen{$key}++;

    push @hosts, $host;
    push @ports, $port;

    # Build display string (include aliases if present)
    my $display;
    if (@parts > 1) {
        my @aliases   = @parts[1 .. $#parts];
        my $alias_str = join ', ', @aliases;
        if ($port) {
            $display = "$host (port $port; aliases: $alias_str)";
        } else {
            $display = "$host (aliases: $alias_str)";
        }
    } else {
        if ($port) {
            $display = "$host (port $port)";
        } else {
            $display = $host;
        }
    }

    push @displays, $display;
}
close $fh;

if ( !@hosts ) {
    if ( $hashed_count > 0 ) {
        die
          "No valid plain hosts found in $known_hosts.\n"
        . "It looks like your known_hosts file contains only hashed entries.\n"
        . "This script cannot recover hostnames from hashed lines.\n"
        . "Consider keeping a separate non-hashed file (e.g. ~/.ssh/known_hosts.menu)\n"
        . "for use with this menu script.\n";
    } else {
        die "No valid hosts found in $known_hosts.\n";
    }
}

##########################################
# 3. Interactive menu to choose a server #
##########################################

print "Select a server to connect to:\n\n";

for my $i (0 .. $#displays) {
    printf "  %2d) %s\n", $i + 1, $displays[$i];
}
printf "  %2d) Quit\n\n", scalar(@displays) + 1;

my $selected_idx;
while (1) {
    print "Choice [1-", scalar(@displays) + 1, "]: ";
    my $input = <STDIN>;
    defined $input or die "\nInput closed.\n";
    chomp $input;
    next if $input !~ /^\d+$/;

    my $num = int($input);

    if ( $num == scalar(@displays) + 1 ) {
        print "Exiting.\n";
        exit 0;
    }

    if ( $num >= 1 && $num <= scalar(@displays) ) {
        $selected_idx = $num - 1;
        last;
    }

    print "Invalid option. Please try again.\n";
}

my $selected_host = $hosts[$selected_idx];
my $selected_port = $ports[$selected_idx];

print "Selected server: $displays[$selected_idx]\n";

#######################
# 4. Ask for SSH user #
#######################

print "SSH user: ";
my $ssh_user = <STDIN>;
defined $ssh_user or die "\nInput closed.\n";
chomp $ssh_user;

if ( !length $ssh_user ) {
    die "Empty user. Aborting.\n";
}

######################
# 5. Connect via SSH #
######################

print "Connecting to $ssh_user\@$selected_host ...\n";

my @cmd;
if ( $selected_port ) {
    @cmd = ('ssh', '-p', $selected_port, "$ssh_user\@$selected_host");
} else {
    @cmd = ('ssh', "$ssh_user\@$selected_host");
}

exec @cmd or die "Failed to exec ssh: $!\n";
