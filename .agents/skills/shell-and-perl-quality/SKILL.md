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
   - `perl/` and Perl tests: Perl 5.10.1+, core modules.
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
- In `openbsd/`, use `typeset` inside functions and avoid `local`, `declare`,
  `readarray`, `mapfile`, `shopt`, here-strings, process substitution, and
  `$'...'`. The project validator rejects them.
- In `tests-format/`, stay POSIX: no arrays, `[[ ]]`, `local`, or `pipefail`.
- Sourced `shell/` helpers must not assume they are executed; avoid `exit`
  and use `return` where appropriate.

### Perl-specific checks

- `use strict; use warnings;` in every file.
- Stay on core modules and Perl 5.10.1 syntax. Declare a minimum version in
  new programs.
- Use `Getopt::Long` for options and `Pod::Usage` for help when the script has
  a POD section.
- Read and write bytes deliberately (`binmode`/`:raw`). Use a temporary file
  in the same directory and `rename` for atomic replacement.
- Never follow symlinks implicitly unless the option says so. Use `lstat`
  when inspecting links.
- Keep POD valid: add `=encoding UTF-8` before non-ASCII text and run
  `podchecker` when editing documentation.

## Validations

Run these on each touched file, from the repository root:

```sh
shfmt -l -s PATH
shellcheck -x PATH
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

`validate-shell.sh` and `validate-perl.sh` rewrite files when the formatters
are installed. Review `git diff` afterwards. Regression tests create their own
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
`python3 scripts/validate-agent-knowledge.py --scope worktree .`). The automated check
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
