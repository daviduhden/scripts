#!/usr/bin/env perl
#
# Render and validate Arti configuration for install-arti-service.bash.
#
# This is a standalone helper, not an embedded heredoc. It has two commands:
#
#   arti-config.pl validate PATH
#   arti-config.pl render SOURCE TARGET CONFIG DATA STATE CACHE
#
# The validator accepts a strict subset of TOML 1.0. It supports:
#
#   - table headers ([a], [a.b]) with bare or quoted keys;
#   - key/value pairs with bare, basic-quoted, or literal-quoted keys;
#   - single-line basic strings with standard escapes (\" \\ \b \t \n
#     \f \r \uXXXX \UXXXXXXXX);
#   - single-line literal strings;
#   - arrays of supported values, including trailing commas and comments;
#   - booleans and decimal, hexadecimal, octal, and binary integers;
#   - comments and blank lines.
#
# It deliberately rejects arrays of tables ([[...]]), inline tables,
# multi-line strings, floats, date/time values, and any other syntax it
# does not implement. This keeps validation predictable without a
# non-core TOML module. Duplicate keys and duplicate table declarations
# are errors.
#
# See the LICENSE file at the top of the project tree for copyright and
# license details.

use 5.010_001;
use strict;
use warnings;

use Encode qw(decode encode FB_CROAK);

our $VERSION = '1.0.0';

my $TOM_TEXT;

sub fail {
    my ($message) = @_;
    print STDERR "arti-config: $message\n";
    exit 1;
}

sub read_bytes {
    my ($path) = @_;
    open my $handle, '<:raw', $path
      or die "cannot read $path: $!\n";
    local $/;
    my $bytes = <$handle>;
    close $handle or die "cannot close $path: $!\n";
    return defined $bytes ? $bytes : '';
}

sub read_utf8 {
    my ($path) = @_;
    my $bytes  = read_bytes($path);
    my $text   = eval { decode( 'UTF-8', $bytes, FB_CROAK ) };
    if ( !defined $text ) {
        my $error = $@ || 'invalid UTF-8';
        chomp $error;
        die "$error\n";
    }
    return $text;
}

sub write_utf8 {
    my ( $path, $text ) = @_;
    my $bytes = encode( 'UTF-8', $text );
    open my $handle, '>:raw', $path
      or die "cannot write $path: $!\n";
    print {$handle} $bytes or die "cannot write $path: $!\n";
    close $handle          or die "cannot write $path: $!\n";
    return;
}

sub path_key {
    return join '', map { length($_) . ':' . $_ } @_;
}

sub at_end {
    return pos($TOM_TEXT) >= length($TOM_TEXT);
}

sub peek_char {
    return '' if at_end();
    return substr( $TOM_TEXT, pos($TOM_TEXT), 1 );
}

sub skip_inline_space {
    $TOM_TEXT =~ /\G[ \t]+/gc;
    return;
}

sub skip_comment {
    $TOM_TEXT =~ /\G#[^\r\n]*/gc;
    return;
}

sub skip_newline {
    return 1 if $TOM_TEXT =~ /\G\r\n/gc;
    return 1 if $TOM_TEXT =~ /\G\n/gc;
    return 0;
}

sub skip_blank {
    while (1) {
        skip_inline_space();
        skip_comment();
        next if skip_newline();
        last;
    }
    return;
}

sub expect_char {
    my ($char) = @_;
    die "expected '$char'\n"
      if at_end() || peek_char() ne $char;
    pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    return;
}

sub finish_line {
    skip_inline_space();
    skip_comment();
    return if at_end();
    return if skip_newline();
    die "expected a newline after the statement\n";
}

sub unicode_escape {
    my ($digits) = @_;
    my $hex;
    if ( $digits == 4 ) {
        die "invalid Unicode escape\n"
          unless $TOM_TEXT =~ /\G([0-9A-Fa-f]{4})/gc;
        $hex = $1;
    }
    else {
        die "invalid Unicode escape\n"
          unless $TOM_TEXT =~ /\G([0-9A-Fa-f]{8})/gc;
        $hex = $1;
    }
    my $code = hex $hex;
    die "Unicode escape is out of range\n"
      if $code > 0x10FFFF;
    die "Unicode escape is a surrogate\n"
      if $code >= 0xD800 && $code <= 0xDFFF;
    return chr $code;
}

