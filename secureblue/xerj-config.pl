#!/usr/bin/env perl
# User-level MCP configuration helper for the POSIX xerj updaters.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use Fcntl          qw(LOCK_EX O_NOFOLLOW O_RDONLY);
use Encode         qw(decode FB_CROAK);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir tempfile);
use JSON::PP       ();
use POSIX          qw(_exit);

my ( $client, $binary, $url, $swival ) = @ARGV;
if (   !defined $client
    || @ARGV != ( $client eq 'swival' ? 4 : 3 )
    || ( $client eq 'swival' && ( $swival !~ m{\A/} || !-x $swival ) )
    || $binary !~ m{\A/}
    || $binary =~ /[\x00-\x1f\x7f]/
    || $url !~
m{\Ahttps?://(?:\[[a-fA-F0-9:.]+\]|[A-Za-z0-9._-]+)(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?\z}
    || $client !~
    /\A(?:crush|opencode[12]?|copilot-cli|claude|swival|codex-check)\z/ )
{
    print STDERR "Usage: xerj-config.pl CLIENT BINARY URL [SWIVAL]\n";
    exit 2;
}

my $json = JSON::PP->new->utf8->canonical;
$binary = decode( 'UTF-8', $binary, FB_CROAK );

sub read_json {
    my ($text) = @_;

    # Avoid decode errors that quote nearby user configuration secrets.
    my $value = eval { $json->decode($text) };
    die "Invalid or unsupported JSON configuration\n" if $@;
    my @keys;
    while ( $text =~ /("(?:[^"\\]|\\.)*")\s*(:?)|([{}])/g ) {
        my ( $string, $colon, $brace ) = ( $1, $2, $3 );
        if ( defined $brace ) {
            if ( $brace eq '{' ) { push @keys, {}; }
            else                 { pop @keys; }
        }
        elsif ($colon) {
            my $key = $json->decode("[$string]")->[0];
            die "Duplicate property in JSON configuration\n"
              if $keys[-1]{$key}++;
        }
    }
    return $value;
}

sub same_command {
    my ( $command, $args ) = @_;
    return
         defined($command)
      && !ref($command)
      && $command eq $binary
      && ref($args) eq 'ARRAY'
      && @$args == 3
      && !( grep { !defined || ref } @$args )
      && $args->[0] eq 'mcp'
      && $args->[1] eq '--url';
}

sub conflict { die "Existing xerj MCP definition requires manual editing\n"; }

