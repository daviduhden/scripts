#!/usr/bin/env perl
#
# Client configuration helper for update-xerj.bash. Kept separate so the
# shell script does not embed Perl in a heredoc.
#
# Usage: xerj-config.pl CLIENT BINARY URL
# CLIENT is "crush" or "opencode".
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use File::Temp     qw(tempfile);
use JSON::PP       ();

my ( $client, $binary, $url ) = @ARGV;
if ( !defined $client || !defined $binary || !defined $url ) {
    print STDERR "Usage: xerj-config.pl CLIENT BINARY URL\n";
    exit 2;
}

my $root = $ENV{XDG_CONFIG_HOME} || "$ENV{HOME}/.config";
my $path =
  "$root/$client/" . ( $client eq 'crush' ? 'crushrc' : 'opencode.json' );
my $old = '';
if ( -f $path ) {
    open my $in, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    $old = <$in>;
    close $in or die "cannot close $path: $!\n";
}

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

my $text;
if ( $client eq 'crush' ) {
    my $begin  = '# BEGIN xerj managed';
    my $end    = '# END xerj managed';
    my $starts = () = $old =~ /\Q$begin\E/g;
    my $ends   = () = $old =~ /\Q$end\E/g;
    die "Malformed xerj managed block\n"
      if $starts != $ends || $starts > 1;
    $old =~ s/\Q$begin\E.*?\Q$end\E\n?//s;
    $old =~ s/\s+\z//;
    $old .= "\n" if length $old;
    $text =
        $old
      . $begin . "\n"
      . 'mcp add xerj --type stdio --command '
      . shell_quote($binary)
      . ' --args mcp --args --url --args '
      . shell_quote($url) . "\n"
      . $end . "\n";
}
elsif ( $client eq 'opencode' ) {
    my $jsonc = "$root/$client/opencode.jsonc";
    die
"Merge xerj into existing opencode.jsonc manually; refusing ambiguous configuration\n"
      if -e $jsonc;
    my $data = length($old) && $old =~ /\S/ ? JSON::PP::decode_json($old) : {};
    die "OpenCode configuration must be a JSON object\n"
      unless ref($data) eq 'HASH';
    $data->{mcp} = {} unless exists $data->{mcp};
    die "OpenCode mcp must be a JSON object\n"
      unless ref( $data->{mcp} ) eq 'HASH';
    $data->{mcp}{xerj} = {
        type    => 'local',
        command => [ $binary, 'mcp', '--url', $url ],
        enabled => JSON::PP::true,
    };
    $text = JSON::PP->new->pretty->canonical->encode($data);
    $text .= "\n" unless $text =~ /\n\z/;
}
else {
    print STDERR "Unknown client: $client\n";
    exit 2;
}

make_path( dirname($path) );
if ( -f $path ) {
    my $backup = "$path.bak.$$." . time;
    copy( $path, $backup ) or die "cannot back up $path: $!\n";
}
my ( $out, $temporary ) = tempfile(
    '.xerj-XXXXXX',
    DIR    => dirname($path),
    UNLINK => 0
);
print {$out} $text or die "cannot write $temporary: $!\n";
close $out         or die "cannot close $temporary: $!\n";
rename $temporary, $path or die "cannot publish $path: $!\n";
print "Configured $path\n";
