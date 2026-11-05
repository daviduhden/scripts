---
name: shell-and-perl-quality
description: >-
  Edit or review shell and Perl code in this repository for portability,
  quoting, formatting, and lint quality. Use for .sh, .bash, .ksh, .pl, .pm,
  and .t changes, shellcheck or Perl::Critic findings, or formatter failures.
---

# Shell and Perl quality

## When to use

- Editing any shell script, sourced Bash helper, validator, or regression test.
- Editing `perl/*.pl` or `tests-format/test-*.pl`.
- Fixing `shfmt`, `shellcheck`, `perltidy`, or `Perl::Critic` findings.
- Reviewing quoting, temporary files, pipelines, or symlink handling.

## Procedure

1. Identify the interpreter from the shebang and directory. Do not change it
   casually:
   - `debian/` and `secureblue/`: Bash.
   - `openbsd/`: OpenBSD base `ksh`.
   - `shell/`: sourced by Bash, no shebang.
   - `tests-format/*.sh`: POSIX `sh`.
   - `perl/` and Perl tests: Perl 5.10.1+, core modules; Windows-only APIs
     may use modules bundled with the supported Perl distribution when the
     Windows installer checks for them.
2. Match the file's existing style. Shell uses tabs and `shfmt -s`. Perl uses
   4-space indentation and an 80-column limit.
3. Keep error handling explicit. Bash scripts use `set -euo pipefail` except
   where the script is interactive by design. ksh scripts use `set -eu` and
   guard optional options.
4. Quote every expansion used as a path or argument. Use `--` before operands
   that may start with `-`.

### Shell-specific checks

- Use `mktemp` with a template ending in `XXXXXX` in OpenBSD code and in
  portable scripts. OpenBSD `mktemp` requires a template.
- Install an `EXIT` trap for temporary directories and files.
- Under `pipefail`, do not pipe a producer into `head` or `grep -q` unless the
  SIGPIPE status is handled. Capture the output first or use `sed -n '1p'`.
- Do not use `eval`, `curl | sh`, or unquoted command strings. If `eval` is
  unavoidable, document why and keep the input bounded.
- Do not introduce Python code. Do not embed Perl source in shell or Perl
  scripts (`-c`, `-e`, `-n`, or a heredoc). Use native tools or a standalone
  helper program that the Makefile installs and the invoking script discovers
  relative to itself.
- Prefer focused helpers over a single omnibus helper when the helper has
  platform-specific dependencies.
- Use `mktemp` and `umask 077` for diagnostic logs and state files; never use
  `$$`-based predictable names under `/tmp`.
- In `openbsd/`, use `typeset` inside functions and avoid `local`, `declare`,
  `readarray`, `mapfile`, `shopt`, here-strings, process substitution, and
  `$'...'`. The project validator rejects them.
- Avoid `cmd1 && cmd2 || cmd3` for control flow; shellcheck reports SC2015 and
  strict CI fails. Use an explicit `if` block.
- When a test replaces `PATH` with a mock directory, link every external
  command the exercised validator calls. OpenBSD `ksh` has no `printf`
  builtin, so `printf` must be present as a command.
- In `tests-format/`, stay POSIX: no arrays, `[[ ]]`, `local`, or `pipefail`.
- Sourced `shell/` helpers must not assume they are executed; avoid `exit`
  and use `return` where appropriate.

### Perl-specific checks

- `use strict; use warnings;` in every file.
- Stay on core modules and Perl 5.10.1 syntax. Windows-specific bundled
  modules are acceptable when required for native Windows behavior and checked
  by the Windows installer. Declare a minimum version in new programs.
- When Windows Perl returns filesystem names as ANSI-code-page bytes, decode
  them with the active code page and encode native path components back before
  calling Perl's narrow filesystem APIs. Add coverage for a non-ASCII parent
  path when changing this handling.
- When adding explicit returns, preserve wrapper return values with
  `return helper(...)`; do not replace an implicit result with a bare return
  without checking callers. Test exception-producing `eval` blocks through
  an explicit success value rather than relying only on `$@`.
- Use `Getopt::Long` for options and `Pod::Usage` for help when the script has
  a POD section.
