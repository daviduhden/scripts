# Shared helpers for the Perl regression suites.
#
# The module only uses core Perl modules and disposable filesystem trees.
# See the LICENSE file at the top of the project tree for copyright and
# license details.
package TestHarness;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
  collect_output
  dir_entries
  env_with
  extract_function
  files_under
  find_command
  find_files
  find_matching
  functions_without_main
  is_linux
  is_windows
  list_tree
  matching_entries
  new_tempdir
  read_line
  repo_root
  run_command
  run_concurrent
  shell_quote
  slurp
  spawn_command
  trim
  write_file
);

use Cwd            qw(abs_path getcwd);
use File::Basename qw(basename dirname);
use File::Find     qw(find);
use File::Path     qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Select;
use IPC::Open3  qw(open3);
use POSIX       qw(WNOHANG);
use Symbol      qw(gensym);
use Time::HiRes qw(sleep time);

sub repo_root {
    return abs_path(
        File::Spec->catdir( dirname(__FILE__), File::Spec->updir ) );
}

sub is_linux {
    return $^O =~ /linux/ ? 1 : 0;
}

sub is_windows {
    return $^O eq 'MSWin32' ? 1 : 0;
}

sub new_tempdir {
    my ($prefix) = @_;
    $prefix = 'tests-' unless defined $prefix && length $prefix;
    return tempdir( $prefix . 'XXXXXX', TMPDIR => 1, CLEANUP => 1 );
}

sub slurp {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $content = <$handle>;
    close $handle or die "cannot close $path: $!";
    return defined $content ? $content : '';
}

sub write_file {
    my ( $path, $content ) = @_;
    $content = '' unless defined $content;
    my $parent = dirname($path);
    make_path($parent) unless -d $parent;
    open my $handle, '>:raw', $path or die "cannot write $path: $!";
    print {$handle} $content or die "cannot write $path: $!";
    close $handle            or die "cannot close $path: $!";
    return $path;
}

sub trim {
    my ($value) = @_;
    return '' unless defined $value;
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    return $value;
}

sub env_with {
    my (%overrides) = @_;
    my %environment = %ENV;
    for my $name ( keys %overrides ) {
        if ( defined $overrides{$name} ) {
            $environment{$name} = $overrides{$name};
        }
        else {
            delete $environment{$name};
        }
    }
    return \%environment;
}

sub find_command {
    my ($name) = @_;
    for my $directory ( File::Spec->path ) {
        next unless defined $directory && length $directory;
        my $candidate = File::Spec->catfile( $directory, $name );
        return $candidate if -f $candidate && -x $candidate;
    }
    return;
}

sub shell_quote {
    my ($value) = @_;
    return "''" unless defined $value && length $value;
    my $escaped = $value;
    $escaped =~ s/\x27/\x27\x22\x27\x22\x27/g;
    return "'" . $escaped . "'";
}