sub parse_basic_string {
    my %simple = (
        b    => "\b",
        t    => "\t",
        n    => "\n",
        f    => "\f",
        r    => "\r",
        '"'  => '"',
        '\\' => '\\',
    );
    pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    die "multi-line strings are not supported\n"
      if substr( $TOM_TEXT, pos($TOM_TEXT), 2 ) eq '""';
    my $value = '';
    while (1) {
        die "unterminated string\n" if at_end();
        my $char = substr( $TOM_TEXT, pos($TOM_TEXT), 1 );
        if ( $char eq '"' ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            return $value;
        }
        if ( $char eq '\\' ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            die "unterminated escape sequence\n" if at_end();
            my $escape = substr( $TOM_TEXT, pos($TOM_TEXT), 1 );
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            if ( $escape eq 'u' ) {
                $value .= unicode_escape(4);
            }
            elsif ( $escape eq 'U' ) {
                $value .= unicode_escape(8);
            }
            elsif ( exists $simple{$escape} ) {
                $value .= $simple{$escape};
            }
            else {
                die "invalid escape sequence \\$escape\n";
            }
            next;
        }
        my $ordinal = ord $char;
        die "control characters must be escaped in strings\n"
          if ( $ordinal < 0x20 && $char ne "\t" )
          || $ordinal == 0x7F;
        $value .= $char;
        pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    }
}

sub parse_literal_string {
    pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    die "multi-line strings are not supported\n"
      if substr( $TOM_TEXT, pos($TOM_TEXT), 2 ) eq "''";
    my $value = '';
    while (1) {
        die "unterminated string\n" if at_end();
        my $char = substr( $TOM_TEXT, pos($TOM_TEXT), 1 );
        if ( $char eq "'" ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            return $value;
        }
        die "literal strings cannot span lines\n"
          if $char eq "\n" || $char eq "\r";
        my $ordinal = ord $char;
        die "control characters must be escaped in strings\n"
          if ( $ordinal < 0x20 && $char ne "\t" )
          || $ordinal == 0x7F;
        $value .= $char;
        pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    }
}

sub parse_key_path {
    my @parts;
    while (1) {
        skip_inline_space();
        my $char = peek_char();
        my $part;
        if ( $char eq '"' ) {
            $part = parse_basic_string();
        }
        elsif ( $char eq "'" ) {
            $part = parse_literal_string();
        }
        elsif ( $TOM_TEXT =~ /\G([A-Za-z0-9_-]+)/gc ) {
            $part = $1;
        }
        else {
            die "expected a key\n";
        }
        push @parts, $part;
        skip_inline_space();
        last if peek_char() ne '.';
        pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    }
    return @parts;
}

sub parse_array {
    pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    while (1) {
        skip_blank();
        die "unterminated array\n" if at_end();
        if ( peek_char() eq ']' ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            return;
        }
        parse_value();
        skip_blank();
        die "unterminated array\n" if at_end();
        my $char = peek_char();
        if ( $char eq ',' ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            next;
        }
        if ( $char eq ']' ) {
            pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
            return;
        }
        die "expected ',' or ']' in array\n";
    }
}

sub parse_value {
    skip_inline_space();
    my $char = peek_char();
    return parse_basic_string()   if $char eq '"';
    return parse_literal_string() if $char eq "'";
    return parse_array()          if $char eq '[';
    if ( $TOM_TEXT =~ /\G(true|false)(?![A-Za-z0-9_.-])/gc ) {
        return;
    }
    if (
        $TOM_TEXT =~ /\G(
            0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*
          | 0o[0-7](?:_?[0-7])*
          | 0b[01](?:_?[01])*
          | [+-]?(?:0|[1-9](?:_?[0-9])*)
        )(?![A-Za-z0-9_.-])/gcx
      )
    {
        return;
    }
    die "unsupported or invalid value\n";
}

sub parse_table_header {
    pos($TOM_TEXT) = pos($TOM_TEXT) + 1;
    die "arrays of tables are not supported\n"
      if peek_char() eq '[';
    my @path = parse_key_path();
    skip_inline_space();
    expect_char(']');
    finish_line();
    return @path;
}

sub parse_assignment {
    my @keys = parse_key_path();
    skip_inline_space();
    expect_char('=');
    parse_value();
    finish_line();
    return @keys;
}

sub define_table {
    my ( $nodes, $explicit, $path ) = @_;
    my @prefix;
    for my $index ( 0 .. $#$path ) {
        push @prefix, $path->[$index];
        my $key = path_key(@prefix);
        if ( exists $nodes->{$key} ) {
            die "cannot redefine a value as a table\n"
              if $nodes->{$key} eq 'value';
            if ( $index == $#$path ) {
                die "duplicate table declaration\n"
                  if $explicit->{$key};
                $explicit->{$key} = 1;
            }
            next;
        }
        $nodes->{$key}    = 'table';
        $explicit->{$key} = 1 if $index == $#$path;
    }
    return;
}

sub define_value {
    my ( $nodes, $path ) = @_;
    my @prefix;
    for my $index ( 0 .. $#$path - 1 ) {
        push @prefix, $path->[$index];
        my $key = path_key(@prefix);
        if ( exists $nodes->{$key} ) {
            die "cannot redefine a value as a table\n"
              if $nodes->{$key} eq 'value';
            next;
        }
        $nodes->{$key} = 'table';
    }
    my $key = path_key( @{$path} );
    die "duplicate key\n" if exists $nodes->{$key};
    $nodes->{$key} = 'value';
    return;
}