- Read and write bytes deliberately (`binmode`/`:raw`). Use a temporary file
  in the same directory and `rename` for atomic replacement. Check both the
  write and close results before replacing the original; a successful write
  call alone does not guarantee buffered data reached the file.
- For file-content replacements, capture identity before reading and carry it
  to the pre-replace check. Bound reads while reading, not only with a prior
  file-size check. A metadata or write/close failure must preserve the original.
  Snapshot checks detect common concurrent changes but do not provide a lock.
- Windows replacement recovery must use unique backup names, check restoration,
  and retain/report the original recovery copy when restoration fails. Simulated
  failure tests do not establish native Windows filesystem compatibility.
- When comparing file snapshots on Windows, ignore device, inode, and ctime
  fields that are not stable between `lstat` and `stat`; compare mode, size,
  and mtime instead. `read_all` skips its pre/post snapshot gate on Windows
  because handle metadata can differ even for an unchanged file.
- Resolve symlink targets with `readlink` and use `abs_path` only as a
  normalization fallback; `abs_path` can fail under an OpenBSD unveil sandbox.
  Unveil both the resolved `/tmp`-style path and the original spelling, since
  access may be checked against either.
- Windows test cases that require case-only renames, case-insensitive
  collisions, raw non-UTF-8 filenames, nested directory renames, or symlink
  creation must skip explicitly instead of relying on POSIX filesystem
  behavior.
- Review retained critic diagnostics in
  [the individual Perl audit](../../../docs/perl-audit.md); do not convert its
  justifications into global exclusions or broad `no critic` directives.
- Never follow symlinks implicitly unless the option says so. Use `lstat`
  when inspecting links.
- Keep POD valid: add `=encoding UTF-8` before non-ASCII text and run
  `podchecker` when editing documentation.

## Validations

Run these on each touched file, from the repository root:

```sh
shfmt -l -s PATH
shellcheck -x <ruta>
bash -n PATH
ksh -n PATH
sh -n PATH
perl -c PATH
perltidy -npro -ast -se -o /dev/null PATH
perlcritic --severity 5 PATH
```

Use only the syntax check that matches the interpreter. `perlcritic` may live
in `$PERL_LOCAL_LIB/bin` (default `~/perl5`); report it as skipped if absent.

Aggregate checks:

```sh
/bin/sh tests-format/validate-shell.sh .
/bin/sh tests-format/validate-perl.sh .
make test-regression
```

`validate-shell.sh` and `validate-perl.sh` default to read-only `--check`.
Use `--format` explicitly to apply formatting, then review `git diff`. Regression tests create their own
temporary trees and must not touch repository files.

## Common problems

- A pipeline fails with status 141 because `pipefail` is active and `head` or
  `grep -q` closes the pipe early.
- A bare `mktemp` works on Linux and fails on OpenBSD.
- The correctness validator now detects `<(...)` and `>(...)` and audits a
  narrow set of dangerous patterns inside here-documents. Review other
  generated scripts and here-document content manually.
- Quoted `mktemp` command substitutions can hide a missing template from
  simple checks; inspect them directly.
- `perltidy` without `-npro` honors a developer's global profile; validation
  uses `-npro` to stay reproducible.
- `podchecker` warns about non-ASCII POD text before `=encoding`.
- A sourced Bash helper with a shebang or executable bit will be
  misclassified by the permission policy.

## Maintenance & Continuous Learning

After using this skill to modify the repository, review this skill and the
applicable agent instructions as part of the task's final synchronization
step. Update this skill when procedures, tools, configuration, assumptions,
validation commands, or reusable knowledge have changed. Correct guidance
that proved inaccurate and keep examples and validation steps aligned with
the repository. Add only knowledge that will help future work; omit
execution-specific notes and cosmetic edits. Review affected specialized
agent instructions for consistency and run
`make check-agent-knowledge` (or
`perl scripts/validate-agent-knowledge.pl --scope worktree`). The automated check
covers structure and resolvable local references; semantic relevance still
requires review. Report the synchronization result in the final summary and
do not claim completion if it was skipped or failed.

## References

- [Root agent instructions](../../../AGENTS.md)
- [Validation tools](../../../tests-format/README.md)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
- [Shell validator](../../../tests-format/validate-shell.sh)
- [Perl validator](../../../tests-format/validate-perl.sh)
- [Perl programs](../../../perl/README.md)