sub extract_function {
    my ( $text, $name ) = @_;
    my @lines = split /\n/, $text, -1;
    my $start;
    for my $index ( 0 .. $#lines ) {
        if ( $lines[$index] =~ /^\Q$name\E\(\) \{/ ) {
            $start = $index;
            last;
        }
    }
    die "function $name not found" unless defined $start;
    my $end;
    for my $index ( $start + 1 .. $#lines ) {
        if ( $lines[$index] eq '}' ) {
            $end = $index;
            last;
        }
    }
    die "function $name not terminated" unless defined $end;
    return join "\n", @lines[ $start .. $end ];
}

sub functions_without_main {
    my ($path) = @_;
    my $text   = slurp($path);
    my $marker = "\nmain \"\$@\"";
    my $index  = rindex( $text, $marker );
    die "main invocation not found in $path" if $index < 0;
    my $suffix = substr( $text, $index + length $marker );
    die "Unexpected code after main in $path" if $suffix =~ /\S/;
    return substr( $text, 0, $index );
}

sub _wait_status {
    my ( $pid, $timed_out ) = @_;
    if ($timed_out) {
        kill 'TERM', $pid;
        my $reaped = waitpid( $pid, WNOHANG );
        if ( $reaped == 0 ) {
            sleep 0.1;
            $reaped = waitpid( $pid, WNOHANG );
        }
        if ( $reaped == 0 ) {
            kill 'KILL', $pid;
            waitpid( $pid, 0 );
        }
    }
    else {
        waitpid( $pid, 0 );
    }
    my $status = $?;
    return {
        exit       => $status >> 8,
        signal     => $status & 127,
        returncode => ( $status & 127 )
        ? -( ( $status & 127 ) )
        : ( $status >> 8 ),
    };
}

sub spawn_command {
    my (%options) = @_;
    my $command = $options{cmd};
    die 'cmd must be an array reference'
      unless ref($command) eq 'ARRAY' && @$command;

    my $old_cwd = getcwd();
    if ( defined $options{cwd} ) {
        chdir $options{cwd} or die "cannot chdir to $options{cwd}: $!";
    }

    my ( $stdin, $stdout, $pid );
    my $stderr = gensym;
    my $ok     = eval {
        {
            local %ENV = defined $options{env} ? %{ $options{env} } : %ENV;
            $pid = open3( $stdin, $stdout, $stderr, @$command );
        }
        1;
    };
    my $error = $@;

    if ( defined $options{cwd} ) {
        chdir $old_cwd or die "cannot restore $old_cwd: $!";
    }
    die $error unless $ok;

    return {
        pid   => $pid,
        in    => $stdin,
        out   => $stdout,
        err   => $stderr,
        cwd   => $options{cwd},
        start => $old_cwd,
    };
}

sub collect_output {
    my ( $process, $timeout, %initial ) = @_;
    $timeout = 20 unless defined $timeout;

    my $stdout = $initial{stdout};
    my $stderr = $initial{stderr};
    $stdout = '' unless defined $stdout;
    $stderr = '' unless defined $stderr;

    my $select = IO::Select->new();
    my %buffers;
    for my $handle ( grep { defined } $process->{out}, $process->{err} ) {
        my $descriptor = fileno($handle);
        $select->add($handle);
        $buffers{$descriptor} = '';
    }
    $buffers{ fileno( $process->{out} ) } = $stdout;
    $buffers{ fileno( $process->{err} ) } = $stderr
      if defined $process->{err};

    my $deadline  = time() + $timeout;
    my $timed_out = 0;
    while ( $select->count() ) {
        my $remaining = $deadline - time();
        if ( $remaining <= 0 ) {
            $timed_out = 1;
            last;
        }
        my @ready = $select->can_read($remaining);
        if ( !@ready ) {
            $timed_out = 1;
            last;
        }
        for my $handle (@ready) {
            my $descriptor = fileno($handle);
            my $read       = sysread( $handle, my $chunk, 65_536 );
            if ( !defined $read || $read == 0 ) {
                $select->remove($handle);
                next;
            }
            $buffers{$descriptor} .= $chunk;
        }
    }

    my $status = _wait_status( $process->{pid}, $timed_out );
    return {
        %{$status},
        stdout => $buffers{ fileno( $process->{out} ) } // '',
        stderr => defined $process->{err}
        ? ( $buffers{ fileno( $process->{err} ) } // '' )
        : '',
        timed_out => $timed_out,
    };
}

sub run_command {
    my (%options) = @_;
    my $timeout   = defined $options{timeout} ? $options{timeout} : 20;
    my $process   = spawn_command(%options);

    local $SIG{PIPE} = 'IGNORE';
    if ( defined $options{stdin} ) {
        print { $process->{in} } $options{stdin};
    }
    close $process->{in};

    return collect_output( $process, $timeout );
}

sub run_concurrent {
    my ( $specifications, $timeout ) = @_;
    $timeout = 20 unless defined $timeout;

    my @processes;
    for my $specification (@$specifications) {
        push @processes, spawn_command(%$specification);
    }

    my $select = IO::Select->new();
    my %buffers;
    my %owners;
    for my $index ( 0 .. $#processes ) {
        close $processes[$index]{in};
        for my $stream (qw(out err)) {
            my $handle     = $processes[$index]{$stream};
            my $descriptor = fileno($handle);
            $owners{$descriptor}  = [ $index, $stream ];
            $buffers{$descriptor} = '';
            $select->add($handle);
        }
    }

    my $deadline  = time() + $timeout;
    my $timed_out = 0;
    while ( $select->count() ) {
        my $remaining = $deadline - time();
        if ( $remaining <= 0 ) {
            $timed_out = 1;
            last;
        }
        my @ready = $select->can_read($remaining);
        if ( !@ready ) {
            $timed_out = 1;
            last;
        }
        for my $handle (@ready) {
            my $descriptor = fileno($handle);
            my $read       = sysread( $handle, my $chunk, 65_536 );
            if ( !defined $read || $read == 0 ) {
                $select->remove($handle);
                next;
            }
            $buffers{$descriptor} .= $chunk;
        }
    }

    if ($timed_out) {
        kill 'TERM', map { $_->{pid} } @processes;
        sleep 0.1;
    }

    my @results;
    for my $process (@processes) {
        my $status = _wait_status( $process->{pid}, $timed_out );
        push @results,
          {
            %{$status},
            stdout    => $buffers{ fileno( $process->{out} ) } // '',
            stderr    => $buffers{ fileno( $process->{err} ) } // '',
            timed_out => $timed_out,
          };
    }
    return \@results;
}

sub read_line {
    my ( $handle, $timeout ) = @_;
    $timeout = 20 unless defined $timeout;
    my $select   = IO::Select->new($handle);
    my $buffer   = '';
    my $deadline = time() + $timeout;
    while (1) {
        if ( $buffer =~ /\n/ ) {
            my ( $line, $rest ) = split /\n/, $buffer, 2;
            return ( $line, $rest );
        }
        my $remaining = $deadline - time();
        return ( undef, $buffer ) if $remaining <= 0;
        my @ready = $select->can_read($remaining);
        return ( undef, $buffer ) unless @ready;
        my $read = sysread( $handle, my $chunk, 4096 );
        return ( undef, $buffer ) if !defined $read || $read == 0;
        $buffer .= $chunk;
    }
}

sub list_tree {
    my ($root) = @_;
    my @entries;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return if $path eq $root;
                my $relative = File::Spec->abs2rel( $path, $root );
                $relative =~ s{\\}{/}g;
                push @entries, $relative;
            },
        },
        $root
    );
    my @sorted = sort @entries;
    return @sorted;
}

