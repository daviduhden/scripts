---
name: script-tests-and-formatting
description: >-
  Change tests-format tooling, Makefile test targets, regression tests, or
  formatting policy in this repository. Use when adding or debugging a
  validator, running make test, fixing permissions, or checking whether a
  validation command rewrites files.
---

# Script tests and formatting

## When to use

- Editing `tests-format/*.sh`, `tests-format/test-*.pl`, or formatter configs.
- Adding, removing, or reordering a target in `Makefile`.
- Investigating a `make test` failure or a formatter rewrite.
- Deciding which checks are read-only and which modify the tree.
- Changing the permission policy or its tests.

## Understand the test split

`make check` runs agent-knowledge validation and contract tests, cache-free
Ruff formatting/lint checks, shell, Perl, Make, permission, correctness, and
manual-page checks. `make test` completes validation before isolated
regressions (including under parallel make): tooling/installers, permissions,
correctness, both Perl programs, delivery transactions, release verification,
and website synchronization filters.
Python test recipes set `PYTHONDONTWRITEBYTECODE=1`.

The four language validators default to `--check`; only `--format` rewrites
sources. `make format` invokes all four explicitly. Formatting drift exits 2
even if repaired, so inspect the diff and rerun checks. Safe `mktemp` logs
remain for inspection; transient failure, skip and format lists are cleaned.
Ruff check mode uses `--no-cache` and must not remove pre-existing caches.

Use `--strict` to fail when optional tools or Perl modules are missing.
Non-strict runs record `[SKIP]` diagnostics and counts rather than claiming
those checks passed. Make dialect/platform omissions are expected skips.
Ruff remains required whenever Python files exist. Make evaluation is opt-in
via `--make-dry-run`: even `-n` can execute commands while parsing untrusted
Makefiles. `perl -c` loads modules and executes compile-time blocks, so those
sources must also be trusted.

Windows batch/PowerShell checks run natively. Platform CI runs safe checks and
regressions on Linux, Windows, and an OpenBSD 7.8 VM; it must never execute
administrative scripts against a host. Pin Actions to verified upstream
commit hashes and document changes to runner dependencies separately from
runtime dependencies.

## Procedure

1. Run the read-only checks first:
   ```sh
   shfmt -l -s .
   shellcheck -x <ruta>
   perl -c PATH
   /bin/sh tests-format/fix-permissions.sh --check .
   /bin/sh tests-format/validate-manpages.sh .
   /bin/sh tests-format/validate-correctness.sh --target all .
   ```
   `fix-permissions.sh --check` skips Git-ignored artifacts and requires
   normalized modes; run `make fix-permissions` once in a clone created with a
   restrictive umask.
2. Run the aggregate suite:
   ```sh
   make test
   ```
3. Inspect `git diff`. If `make format` was explicitly used, review its
   rewrites and never commit unrelated formatting.
4. Installation and removal:
   - developer tools install under `${PREFIX}/libexec/scripts`
     (`TESTS_FORMAT_DIR`), not `BINDIR`; `TESTS_FORMAT_LINKS=1` adds
     compatibility symlinks;
   - `make all` installs only the Perl runtime helper; use the explicit
     `install-tests-format` target for validators;
   - every install target has a matching `uninstall-*` target and honors
     `DESTDIR`.

5. To add a validator:
   - write it as POSIX `sh` unless it needs Perl;
   - use `mktemp` and a cleanup trap;
   - print a clear log path and use meaningful exit codes;
   - add it to `TESTS_FORMAT_SCRIPTS` in `Makefile` if it should be installed;
   - add it to `test-validate`, or to a separate target such as
     `test-manpages` when it depends on an optional tool; a dedicated
     prerequisite target can keep the main validation recipe manageable;
   - report absent optional tools as skips by default and failures with
     `--strict`;
   - document it in `tests-format/README.md`.
   - update `tests-format/openbsd-tools.txt` when adding or changing an
    optional tool with an OpenBSD port/package mapping; keep that file
    informational and verify package paths before recording them.
   - for agent instruction synchronization, use
     `validate-agent-knowledge.py`; `make test-validate` runs it against the
     current worktree. Pull request comparisons require
     `--scope range --base BASE_REF --head HEAD_REF`.
     The agent workflow runs the shared contract tests and range
     check; the platform workflow runs native/isolated checks. The standalone
     Windows xerj updater suite is `pwsh -NoProfile -File windows/tests/test-update-xerj.ps1`;
     it uses temporary paths and mocked downloads/clients, not real installs.