sub validate_toml {
    my ($text) = @_;
    $TOM_TEXT = $text;
    $TOM_TEXT =~ s/\A\x{FEFF}//;
    pos($TOM_TEXT) = 0;
    my %nodes;
    my %explicit;
    my @current;
    while (1) {
        skip_blank();
        last if at_end();
        if ( peek_char() eq '[' ) {
            my @path = parse_table_header();
            define_table( \%nodes, \%explicit, \@path );
            @current = @path;
            next;
        }
        my @keys = parse_assignment();
        my @path = ( @current, @keys );
        define_value( \%nodes, \@path );
    }
    return;
}

sub validate {
    my ($path) = @_;
    my $ok = eval {
        my $text = read_utf8($path);
        validate_toml($text);
        1;
    };
    return if $ok;
    my $error = $@ || 'unknown error';
    chomp $error;
    fail("invalid TOML in $path: $error");
}

sub replace_all {
    my ( $text, $needle, $replacement ) = @_;
    return $text if $needle eq '';
    my $result = '';
    my $start  = 0;
    while (1) {
        my $found = index( $text, $needle, $start );
        last if $found < 0;
        $result .= substr( $text, $start, $found - $start );
        $result .= $replacement;
        $start = $found + length $needle;
    }
    return $result . substr( $text, $start );
}

sub split_lines {
    my ($text) = @_;
    return () if length($text) == 0;
    my @lines;
    my $start  = 0;
    my $index  = 0;
    my $length = length $text;
    while ( $index < $length ) {
        my $char = substr( $text, $index, 1 );
        my $step = 0;
        if ( $char eq "\r" ) {
            $step = 1;
            if ( $index + 1 < $length
                && substr( $text, $index + 1, 1 ) eq "\n" )
            {
                $step = 2;
            }
        }
        elsif ($char eq "\n"
            || $char eq "\x0b"
            || $char eq "\x0c"
            || $char eq "\x1c"
            || $char eq "\x1d"
            || $char eq "\x1e"
            || $char eq "\x85"
            || $char eq "\x{2028}"
            || $char eq "\x{2029}" )
        {
            $step = 1;
        }
        if ($step) {
            push @lines, substr( $text, $start, $index - $start );
            $index += $step;
            $start = $index;
            next;
        }
        $index += 1;
    }
    push @lines, substr( $text, $start ) if $start < $length;
    return @lines;
}

sub quote_path {
    my ( $value, $command ) = @_;
    fail('control characters are not supported in XDG paths')
      if $value =~ /[\x00-\x1f\x7f]/;
    $value =~ s/%/%%/g;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\$/\$\$/g if $command;
    return '"' . $value . '"';
}

sub render {
    my ( $source, $target, $config, $data, $state, $cache ) = @_;
    my @paths = (
        [ '%h/.config/arti',      $config ],
        [ '%h/.local/share/arti', $data ],
        [ '%h/.local/state/arti', $state ],
        [ '%h/.cache/arti',       $cache ],
    );
    my $text;
    my $read_ok = eval { $text = read_utf8($source); 1 };
    if ( !$read_ok ) {
        my $error = $@ || 'unknown error';
        chomp $error;
        fail($error);
    }
    my @result;
    for my $line ( split_lines($text) ) {
        my $command = index( $line, 'Exec' ) == 0 ? 1 : 0;
        for my $entry (@paths) {
            my ( $placeholder, $path ) = @{$entry};
            if ( index( $line, 'UNIX-LISTEN:' . $placeholder ) >= 0 ) {
                fail('socat socket paths cannot contain commas')
                  if index( $path, ',' ) >= 0;
                my $old =
                    'UNIX-LISTEN:'
                  . $placeholder
                  . '/arti-socks.sock,fork,mode=0600';
                my $new = quote_path(
                    'UNIX-LISTEN:' . $path . '/arti-socks.sock,fork,mode=0600',
                    1
                );
                $line = replace_all( $line, $old, $new );
            }
            for my $suffix ( '/arti.toml', '/arti-socks.sock', '' ) {
                $line = replace_all(
                    $line,
                    $placeholder . $suffix,
                    quote_path( $path . $suffix, $command )
                );
            }
        }
        push @result, $line;
    }
    my $output   = join( "\n", @result ) . "\n";
    my $write_ok = eval { write_utf8( $target, $output ); 1 };
    if ( !$write_ok ) {
        my $error = $@ || 'unknown error';
        chomp $error;
        fail($error);
    }
    return;
}

sub main {
    my @arguments = @_;
    if ( @arguments == 2 && $arguments[0] eq 'validate' ) {
        validate( $arguments[1] );
        return 0;
    }
    if ( @arguments == 7 && $arguments[0] eq 'render' ) {
        render( @arguments[ 1 .. 6 ] );
        return 0;
    }
    fail(   'usage: arti-config.pl validate PATH | render '
          . 'SOURCE TARGET CONFIG DATA STATE CACHE' );
}

exit main(@ARGV);
