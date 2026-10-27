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

`make test` runs `test-validate` and then `test-regression`:

1. `/bin/sh tests-format/validate-python.sh .` (`test-python`, a prerequisite
   of `test-validate`)
2. `/bin/sh tests-format/validate-shell.sh .`
3. `/bin/sh tests-format/validate-perl.sh .`
4. `/bin/sh tests-format/validate-make.sh .`
5. `/bin/sh tests-format/fix-permissions.sh --check .`
6. `/bin/sh tests-format/validate-correctness.sh --target all .`
7. `/bin/sh tests-format/validate-manpages.sh .`
8. `/bin/sh tests-format/test-fix-permissions.sh`
9. `/bin/sh tests-format/test-validate-correctness.sh`
10. `perl tests-format/test-ssh-menu.pl`
11. `perl tests-format/test-normalize-files.pl`

Important boundaries:

- Steps 1-4 can rewrite files when `shfmt`, `perltidy`, `ruff`, or `mbake` are
  installed. A successful rewrite still makes the validator exit non-zero.
- Step 5 is read-only and exits 1 on a permission mismatch.
- Step 6 is read-only; it creates a temporary directory for its worker.
- Step 7 is read-only and exits 0 when `mandoc` is absent.
- Steps 8-11 use temporary trees. They must not modify the repository.
- `validate-windows-installer.bat`, `psfmt`, and the PowerShell test runner
  are Windows-only and are not part of `make test`.

## Procedure

1. Run the read-only checks first:
   ```sh
   shfmt -l -s .
   shellcheck -x PATH
   perl -c PATH
   /bin/sh tests-format/fix-permissions.sh --check .
   /bin/sh tests-format/validate-manpages.sh .
   /bin/sh tests-format/validate-correctness.sh --target all .
   ```
2. Run the aggregate suite:
   ```sh
   make test
   ```
3. Inspect `git diff`. Formatters may have rewritten files; decide whether the
   rewrite is intended, and never commit unrelated formatting.
4. To add a validator:
   - write it as POSIX `sh` unless it needs Perl;
   - use `mktemp` and a cleanup trap;
   - print a clear log path and use meaningful exit codes;
   - add it to `TESTS_FORMAT_SCRIPTS` in `Makefile` if it should be installed;
   - add it to `test-validate`, or to a separate target such as
     `test-manpages` when it depends on an optional tool; a dedicated
     prerequisite target can keep the main validation recipe manageable;
   - make optional-tool checks skip with exit 0 when the tool is absent;
   - document it in `tests-format/README.md`.
  - update `tests-format/openbsd-tools.txt` when adding or changing an
    optional tool with an OpenBSD port/package mapping; keep that file
    informational and verify package paths before recording them.
   - for agent instruction synchronization, use
     `validate-agent-knowledge.py`; `make test-validate` runs it against the
     current worktree, while `--base REF` supports pull request comparisons.
     No CI workflow is currently configured in this repository.
5. To add a regression test:
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
6. The permission policy is content-based: directories and scripts are 0755,
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
`mandoc`. A missing tool is a skipped check, not a pass. `checkmake` findings
are recorded as failures; `checkmake` and `mbake` are skipped on OpenBSD.

## Common problems

- `make test` rewrote files and then failed; review the diff and rerun.
- `validate-shell.sh` runs `shfmt -w`; do not run it when you need a strictly
  read-only check.
- `validate-perl.sh` runs `perltidy` in place; it uses `-npro` so a developer
  profile does not change the result.
- `validate-python.sh` applies `ruff format` and runs `ruff check` for Python
  files, then runs `ruff clean` from the selected root. Ruff is required only
  when Python files are found; it follows the neighboring validator structure
  with `require_cmd` checks in `main`, work in `run_validate_python`, and
  `main "$@"` as its entry point. Formatting rewrites are reported as
  validation failures so the diff can be reviewed.
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
`python3 scripts/validate-agent-knowledge.py --scope worktree .`). The automated check
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