6. To add a regression test:
   - use POSIX `sh` or core-module Perl for portable shell/tool tests; use the
     Python standard library when a filesystem harness needs to exercise both
     platform-specific sync scripts without sourcing their deployment entry
     points;
   - keep fixtures in a `mktemp` tree with trap cleanup in shell tests, or use
     `tempfile.TemporaryDirectory` in Python tests;
   - do not access the network, the user's home, or system configuration;
   - add it to `test-regression` and document it in the relevant README.
   - website sync filter coverage lives in
     `tests/test_sync_website_filters.py`; it runs both the rsync and copy
     staging paths, tests initial and existing destinations, and preserves a
     temporary `.sync.lock` without touching a real document root.
7. The permission policy is content-based: directories and scripts are 0755,
   data is 0644, Makefiles are 0755. Use `--check` to report and
   `--dry-run` to preview. Only `make fix-permissions` applies changes.

## Validations

```sh
make test
make test-validate
make test-regression
make check-permissions
```

Individual read-only checks:

```sh
/bin/sh tests-format/fix-permissions.sh --check .
/bin/sh tests-format/validate-correctness.sh --target all .
/bin/sh tests-format/validate-correctness.sh --strict --target openbsd .
```

`--strict` also fails on `WARNING` and `UNVERIFIED` findings. Use it when the
goal is to drive the tree to a clean audit, not for every routine run.

Optional tools are discovered through `PATH`: `shfmt`, `shellcheck`,
`checkbashisms`, `perltidy`, `perlcritic`, `mbake`, `checkmake`, `bmake`,
`mandoc`. A missing tool is a skipped check, not a pass. `mbake` and
`checkmake` are GNU make tools; `validate-make.sh` skips them for files using
detected BSD make syntax and for include-only wrappers that they cannot lint
in isolation. The BSD make dry run skips GNUmakefile wrappers and build
Makefiles whose generated `config.mk` is absent. On OpenBSD, `mbake` and
`checkmake` are skipped because they are not ported.

## Common problems

- `make format` reported drift after rewriting; review the diff and rerun checks.
- `validate-shell.sh --format` runs `shfmt -w`; its default `--check` mode
  reports drift without rewriting.
- `validate-perl.sh --format` runs `perltidy` in place; it uses `-npro` so a developer
  profile does not change the result.
- `validate-python.sh --check` uses cache-free Ruff checks. `--format` applies
  formatting and clears Ruff caches in its cleanup; both report drift as a
  failure. Keep the `require_cmd`, `run_validate_python`, `main "$@"` pattern.
- `make test-tooling` covers all four validator modes, strict missing tools,
  make execution opt-in, installation paths with spaces, and early failures
  using temporary paths and offline tool doubles. Installer failure tests must
  also verify cleanup: the shell-config copy recipe restores its immutable
  attribute in an exit trap even when a copy fails.
- `fix-permissions.sh --help` now exits 0; other usage errors exit 2.
- `fix-permissions.sh` prunes `.git` directories and gitfiles, never follows
  symlinks, and preserves setuid/setgid/sticky bits.
- The Windows validation suite is separate and must run on Windows.
- `test-ssh-menu.pl` skips with exit 0 when `ssh` is unavailable.
- `validate-correctness.sh` audits only high-confidence patterns inside
  here-documents; review other generated code manually.
- Generated Windows test artifacts (`work/`, `vendor/`, `results.json`,
  `self-check.json`) are ignored and should not be committed.

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
`python3 scripts/validate-agent-knowledge.py --scope worktree`). The automated check
covers structure and resolvable local references; semantic relevance still
requires review. Report the synchronization result in the final summary and
do not claim completion if it was skipped or failed.

## References

- [Root agent instructions](../../../AGENTS.md)
- [Tests and formatting tools](../../../tests-format/README.md)
- [Makefile](../../../Makefile)
- [Permission script](../../../tests-format/fix-permissions.sh)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
- [Windows formatter tests](../../../windows/test-format/tests/README.md)