sub files_under {
    my ($root) = @_;
    my %contents;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless -f $path;
                my $relative = File::Spec->abs2rel( $path, $root );
                $relative =~ s{\\}{/}g;
                $contents{$relative} = slurp($path);
            },
        },
        $root
    );
    return \%contents;
}

sub find_files {
    my ( $root, $pattern ) = @_;
    my @matches;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless -f $path;
                my $relative = File::Spec->abs2rel( $path, $root );
                $relative =~ s{\\}{/}g;
                push @matches, $relative if $relative =~ $pattern;
            },
        },
        $root
    );
    my @sorted = sort @matches;
    return @sorted;
}

sub find_matching {
    my ( $root, $pattern ) = @_;
    my @matches;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless basename($path) =~ $pattern;
                my $relative = File::Spec->abs2rel( $path, $root );
                $relative =~ s{\\}{/}g;
                push @matches, $relative;
            },
        },
        $root
    );
    my @sorted = sort @matches;
    return @sorted;
}

sub dir_entries {
    my ($directory) = @_;
    opendir my $handle, $directory or die "cannot read $directory: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $handle;
    closedir $handle or die "cannot close $directory: $!";
    my @sorted = sort @entries;
    return @sorted;
}

sub matching_entries {
    my ( $directory, $pattern ) = @_;
    return grep { $_ =~ $pattern } dir_entries($directory);
}

1;
