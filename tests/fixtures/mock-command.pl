#!__PERL__
use strict;
use warnings;

use File::Basename qw(basename);

my $name = basename($0);
my @args = @ARGV;
exit 0 if $name =~ /\A(?:perlcritic|checkmake|bmake)\z/;

my $path = $args[-1];
open my $input, '<', $path or exit 1;
local $/;
my $text = <$input>;
close $input;

my $drift    = index( $text, "# UNFORMATTED\n" ) >= 0;
my $checking = grep { $_ eq '-l' || $_ eq '--check' || $_ eq '-ast' } @args;
if ($checking) {
    print "$path\n" if $drift && $name eq 'shfmt';
    exit( $drift && $name ne 'shfmt' ? 1 : 0 );
}

$text =~ s/# UNFORMATTED\n//g;
open my $output, '>', $path or exit 1;
print {$output} $text;
close $output;
exit 0;