if ( $client eq 'codex-check' ) {
    my $payload = do { local $/; <STDIN> }
      // '';
    my $existing = read_json($payload);
    die "Unexpected Codex MCP response\n" unless ref($existing) eq 'HASH';
    my $transport = $existing->{transport};
    conflict()
      unless ref($transport) eq 'HASH'
      && ( $transport->{type} // '' ) eq 'stdio'
      && same_command( $transport->{command}, $transport->{args} );
    if ( $transport->{args}[2] eq $url ) { print "current\n"; exit 0; }

    # Codex's JSON view omits some supported TOML keys. Re-adding an
    # existing entry could silently discard them.
    conflict();
}

my $home = $ENV{HOME} // '';
my $root = $ENV{XDG_CONFIG_HOME} || "$home/.config";
my $path;
if ( $client eq 'crush' ) {
    my $dir = $ENV{CRUSH_GLOBAL_CONFIG} || "$root/crush";
    $path = "$dir/crushrc";
}
elsif ( $client eq 'copilot-cli' ) {
    my $dir = $ENV{COPILOT_HOME} || "$home/.copilot";
    $path = "$dir/mcp-config.json";
}
elsif ( $client eq 'swival' ) {
    $path = "$root/swival/config.toml";
}
elsif ( $client eq 'claude' ) {
    my $dir = $ENV{CLAUDE_CONFIG_DIR} || $home;
    $path = "$dir/.claude.json";
}
else {
    die "An OpenCode configuration override requires manual registration\n"
      if length( $ENV{OPENCODE_CONFIG}         // '' )
      || length( $ENV{OPENCODE_CONFIG_CONTENT} // '' )
      || length( $ENV{OPENCODE_CONFIG_DIR}     // '' );
    $path = "$root/opencode/opencode.json";
    if ( -e "${path}c" || -l "${path}c" ) {
        die "Merge xerj into existing opencode.jsonc manually\n";
    }
}
die "Configuration path must be absolute\n"
  unless $home =~ m{\A/}
  && $path     =~ m{\A/}
  && $path     !~ /[\x00-\x1f\x7f]/;

umask oct('077');
my $directory = dirname($path);
make_path($directory);
open my $lock, '<', $directory
  or die "Cannot open configuration directory: $!\n";
flock $lock, LOCK_EX or die "Cannot lock configuration directory: $!\n";

sub read_config {
    my ($file) = @_;
    return ( '', [] ) unless -e $file || -l $file;
    die "Cannot replace a symlink or non-regular configuration\n"
      if -l $file || !-f $file;
    sysopen my $in, $file, O_RDONLY | O_NOFOLLOW
      or die "Cannot open configuration: $!\n";
    die "Configuration must be a user-owned regular file\n"
      unless -f $in && -O $in;
    my @info     = stat($in);
    my $limit    = 64 * 1024 * 1024;
    my $contents = '';
    die "Configuration exceeds size limit\n" if $info[7] > $limit;

    while (1) {
        my $count = sysread $in, my $buffer, 65536;
        die "Cannot read configuration: $!\n" unless defined $count;
        last                                  unless $count;
        $contents .= $buffer;
        die "Configuration exceeds size limit\n" if length($contents) > $limit;
    }
    close $in or die "Cannot close configuration: $!\n";
    return ( $contents, [ @info[ 0, 1, 2, 4, 7, 9, 10 ] ] );
}

my ( $old, $snapshot ) = read_config($path);
my $mode = @$snapshot ? $snapshot->[2] & oct('777') : oct('600');

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub validate_shell {
    my ($file) = @_;
    my $pid = fork();
    die "Cannot start shell syntax check\n" unless defined $pid;
    if ( !$pid ) {
        open STDOUT, '>', '/dev/null' or _exit(1);
        open STDERR, '>', '/dev/null' or _exit(1);
        delete $ENV{BASH_ENV};
        exec '/bin/bash', '--noprofile', '--norc', '-p', '-n', '--', $file
          or _exit(1);
    }
    die "Crush configuration failed its Bash syntax check\n"
      unless waitpid( $pid, 0 ) == $pid && $? == 0;
}

sub object_at {
    my ( $parent, $key ) = @_;
    $parent->{$key} = {} unless exists $parent->{$key};
    die "Expected an MCP configuration object\n"
      unless ref( $parent->{$key} ) eq 'HASH';
    return $parent->{$key};
}

sub update_entry {
    my ( $servers, $style ) = @_;
    if ( exists $servers->{xerj} ) {
        my $entry = $servers->{xerj};
        conflict() unless ref($entry) eq 'HASH';
        if ( $style =~ /\Aopencode/ ) {
            my $cmd = $entry->{command};
            conflict()
              unless ( $entry->{type} // '' ) eq 'local'
              && ref($cmd) eq 'ARRAY'
              && @$cmd == 4
              && same_command( $cmd->[0], [ @$cmd[ 1 .. 3 ] ] );
            $cmd->[3] = $url;
        }
        else {
            conflict()
              unless ( $entry->{type} // '' ) =~ /\A(?:stdio|local)\z/
              && same_command( $entry->{command}, $entry->{args} );
            $entry->{args}[2] = $url;
        }
    }
    elsif ( $style =~ /\Aopencode/ ) {
        my $entry =
          { type => 'local', command => [ $binary, 'mcp', '--url', $url ] };
        $entry->{enabled} = JSON::PP::true if $style eq 'opencode1';
        $servers->{xerj}  = $entry;
    }
    else {
        my $entry = {
            type    => 'stdio',
            command => $binary,
            args    => [ 'mcp', '--url', $url ],
            env     => {}
        };
        if ( $style eq 'copilot-cli' ) {
            $entry->{type}  = 'local';
            $entry->{tools} = ['*'];
        }
        $servers->{xerj} = $entry;
    }
}

sub validate_swival {
    my ( $candidate, $stage ) = @_;
    my $config = "$stage/swival/config.toml";
    open my $out, '>:raw', $config or die "Cannot stage Swival TOML\n";
    print {$out} $candidate or die "Cannot write staged Swival TOML\n";
    close $out              or die "Cannot close staged Swival TOML\n";

    my $pid = fork();
    die "Cannot start Swival configuration validation\n" unless defined $pid;
    if ( !$pid ) {
        open STDIN,  '<', '/dev/null' or _exit(1);
        open STDOUT, '>', '/dev/null' or _exit(1);
        open STDERR, '>', '/dev/null' or _exit(1);
        $ENV{XDG_CONFIG_HOME} = $stage;
        exec '/usr/bin/timeout', '--kill-after=3s', '20s', $swival,
          '--list-profiles', '--base-dir', "$stage/project"
          or _exit(1);
    }
    waitpid( $pid, 0 );
    die "Swival could not validate its TOML configuration\n" if $?;
}

sub swival_config {
    my ($body)      = @_;
    my $begin       = '# BEGIN xerj managed';
    my $end         = '# END xerj managed';
    my $command     = $json->encode($binary);
    my $table       = '[mcp_servers.xerj]';
    my $prefix      = "args = [\"mcp\", \"--url\", ";
    my $encoded_url = $json->encode($url);
    my $wanted =
        "$begin\n$table\ncommand = $command\n"
      . $prefix
      . $encoded_url
      . "]\n$end\n";

    if ( $body =~ /^(?:\Q$begin\E|\Q$end\E)\r?$/m ) {
        my $count = () = $body =~ /^(?:\Q$begin\E|\Q$end\E)\r?$/mg;
        conflict() if $count != 2;
        $body =~ s{
            (^\Q$begin\E\r?\n
            \Q$table\E\r?\n
            command\ =\ \Q$command\E\r?\n
            \Q$prefix\E)"https?://[^"\r\n]+"
            (\]\r?\n\Q$end\E\r?(?:\n|\z)\s*\z)
        }{$1$encoded_url$2}mx or conflict();
    }
    else {
        $body .= "\n" if length($body) && $body !~ /\n\z/;
        $body .= $wanted;
    }
    return $body;
}

my $text;
if ( $client eq 'swival' ) {
    my $stage =
      tempdir( '.xerj-swival-XXXXXX', DIR => $directory, CLEANUP => 1 );
    make_path( "$stage/swival", "$stage/project" );
    $text = swival_config($old);
    validate_swival( $old,  $stage ) if length($old);
    validate_swival( $text, $stage ) if $text ne $old || !length($old);
}
elsif ( $client eq 'crush' ) {
    my ($legacy) = read_config("$directory/crush.json");
    if ( $legacy =~ /\S/ ) {
        my $old_json = read_json($legacy);
        die "Unrecognized legacy Crush configuration\n"
          unless ref($old_json) eq 'HASH'
          && ( !exists $old_json->{mcp} || ref( $old_json->{mcp} ) eq 'HASH' );
        conflict() if exists $old_json->{mcp} && exists $old_json->{mcp}{xerj};
    }
    my $begin  = '# BEGIN xerj managed';
    my $end    = '# END xerj managed';
    my $start  = '^' . quotemeta($begin) . '\r?$';
    my $stop   = '^' . quotemeta($end) . '\r?$';
    my $starts = () = $old =~ /$start/mg;
    my $ends   = () = $old =~ /$stop/mg;
    die "Malformed xerj managed block\n" if $starts != $ends || $starts > 1;
    my $prefix =
        'mcp add xerj --type stdio --command '
      . shell_quote( Encode::encode_utf8($binary) )
      . ' --args mcp --args --url --args ';
    my $new = "$begin\n$prefix" . shell_quote($url) . "\n$end";
    $text = $old;

    if ($starts) {
        $text =~ s{$start\n\Q$prefix\E'[^'\r\n]*'\r?\n$stop}{$new}m
          or conflict();
    }
    else {
        conflict() if $text =~ /\bmcp\h+add\b[^\r\n]*\bxerj\b/m;
        $text .= "\n" if length($text) && $text !~ /\n\z/;
        $text .= "$new\n";
    }
}
else {
    my $data = length($old) && $old =~ /\S/ ? read_json($old) : {};
    die "Expected a JSON configuration object\n" unless ref($data) eq 'HASH';
    my $before = $json->encode($data);
    my $servers;
    if ( $client =~ /\Aopencode/ ) {
        my $mcp = object_at( $data, 'mcp' );
        if ( $client eq 'opencode2' ) {
            die "Legacy OpenCode MCP configuration requires manual editing\n"
              if grep { $_ ne 'xerj' && $_ ne 'servers' && $_ ne 'timeout' }
              keys %$mcp;
            $servers = object_at( $mcp, 'servers' );
            if ( exists $mcp->{xerj} ) {
                conflict() if exists $servers->{xerj};
                update_entry( $mcp, 'opencode1' );
                my $entry = delete $mcp->{xerj};
                if ( exists $entry->{enabled} ) {
                    conflict()
                      if exists $entry->{disabled}
                      || !JSON::PP::is_bool( $entry->{enabled} );
                    $entry->{disabled} =
                      $entry->{enabled} ? JSON::PP::false : JSON::PP::true;
                    delete $entry->{enabled};
                }
                $servers->{xerj} = $entry;
            }
        }
        else {
            die "OpenCode 2 MCP configuration requires manual editing\n"
              if exists $mcp->{servers};
            $servers = $mcp;
        }
    }
    else {
        $servers = object_at( $data, 'mcpServers' );
    }
    update_entry( $servers, $client );
    exit 0 if $json->encode($data) eq $before;
    $text = $json->pretty->encode($data);
}

exit 0 if $old eq $text;
die "Configuration is read-only\n" unless $mode & oct('200');
my ( $out, $temporary ) =
  tempfile( '.xerj-XXXXXX', DIR => $directory, UNLINK => 1 );
binmode $out       or die "Cannot prepare configuration: $!\n";
print {$out} $text or die "Cannot write configuration: $!\n";
close $out         or die "Cannot close configuration: $!\n";
validate_shell($temporary) if $client eq 'crush';
my ( $latest, $latest_snapshot ) = read_config($path);
die "Configuration changed during registration\n"
  if $old ne $latest || "@$snapshot" ne "@$latest_snapshot";
chmod $mode, $temporary or die "Cannot preserve configuration mode: $!\n";
rename $temporary, $path or die "Cannot publish configuration: $!\n";
