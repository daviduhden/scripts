# Perl safety remediation and individual critic review

## Scope and result

This review covers the two portable Perl programs and their two Perl regression
files. The code keeps Perl 5.10.1 syntax and core-module dependencies. Validation
used Linux Perl 5.44.0 and Perl::Critic 1.156, loaded from
`/var/home/david/perl5` using process-local PATH/PERL5LIB. Native Windows and the
minimum Perl version were not available for execution; their compatibility has
been reviewed statically, not claimed as tested.

The earlier baseline contained 49 severity-4 and 152 severity-3 diagnostics.
Corrections preserve explicit wrapper results and check eval success. No critic
configuration was weakened, no policy was globally disabled, and no `no critic`
annotations remain in these Perl files. The individual retained diagnostics
below remain visible in a default severity-3 run. Counts can increase as focused
failure tests and explicit errno propagation introduce additional stylistic
warnings; the count is not a defect count or a compliance claim.

## Corrections and boundaries

- Content reads distinguish I/O failure from empty files and use bounded chunks
  with a strict byte cap, including files growing after a size check. The
  normalizer still retains the permitted content for conversion; memory usage
  is bounded by the configured input limit plus conversion buffers.
- Path and handle snapshots (device, inode, mode, size, mtime, ctime) are compared
  before/after reading and before installation. This detects common concurrent
  modifications and path swaps. It is not a lock or a guarantee against a writer
  preserving all compared metadata, nor does it eliminate the final pathname
  check/rename race. Use a quiescent directory when strong consistency matters.
- A failed print, close, chmod or requested utime prevents replacement. The
  original pre-read access timestamp is used when preserving timestamps.
  Ownership, ACLs and extended attributes remain outside the documented
  preservation contract. Report output errors now affect the result status.
- Temporary reservations use File::Temp rather than returning an unreserved
  name after a failed exclusive create. Windows replacement uses unique backup
  names and checks restoration. A failed restore retains the original recovery
  copy and identifies its path. Recovery is best effort, not a transaction
  spanning concurrent writers or process termination.

## Validation

Commands executed with the local Perl tools on PATH and PERL5LIB:

```sh
perl -c perl/normalize-files.pl
perl -c perl/ssh-menu.pl
perl -c tests-format/test-normalize-files.pl
perl -c tests-format/test-ssh-menu.pl
perl tests-format/test-normalize-files.pl
perl tests-format/test-ssh-menu.pl
podchecker perl/normalize-files.pl
podchecker perl/ssh-menu.pl
perlcritic --severity 5 perl/normalize-files.pl perl/ssh-menu.pl tests-format/test-normalize-files.pl tests-format/test-ssh-menu.pl
perlcritic --severity 3 perl/normalize-files.pl perl/ssh-menu.pl tests-format/test-normalize-files.pl tests-format/test-ssh-menu.pl
```

Syntax, both regression programs and both POD checks passed. The normalizer
suite has 44 subtests, including exact/zero byte limits, empty/missing/directory/
symlink inputs, source changes, metadata failure, POSIX mode/timestamp success,
`/dev/full` report failure and Windows recovery failure simulation. The SSH suite
also injects Windows-style rename failures in a child interpreter and verifies
that a preexisting .bak file survives and failed restoration retains the unique
original copy. Simulation does not test native Windows filesystem semantics.
Severity 5 passes. Severity 3 intentionally returns a diagnostic status for the
retained findings below. Formatting uses perltidy with `-npro`; it is separate
from syntax and regression execution.

## Reviewed dispositions

### R1: RequireBriefOpen

Reviewed retention: the handle is lexical and is closed after the streaming parse/read or at the end of its lexical test block. The default nine-line distance is not evidence of a leaked handle. Splitting these loops solely to move close nearer to open would add parameter plumbing; whole-file buffering would increase memory. Keep streaming and retain the diagnostic.

### R2: RequireExtendedFormatting

Intentional compact expressions: the individual patterns below are short anchors, byte classes, substitutions, delimiters, or interpolated user/glob patterns. Adding /x provides no demonstrated correctness benefit. Literal spaces and # in some patterns are significant, so blanket flag insertion could change behavior. Keep current patterns and tests; a future complex pattern should use /x with explicit literal escaping.

### R3: RequireFinalReturn

Reviewed implicit-result compatibility: these routines finish with conditional side effects, parsing loops, or assignments. Their current implicit values are retained rather than replaced with bare return. repo_root_for has a deliberate infinite search loop whose exits return explicitly. Terminal helpers and simple wrappers that could preserve their exact results with explicit return have been corrected separately. This retained warning does not establish a missing control-flow exit.

### R4: RequireCarping

Intentional error attribution: die reports the failing CLI operation or fixture setup, and exceptions in conversion/sandbox code are caught and reported at their established location. Replacing die with croak would alter caller attribution and observable diagnostics without correcting a demonstrated error-handling defect. Both are core mechanisms; retaining die is not ignoring the exception.

### R5: RequireLocalizedPunctuationVars

Intentional caller-visible state: SSH_ASKPASS assignments must survive the setup helper until ssh executes. The other assignments restore or set errno ($!) for the calling operation after cleanup has overwritten it; localizing errno would hide the intended failure from the caller. Diagnostic-only errno restoration was localized instead. These assignments are narrow and deliberate.

### R6: ProhibitExcessComplexity

Deferred structural improvement: inspect the named routine in the row. Sandbox setup accumulates per-path failures; scan_tree uses an iterative walk; plan_renames handles collisions; process_content sequences conversion policy and validation; run coordinates the CLI; known_hosts deletion preserves aliases/markers/links. Extracting these branches only to lower a metric does not change the algorithm and risks transaction ordering. The 75-point process_content remains a maintainability hotspot; a separately scoped refactor should retain the new failure tests and existing conversion matrix.

### R7: ProhibitExplicitStdin

Intentional interactive input boundary: the menu must read the supplied standard input stream. The diamond operator would also consume filenames in ARGV, changing CLI behavior. A prompting dependency is unnecessary for plain line-oriented input and EOF handling.

### R8: ProhibitCascadingIfElse

Intentional ordered decisions: detect_eol classifies the finite newline combinations; glob_regex scans distinct glob tokens and advances its cursor differently for each token. A dispatch map or given/when would add indirection or portability constraints rather than demonstrate a simpler equivalent parser.

### R9: ProhibitExcessMainComplexity

Intentional regression orchestration: these executable tests contain independent assertions and platform guards. Moving the same assertions into wrappers merely to lower top-level complexity would hide the test sequence. Test branches remain bounded and use temporary trees; they are not production request handlers.

### R10: ProhibitNoWarnings

Narrow test-only warning control: scoped typeglob stubs intentionally redefine one helper to inject metadata failure; once suppresses a false typo warning for a fully qualified fixture variable. strict and all other warning categories remain active, and the surrounding block restores warning settings.

### R11: ProhibitManyArgs

Deferred interface change: rename_op receives explicit config, operation, source, destination, result accumulator and diagnostic label. Existing callers use that order consistently. Replacing it with a new object/options hash is possible but adds an interface migration without a demonstrated argument-order bug.

### R12: ProhibitMultiplePackages

Intentional single-file distribution: NormalizeFiles contains reusable helpers and the short package main CLI entry point in the installed executable. Splitting them would change the manifest/install layout and deployment assumptions. The require guard lets tests load the helpers without scanning a tree.

## Individual retained findings

There are **43 severity-4 and 162 severity-3** retained findings. Every row
identifies one diagnostic by file, line, column and policy; duplicate locations
can describe distinct regular expressions. The disposition reference provides
the engineering justification, and the source excerpt makes the occurrence
reviewable. Locations describe this audited revision and must be regenerated
after subsequent source changes.

| ID | Severity | Location | Policy | Disposition | Source |
| --- | --- | --- | --- | --- | --- |
| PC001 | 3 | `perl/normalize-files.pl:139:1` | `ProhibitExcessComplexity` | Retained R6 | `sub setup_openbsd_sandbox {` |
| PC002 | 3 | `perl/normalize-files.pl:198:14` | `RequireCarping` | Retained R4 | `or die "unveil lock failed: $!";` |
| PC003 | 3 | `perl/normalize-files.pl:207:14` | `RequireCarping` | Retained R4 | `or die "pledge failed: $!"` |
| PC004 | 3 | `perl/normalize-files.pl:225:14` | `RequireExtendedFormatting` | Retained R2 | `$prog =~ s/\.(?:pl&#124;pm)\z//;` |
| PC005 | 4 | `perl/normalize-files.pl:235:21` | `RequireBriefOpen` | Retained R1 | `next unless open( $fh, '<:raw', $cand );` |
| PC006 | 3 | `perl/normalize-files.pl:239:18` | `RequireExtendedFormatting` | Retained R2 | `$line =~ s/\s+\z//;` |
| PC007 | 3 | `perl/normalize-files.pl:257:23` | `RequireExtendedFormatting` | Retained R2 | `@exts = split /;/, $pathext;` |
| PC008 | 3 | `perl/normalize-files.pl:306:18` | `RequireExtendedFormatting` | Retained R2 | `$copy =~ s/([\x00-\x1F\x7F])/sprintf( '\\x%02X', ord $1 )/ge;` |
| PC009 | 3 | `perl/normalize-files.pl:309:14` | `RequireExtendedFormatting` | Retained R2 | `$copy =~ s/([^\x20-\x7E])/sprintf( '\\x%02X', ord $1 )/ge;` |
| PC010 | 3 | `perl/normalize-files.pl:371:11` | `RequireExtendedFormatting` | Retained R2 | `$d =~ s/\p{Mn}+//g;` |
| PC011 | 3 | `perl/normalize-files.pl:390:11` | `RequireExtendedFormatting` | Retained R2 | `$e =~ s/[^a-z0-9]+//g;` |
| PC012 | 3 | `perl/normalize-files.pl:400:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/\s+/-/g;` |
| PC013 | 3 | `perl/normalize-files.pl:401:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/[^a-z0-9._-]+/-/g;` |
| PC014 | 3 | `perl/normalize-files.pl:402:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/-{2,}/-/g;` |
| PC015 | 3 | `perl/normalize-files.pl:403:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/\.{2,}/./g;` |
| PC016 | 3 | `perl/normalize-files.pl:404:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/^-+//;` |
| PC017 | 3 | `perl/normalize-files.pl:405:11` | `RequireExtendedFormatting` | Retained R2 | `$t =~ s/-+$//;` |
| PC018 | 3 | `perl/normalize-files.pl:414:14` | `RequireExtendedFormatting` | Retained R2 | `$base =~ s/\..*$//s;` |
| PC019 | 3 | `perl/normalize-files.pl:455:16` | `RequireExtendedFormatting` | Retained R2 | `$result =~ s/\.{2,}/./g;` |
| PC020 | 3 | `perl/normalize-files.pl:456:16` | `RequireExtendedFormatting` | Retained R2 | `$result =~ s/[.\-]+$//;` |
| PC021 | 3 | `perl/normalize-files.pl:489:34` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $rel_char =~ /$re/;` |
| PC022 | 3 | `perl/normalize-files.pl:580:31` | `RequireExtendedFormatting` | Retained R2 | `my $compiled = eval { qr/$re/ };` |
| PC023 | 3 | `perl/normalize-files.pl:733:1` | `ProhibitExcessComplexity` | Retained R6 | `sub scan_tree {` |
| PC024 | 3 | `perl/normalize-files.pl:757:31` | `RequireExtendedFormatting` | Retained R2 | `next if $cname =~ /^\.norm-(?:tmp&#124;bak)-/;` |
| PC025 | 3 | `perl/normalize-files.pl:817:1` | `ProhibitExcessComplexity` | Retained R6 | `sub plan_renames {` |
| PC026 | 3 | `perl/normalize-files.pl:922:9` | `RequireCarping` | Retained R4 | `die "cannot close temporary reservation in $dir: $close_error";` |
| PC027 | 3 | `perl/normalize-files.pl:943:1` | `ProhibitManyArgs` | Retained R11 | `sub rename_op {` |
| PC028 | 4 | `perl/normalize-files.pl:1092:19` | `RequireBriefOpen` | Retained R1 | `return unless open( $fh, '<:raw', $path );` |
| PC029 | 3 | `perl/normalize-files.pl:1109:23` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $b =~ /^\xEF\xBB\xBF/;` |
| PC030 | 3 | `perl/normalize-files.pl:1110:23` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $b =~ /^\xFF\xFE/ &#124;&#124; $b =~ /^\xFE\xFF/;` |
| PC031 | 3 | `perl/normalize-files.pl:1110:44` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $b =~ /^\xFF\xFE/ &#124;&#124; $b =~ /^\xFE\xFF/;` |
| PC032 | 3 | `perl/normalize-files.pl:1114:23` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $b =~ /^\x00\x00\xFE\xFF/ &#124;&#124; $b =~ /^\xFF\xFE\x00\x00/;` |
| PC033 | 3 | `perl/normalize-files.pl:1114:52` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $b =~ /^\x00\x00\xFE\xFF/ &#124;&#124; $b =~ /^\xFF\xFE\x00\x00/;` |
| PC034 | 3 | `perl/normalize-files.pl:1115:23` | `RequireExtendedFormatting` | Retained R2 | `return 0 if $b =~ /\x00/;` |
| PC035 | 3 | `perl/normalize-files.pl:1118:27` | `RequireExtendedFormatting` | Retained R2 | `my $ctrl = () = $b =~ /[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]/g;` |
| PC036 | 3 | `perl/normalize-files.pl:1147:20` | `RequireExtendedFormatting` | Retained R2 | `if ( $bytes =~ /[\x80-\x9F]/ )         { return ( 'ambiguous-cp1252', 0 ) }` |
| PC037 | 3 | `perl/normalize-files.pl:1186:5` | `RequireCarping` | Retained R4 | `die "internal error: encode_result unknown encoding '$enc'";` |
| PC038 | 3 | `perl/normalize-files.pl:1197:32` | `RequireExtendedFormatting` | Retained R2 | `my $crlf   = () = $text =~ /\r\n/g;` |
| PC039 | 3 | `perl/normalize-files.pl:1198:32` | `RequireExtendedFormatting` | Retained R2 | `my $lf     = () = $text =~ /(?<!\r)\n/g;` |
| PC040 | 3 | `perl/normalize-files.pl:1199:32` | `RequireExtendedFormatting` | Retained R2 | `my $cr     = () = $text =~ /\r(?!\n)/g;` |
| PC041 | 3 | `perl/normalize-files.pl:1202:5` | `ProhibitCascadingIfElse` | Retained R8 | `if    ( $kinds == 0 ) { $type = 'none' }` |
| PC042 | 3 | `perl/normalize-files.pl:1215:11` | `RequireExtendedFormatting` | Retained R2 | `$n =~ s/\r\n/\n/g;` |
| PC043 | 3 | `perl/normalize-files.pl:1216:11` | `RequireExtendedFormatting` | Retained R2 | `$n =~ s/\r/\n/g;` |
| PC044 | 3 | `perl/normalize-files.pl:1217:41` | `RequireExtendedFormatting` | Retained R2 | `if    ( $target eq 'crlf' ) { $n =~ s/\n/\r\n/g }` |
| PC045 | 3 | `perl/normalize-files.pl:1218:41` | `RequireExtendedFormatting` | Retained R2 | `elsif ( $target eq 'cr' )   { $n =~ s/\n/\r/g }` |
| PC046 | 3 | `perl/normalize-files.pl:1225:45` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $target eq 'lf' && $text !~ /\r/;` |
| PC047 | 3 | `perl/normalize-files.pl:1227:40` | `RequireExtendedFormatting` | Retained R2 | `if $target eq 'crlf' && $text !~ /(?<!\r)\n/ && $text !~ /\r(?!\n)/;` |
| PC048 | 3 | `perl/normalize-files.pl:1227:64` | `RequireExtendedFormatting` | Retained R2 | `if $target eq 'crlf' && $text !~ /(?<!\r)\n/ && $text !~ /\r(?!\n)/;` |
| PC049 | 3 | `perl/normalize-files.pl:1228:45` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $target eq 'cr' && $text !~ /\n/ && $text !~ /\r\n/;` |
| PC050 | 3 | `perl/normalize-files.pl:1228:62` | `RequireExtendedFormatting` | Retained R2 | `return 1 if $target eq 'cr' && $text !~ /\n/ && $text !~ /\r\n/;` |
| PC051 | 3 | `perl/normalize-files.pl:1262:9` | `ProhibitCascadingIfElse` | Retained R8 | `if ( $c eq '*' ) {` |
| PC052 | 3 | `perl/normalize-files.pl:1279:25` | `RequireExtendedFormatting` | Retained R2 | `$cls =~ s/^!/^/;` |
| PC053 | 3 | `perl/normalize-files.pl:1289:34` | `RequireExtendedFormatting` | Retained R2 | `my @opts = split /,/, $alt, -1;` |
| PC054 | 3 | `perl/normalize-files.pl:1310:28` | `RequireExtendedFormatting` | Retained R2 | `my $anchored = ( $p =~ m{/} ) ? 1 : 0;` |
| PC055 | 3 | `perl/normalize-files.pl:1311:11` | `RequireExtendedFormatting` | Retained R2 | `$p =~ s{^/}{};` |
| PC056 | 3 | `perl/normalize-files.pl:1317:37` | `RequireExtendedFormatting` | Retained R2 | `if   ($anchored) { $path =~ m{^$re$}       ? 1 : 0 }` |
| PC057 | 3 | `perl/normalize-files.pl:1318:37` | `RequireExtendedFormatting` | Retained R2 | `else             { $path =~ m{(?:^&#124;/)$re$} ? 1 : 0 }` |
| PC058 | 3 | `perl/normalize-files.pl:1330:11` | `RequireExtendedFormatting` | Retained R2 | `$r =~ s{\\}{/}g;` |
| PC059 | 4 | `perl/normalize-files.pl:1341:27` | `RequireBriefOpen` | Retained R1 | `return \@rules unless open( $fh, '<:raw', $file );` |
| PC060 | 3 | `perl/normalize-files.pl:1345:18` | `RequireExtendedFormatting` | Retained R2 | `$line =~ s/\r?\n\z//;` |
| PC061 | 3 | `perl/normalize-files.pl:1346:26` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*\z/;` |
| PC062 | 3 | `perl/normalize-files.pl:1347:26` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*#/;` |
| PC063 | 3 | `perl/normalize-files.pl:1356:27` | `RequireExtendedFormatting` | Retained R2 | `if    ( $a =~ /^-(.+)\z/ )      { $unset{$1}     = 1 }` |
| PC064 | 3 | `perl/normalize-files.pl:1357:27` | `RequireExtendedFormatting` | Retained R2 | `elsif ( $a =~ /^(.+?)=(.+)\z/ ) { $val{$1}       = $2 }` |
| PC065 | 3 | `perl/normalize-files.pl:1379:13` | `RequireExtendedFormatting` | Retained R2 | `$rel =~ s{\\}{/}g;` |
| PC066 | 3 | `perl/normalize-files.pl:1383:29` | `RequireExtendedFormatting` | Retained R2 | `return @dirs if $rel =~ m{^\.\.(?:/&#124;$)};` |
| PC067 | 3 | `perl/normalize-files.pl:1384:26` | `RequireExtendedFormatting` | Retained R2 | `for my $part ( split m{/}, $rel ) {` |
| PC068 | 4 | `perl/normalize-files.pl:1438:21` | `RequireBriefOpen` | Retained R1 | `next unless open( $fh, '<:raw', $ec );` |
| PC069 | 3 | `perl/normalize-files.pl:1443:22` | `RequireExtendedFormatting` | Retained R2 | `$line =~ s/\r?\n\z//;` |
| PC070 | 3 | `perl/normalize-files.pl:1444:22` | `RequireExtendedFormatting` | Retained R2 | `$line =~ s/^\s+//;` |
| PC071 | 3 | `perl/normalize-files.pl:1445:22` | `RequireExtendedFormatting` | Retained R2 | `$line =~ s/\s+\z//;` |
| PC072 | 3 | `perl/normalize-files.pl:1447:30` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^[#;]/;` |
| PC073 | 3 | `perl/normalize-files.pl:1448:27` | `RequireExtendedFormatting` | Retained R2 | `if ( $line =~ /^\[(.+)\]\z/ ) {` |
| PC074 | 3 | `perl/normalize-files.pl:1454:27` | `RequireExtendedFormatting` | Retained R2 | `if ( $line =~ /^([^=]+?)\s*=\s*(.+)\z/ ) {` |
| PC075 | 4 | `perl/normalize-files.pl:1508:8` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = $install_error;` |
| PC076 | 3 | `perl/normalize-files.pl:1543:31` | `RequireCarping` | Retained R4 | `print {$fh} $bytes or die "write failed: $!";` |
| PC077 | 3 | `perl/normalize-files.pl:1544:31` | `RequireCarping` | Retained R4 | `close $fh          or die "close failed: $!";` |
| PC078 | 4 | `perl/normalize-files.pl:1625:12` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = $read_error if !defined $count;` |
| PC079 | 4 | `perl/normalize-files.pl:1639:12` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = EFBIG;` |
| PC080 | 4 | `perl/normalize-files.pl:1646:12` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = EAGAIN;` |
| PC081 | 4 | `perl/normalize-files.pl:1659:16` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = $read_error;` |
| PC082 | 4 | `perl/normalize-files.pl:1666:16` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = EFBIG;` |
| PC083 | 4 | `perl/normalize-files.pl:1676:12` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = EAGAIN;` |
| PC084 | 3 | `perl/normalize-files.pl:1687:1` | `ProhibitExcessComplexity` | Retained R6 | `sub process_content {` |
| PC085 | 3 | `perl/normalize-files.pl:1811:23` | `RequireExtendedFormatting` | Retained R2 | `if ( $text =~ /\x00/ ) {` |
| PC086 | 3 | `perl/normalize-files.pl:1826:51` | `RequireExtendedFormatting` | Retained R2 | `( $enc eq 'assumed' && $canon_assume =~ /^utf-?8$/ );` |
| PC087 | 4 | `perl/normalize-files.pl:1957:1` | `RequireFinalReturn` | Retained R3 | `sub repo_root_for {` |
| PC088 | 3 | `perl/normalize-files.pl:1999:30` | `RequireExtendedFormatting` | Retained R2 | `for my $line ( split /\n/, safe_decode($out) ) {` |
| PC089 | 3 | `perl/normalize-files.pl:2017:49` | `RequireExtendedFormatting` | Retained R2 | `emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode( $st // '' );` |
| PC090 | 3 | `perl/normalize-files.pl:2022:53` | `RequireExtendedFormatting` | Retained R2 | `emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode($chk);` |
| PC091 | 3 | `perl/normalize-files.pl:2031:53` | `RequireExtendedFormatting` | Retained R2 | `emit( '  ' . $_ ) for grep { length } split /\n/, safe_decode($stat);` |
| PC092 | 3 | `perl/normalize-files.pl:2071:1` | `ProhibitExcessComplexity` | Retained R6 | `sub run {` |
| PC093 | 4 | `perl/normalize-files.pl:2177:1` | `ProhibitMultiplePackages` | Retained R12 | `package main;` |
| PC094 | 3 | `perl/ssh-menu.pl:82:14` | `RequireExtendedFormatting` | Retained R2 | `$dirs =~ s{[\\/]\z}{} if length $dirs;` |
| PC095 | 3 | `perl/ssh-menu.pl:97:25` | `RequireExtendedFormatting` | Retained R2 | `for my $dir ( split /\Q$sep\E/, $ENV{PATH} &#124;&#124; '' ) {` |
| PC096 | 4 | `perl/ssh-menu.pl:113:1` | `RequireFinalReturn` | Retained R3 | `sub ensure_known_hosts_exists {` |
| PC097 | 4 | `perl/ssh-menu.pl:121:1` | `RequireFinalReturn` | Retained R3 | `sub setup_ssh_askpass {` |
| PC098 | 4 | `perl/ssh-menu.pl:125:35` | `RequireLocalizedPunctuationVars` | Retained R5 | `$ENV{SSH_ASKPASS}         = $ksshaskpass;` |
| PC099 | 4 | `perl/ssh-menu.pl:126:35` | `RequireLocalizedPunctuationVars` | Retained R5 | `$ENV{SSH_ASKPASS_REQUIRE} = 'prefer';` |
| PC100 | 3 | `perl/ssh-menu.pl:133:1` | `ProhibitExcessComplexity` | Retained R6 | `sub setup_openbsd_sandbox {` |
| PC101 | 4 | `perl/ssh-menu.pl:133:1` | `RequireFinalReturn` | Retained R3 | `sub setup_openbsd_sandbox {` |
| PC102 | 3 | `perl/ssh-menu.pl:138:13` | `RequireExtendedFormatting` | Retained R2 | `split /:/, ( $ENV{PATH} &#124;&#124; '' );` |
| PC103 | 3 | `perl/ssh-menu.pl:189:14` | `RequireCarping` | Retained R4 | `or die "unveil lock failed: $!";` |
| PC104 | 4 | `perl/ssh-menu.pl:232:16` | `RequireLocalizedPunctuationVars` | Retained R5 | `$! = $install_error;` |
| PC105 | 4 | `perl/ssh-menu.pl:243:1` | `RequireFinalReturn` | Retained R3 | `sub write_state_file {` |
| PC106 | 4 | `perl/ssh-menu.pl:317:1` | `RequireFinalReturn` | Retained R3 | `sub load_freq_file {` |
| PC107 | 3 | `perl/ssh-menu.pl:323:30` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*$/;` |
| PC108 | 3 | `perl/ssh-menu.pl:324:35` | `RequireExtendedFormatting` | Retained R2 | `my ( $k, $v ) = split /\s+/, $line, 2;` |
| PC109 | 3 | `perl/ssh-menu.pl:326:31` | `RequireExtendedFormatting` | Retained R2 | `next unless $v =~ /^\d+$/;` |
| PC110 | 4 | `perl/ssh-menu.pl:337:1` | `RequireFinalReturn` | Retained R3 | `sub load_alias_file {` |
| PC111 | 3 | `perl/ssh-menu.pl:343:30` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*$/;` |
| PC112 | 3 | `perl/ssh-menu.pl:344:35` | `RequireExtendedFormatting` | Retained R2 | `my ( $k, $v ) = split /\s+/, $line, 2;` |
| PC113 | 4 | `perl/ssh-menu.pl:356:1` | `RequireFinalReturn` | Retained R3 | `sub load_last_user_file {` |
| PC114 | 3 | `perl/ssh-menu.pl:362:30` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*$/;` |
| PC115 | 3 | `perl/ssh-menu.pl:363:35` | `RequireExtendedFormatting` | Retained R2 | `my ( $k, $v ) = split /\s+/, $line, 2;` |
| PC116 | 4 | `perl/ssh-menu.pl:421:1` | `RequireFinalReturn` | Retained R3 | `sub parse_known_hosts {` |
| PC117 | 4 | `perl/ssh-menu.pl:422:5` | `RequireBriefOpen` | Retained R1 | `open my $fh, '<', $known_hosts` |
| PC118 | 3 | `perl/ssh-menu.pl:427:26` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*$/;` |
| PC119 | 3 | `perl/ssh-menu.pl:428:26` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*#/;` |
| PC120 | 3 | `perl/ssh-menu.pl:430:23` | `RequireExtendedFormatting` | Retained R2 | `if ( $line =~ /^\s*\&#124;/ ) {` |
| PC121 | 3 | `perl/ssh-menu.pl:439:26` | `RequireExtendedFormatting` | Retained R2 | `next if $line =~ /^\s*@/;` |
| PC122 | 3 | `perl/ssh-menu.pl:445:47` | `RequireExtendedFormatting` | Retained R2 | `next unless defined $rest && $rest =~ /\S/;` |
| PC123 | 3 | `perl/ssh-menu.pl:448:51` | `RequireExtendedFormatting` | Retained R2 | `grep { defined $_ && length $_ && $_ !~ /^\s*#/ && $_ !~ /^\s*\&#124;/ }` |
| PC124 | 3 | `perl/ssh-menu.pl:448:68` | `RequireExtendedFormatting` | Retained R2 | `grep { defined $_ && length $_ && $_ !~ /^\s*#/ && $_ !~ /^\s*\&#124;/ }` |
| PC125 | 3 | `perl/ssh-menu.pl:449:17` | `RequireExtendedFormatting` | Retained R2 | `split /,/, $field;` |
| PC126 | 3 | `perl/ssh-menu.pl:456:29` | `RequireExtendedFormatting` | Retained R2 | `next if $primary =~ /^!/ &#124;&#124; $primary =~ /[*?]/;` |
| PC127 | 3 | `perl/ssh-menu.pl:456:49` | `RequireExtendedFormatting` | Retained R2 | `next if $primary =~ /^!/ &#124;&#124; $primary =~ /[*?]/;` |
| PC128 | 3 | `perl/ssh-menu.pl:461:23` | `RequireExtendedFormatting` | Retained R2 | `if ( $host =~ /^\[(.+)\]:(\d+)$/ ) {` |
| PC129 | 4 | `perl/ssh-menu.pl:484:1` | `RequireFinalReturn` | Retained R3 | `sub prune_stale_data {` |
| PC130 | 4 | `perl/ssh-menu.pl:521:1` | `RequireFinalReturn` | Retained R3 | `sub ensure_entries_present {` |
| PC131 | 4 | `perl/ssh-menu.pl:538:1` | `RequireFinalReturn` | Retained R3 | `sub sort_entries {` |
| PC132 | 4 | `perl/ssh-menu.pl:567:1` | `RequireFinalReturn` | Retained R3 | `sub add_alias_menu {` |
| PC133 | 4 | `perl/ssh-menu.pl:582:21` | `ProhibitExplicitStdin` | Retained R7 | `my $input = <STDIN>;` |
| PC134 | 3 | `perl/ssh-menu.pl:586:29` | `RequireExtendedFormatting` | Retained R2 | `return if $input =~ /^[qQ]$/;` |
| PC135 | 3 | `perl/ssh-menu.pl:587:29` | `RequireExtendedFormatting` | Retained R2 | `next   if $input !~ /^\d+$/;` |
| PC136 | 4 | `perl/ssh-menu.pl:602:25` | `ProhibitExplicitStdin` | Retained R7 | `my $alias_val = <STDIN> // '';` |
| PC137 | 3 | `perl/ssh-menu.pl:604:33` | `RequireExtendedFormatting` | Retained R2 | `return if $alias_val !~ /\S/;` |
| PC138 | 3 | `perl/ssh-menu.pl:616:1` | `ProhibitExcessComplexity` | Retained R6 | `sub remove_known_host_entry {` |
| PC139 | 4 | `perl/ssh-menu.pl:627:11` | `RequireBriefOpen` | Retained R1 | `if ( !open $fh, '<', $known_hosts ) {` |
| PC140 | 3 | `perl/ssh-menu.pl:633:31` | `RequireExtendedFormatting` | Retained R2 | `my ($eol) = $probe =~ /(\r?\n)\z/;` |
| PC141 | 3 | `perl/ssh-menu.pl:634:19` | `RequireExtendedFormatting` | Retained R2 | `$probe =~ s/\r?\n\z//;` |
| PC142 | 3 | `perl/ssh-menu.pl:637:24` | `RequireExtendedFormatting` | Retained R2 | `if ( $probe !~ /^\s*(?:#&#124;\&#124;&#124;@)/ && $probe =~ /\S/ ) {` |
| PC143 | 3 | `perl/ssh-menu.pl:637:54` | `RequireExtendedFormatting` | Retained R2 | `if ( $probe !~ /^\s*(?:#&#124;\&#124;&#124;@)/ && $probe =~ /\S/ ) {` |
| PC144 | 3 | `perl/ssh-menu.pl:641:38` | `RequireExtendedFormatting` | Retained R2 | `for my $cand ( split /,/, $field, -1 ) {` |
| PC145 | 3 | `perl/ssh-menu.pl:643:32` | `RequireExtendedFormatting` | Retained R2 | `if ( $h =~ /^\[(.+)\]:(\d+)$/ ) { $h = $1; $p = $2; }` |
| PC146 | 4 | `perl/ssh-menu.pl:706:1` | `RequireFinalReturn` | Retained R3 | `sub manage_known_hosts_menu {` |
| PC147 | 4 | `perl/ssh-menu.pl:721:21` | `ProhibitExplicitStdin` | Retained R7 | `my $input = <STDIN>;` |
| PC148 | 3 | `perl/ssh-menu.pl:725:29` | `RequireExtendedFormatting` | Retained R2 | `return if $input =~ /^[qQ]$/;` |
| PC149 | 3 | `perl/ssh-menu.pl:726:29` | `RequireExtendedFormatting` | Retained R2 | `next   if $input !~ /^\d+$/;` |
| PC150 | 4 | `perl/ssh-menu.pl:738:23` | `ProhibitExplicitStdin` | Retained R7 | `my $confirm = <STDIN>;` |
| PC151 | 3 | `perl/ssh-menu.pl:741:31` | `RequireExtendedFormatting` | Retained R2 | `return if $confirm !~ /^[yY]/;` |
| PC152 | 4 | `perl/ssh-menu.pl:778:21` | `ProhibitExplicitStdin` | Retained R7 | `my $input = <STDIN>;` |
| PC153 | 3 | `perl/ssh-menu.pl:781:24` | `RequireExtendedFormatting` | Retained R2 | `if ( $input =~ /^[qQ]$/ ) {` |
| PC154 | 3 | `perl/ssh-menu.pl:786:27` | `RequireExtendedFormatting` | Retained R2 | `next if $input !~ /^\d+$/;` |
| PC155 | 4 | `perl/ssh-menu.pl:844:20` | `ProhibitExplicitStdin` | Retained R7 | `my $ssh_user = <STDIN>;` |
| PC156 | 3 | `perl/ssh-menu.pl:847:18` | `RequireExtendedFormatting` | Retained R2 | `$ssh_user =~ s/^\s+&#124;\s+$//g;` |
| PC157 | 3 | `perl/ssh-menu.pl:872:45` | `RequireExtendedFormatting` | Retained R2 | `if ( !defined $ssh_user &#124;&#124; $ssh_user !~ /\A[A-Za-z0-9._-]+\z/ ) {` |
| PC158 | 4 | `perl/ssh-menu.pl:891:1` | `RequireFinalReturn` | Retained R3 | `sub update_frequency {` |
| PC159 | 3 | `tests-format/test-normalize-files.pl:1:1` | `ProhibitExcessMainComplexity` | Retained R9 | `#!/usr/bin/env perl` |
| PC160 | 3 | `tests-format/test-normalize-files.pl:53:36` | `RequireCarping` | Retained R4 | `open my $fh, '>:raw', $path or die "cannot write $path: $!";` |
| PC161 | 3 | `tests-format/test-normalize-files.pl:64:47` | `RequireCarping` | Retained R4 | `open my $fh, '-&#124;', $^X, $SCRIPT, @args or die "cannot run script: $!";` |
| PC162 | 3 | `tests-format/test-normalize-files.pl:153:24` | `RequireExtendedFormatting` | Retained R2 | `unlike( $once, qr{[/\\]}, "no path separator in <$once>" );` |
| PC163 | 3 | `tests-format/test-normalize-files.pl:501:21` | `RequireExtendedFormatting` | Retained R2 | `unlike( $bytes, qr/\r/, 'report uses LF only' );` |
| PC164 | 3 | `tests-format/test-normalize-files.pl:590:29` | `RequireCarping` | Retained R4 | `opendir my $dh, $tmp or die "opendir $tmp: $!";` |
| PC165 | 3 | `tests-format/test-normalize-files.pl:591:28` | `RequireExtendedFormatting` | Retained R2 | `my @leftovers = grep { m{^\.norm-} } readdir $dh;` |
| PC166 | 3 | `tests-format/test-normalize-files.pl:691:17` | `RequireExtendedFormatting` | Retained R2 | `like( $out, qr/^normalize-files \S+/, 'prints name and version' );` |
| PC167 | 3 | `tests-format/test-normalize-files.pl:694:41` | `RequireCarping` | Retained R4 | `open my $fh, '<:raw', $vfile or die "open $vfile: $!";` |
| PC168 | 3 | `tests-format/test-normalize-files.pl:697:15` | `RequireExtendedFormatting` | Retained R2 | `$v =~ s/\s+\z//;` |
| PC169 | 3 | `tests-format/test-normalize-files.pl:698:21` | `RequireExtendedFormatting` | Retained R2 | `like( $out, qr/\Q$v\E/, 'matches the VERSION file' );` |
| PC170 | 4 | `tests-format/test-normalize-files.pl:768:9` | `ProhibitNoWarnings` | Retained R10 | `no warnings qw(redefine once);` |
| PC171 | 3 | `tests-format/test-normalize-files.pl:779:29` | `RequireCarping` | Retained R4 | `opendir my $dh, $tmp or die "opendir $tmp: $!";` |
| PC172 | 3 | `tests-format/test-normalize-files.pl:780:28` | `RequireExtendedFormatting` | Retained R2 | `my @temporary = grep { /^\.norm-tmp-/ } readdir $dh;` |
| PC173 | 4 | `tests-format/test-normalize-files.pl:787:5` | `ProhibitNoWarnings` | Retained R10 | `no warnings 'once';` |
| PC174 | 3 | `tests-format/test-normalize-files.pl:836:14` | `RequireCarping` | Retained R4 | `or die "cannot run recovery driver: $!";` |
| PC175 | 3 | `tests-format/test-normalize-files.pl:842:37` | `RequireCarping` | Retained R4 | `opendir my $dh, $dir or die "opendir $dir: $!";` |
| PC176 | 3 | `tests-format/test-normalize-files.pl:843:33` | `RequireExtendedFormatting` | Retained R2 | `my @copies = grep { /^\.norm-bak-/ } readdir $dh;` |
| PC177 | 3 | `tests-format/test-normalize-files.pl:862:26` | `RequireCarping` | Retained R4 | `chmod 0640, $path or die "chmod $path: $!";` |
| PC178 | 3 | `tests-format/test-normalize-files.pl:864:10` | `RequireCarping` | Retained R4 | `or die "utime $path: $!";` |
| PC179 | 3 | `tests-format/test-ssh-menu.pl:1:1` | `ProhibitExcessMainComplexity` | Retained R9 | `#!/usr/bin/env perl` |
| PC180 | 3 | `tests-format/test-ssh-menu.pl:47:23` | `RequireExtendedFormatting` | Retained R2 | `for my $p ( split /\Q$sep\E/, ( $ENV{PATH} &#124;&#124; '' ) ) {` |
| PC181 | 3 | `tests-format/test-ssh-menu.pl:93:23` | `RequireCarping` | Retained R4 | `seek $in, 0, 0 or die "seek input: $!";` |
| PC182 | 3 | `tests-format/test-ssh-menu.pl:102:24` | `RequireCarping` | Retained R4 | `seek $out, 0, 0 or die "seek output: $!";` |
| PC183 | 3 | `tests-format/test-ssh-menu.pl:113:14` | `RequireExtendedFormatting` | Retained R2 | `if ( $out !~ /host1\.example\.com/ ) {` |
| PC184 | 3 | `tests-format/test-ssh-menu.pl:116:14` | `RequireExtendedFormatting` | Retained R2 | `if ( $out !~ /host2\.example\.com/ ) {` |
| PC185 | 3 | `tests-format/test-ssh-menu.pl:119:14` | `RequireExtendedFormatting` | Retained R2 | `if ( $out =~ /cert-authority/ ) {` |
| PC186 | 3 | `tests-format/test-ssh-menu.pl:122:14` | `RequireExtendedFormatting` | Retained R2 | `if ( $out =~ /host3\.example\.com/ ) {` |
| PC187 | 4 | `tests-format/test-ssh-menu.pl:132:5` | `RequireBriefOpen` | Retained R1 | `open my $fh, '<', $known_hosts or fail_test("cannot read $known_hosts");` |
| PC188 | 3 | `tests-format/test-ssh-menu.pl:139:19` | `RequireExtendedFormatting` | Retained R2 | `if ( $kh_after =~ /^host1\.example\.com\b/m ) {` |
| PC189 | 3 | `tests-format/test-ssh-menu.pl:142:19` | `RequireExtendedFormatting` | Retained R2 | `if ( $kh_after !~ /^host2\.example\.com\b/m ) {` |
| PC190 | 3 | `tests-format/test-ssh-menu.pl:145:19` | `RequireExtendedFormatting` | Retained R2 | `if ( $kh_after !~ /\@cert-authority/ &#124;&#124; $kh_after !~ /\@revoked/ ) {` |
| PC191 | 3 | `tests-format/test-ssh-menu.pl:145:54` | `RequireExtendedFormatting` | Retained R2 | `if ( $kh_after !~ /\@cert-authority/ &#124;&#124; $kh_after !~ /\@revoked/ ) {` |
| PC192 | 3 | `tests-format/test-ssh-menu.pl:148:19` | `RequireExtendedFormatting` | Retained R2 | `if ( $kh_after !~ /^\&#124;1\&#124;hash-of-something\&#124;key/m ) {` |
| PC193 | 4 | `tests-format/test-ssh-menu.pl:175:13` | `RequireBriefOpen` | Retained R1 | `open my $fh, '<', $link_target` |
| PC194 | 3 | `tests-format/test-ssh-menu.pl:180:31` | `RequireExtendedFormatting` | Retained R2 | `if ( $target_after =~ /^linkhost\.example\.com\b/m ) {` |
| PC195 | 3 | `tests-format/test-ssh-menu.pl:198:37` | `RequireCarping` | Retained R4 | `open my $driver_fh, '>', $driver or die "write $driver: $!";` |
| PC196 | 3 | `tests-format/test-ssh-menu.pl:212:21` | `RequireExtendedFormatting` | Retained R2 | `&#124;&#124; $config !~ /^hostname example\.com\r?$/m` |
| PC197 | 3 | `tests-format/test-ssh-menu.pl:213:21` | `RequireExtendedFormatting` | Retained R2 | `&#124;&#124; $config !~ /^user testuser\r?$/m` |
| PC198 | 3 | `tests-format/test-ssh-menu.pl:214:21` | `RequireExtendedFormatting` | Retained R2 | `&#124;&#124; $config !~ /^port $expected_port\r?$/m;` |
| PC199 | 4 | `tests-format/test-ssh-menu.pl:220:1` | `RequireBriefOpen` | Retained R1 | `open my $recovery_fh, '>', $recovery_driver` |
| PC200 | 3 | `tests-format/test-ssh-menu.pl:221:6` | `RequireCarping` | Retained R4 | `or die "write $recovery_driver: $!";` |
| PC201 | 3 | `tests-format/test-ssh-menu.pl:248:23` | `RequireCarping` | Retained R4 | `close $recovery_fh or die "close $recovery_driver: $!";` |
| PC202 | 3 | `tests-format/test-ssh-menu.pl:255:39` | `RequireCarping` | Retained R4 | `open my $fh, '>', $fixture or die "write $fixture: $!";` |
| PC203 | 3 | `tests-format/test-ssh-menu.pl:257:22` | `RequireCarping` | Retained R4 | `close $fh or die "close $fixture: $!";` |
| PC204 | 3 | `tests-format/test-ssh-menu.pl:266:29` | `RequireExtendedFormatting` | Retained R2 | `unless $output =~ /recovery copy:/;` |
| PC205 | 3 | `tests-format/test-ssh-menu.pl:272:36` | `RequireCarping` | Retained R4 | `open my $fh, '<', $path or die "read restored $path: $!";` |
