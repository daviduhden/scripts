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

`make check` runs agent-knowledge validation and contract tests, shell, Perl,
Make, permission, correctness, and manual-page checks. `make test` completes
validation before isolated regressions (including under parallel make):
tooling/installers, permissions, correctness, both Perl programs, delivery
transactions, release verification, and website synchronization filters.

The three language validators default to `--check`; only `--format` rewrites
sources. `make format` invokes all three explicitly. Formatting drift exits 2
even if repaired, so inspect the diff and rerun checks. Safe `mktemp` logs
remain for inspection; transient failure, skip and format lists are cleaned.

Use `--strict` to fail when optional tools or Perl modules are missing.
Non-strict runs record `[SKIP]` diagnostics and counts rather than claiming
those checks passed. Make dialect/platform omissions are expected skips.
Make evaluation is opt-in via `--make-dry-run`: even `-n` can execute commands
while parsing untrusted Makefiles. `perl -c` loads modules and executes compile-time blocks, so those
sources must also be trusted.

Windows batch/PowerShell checks run natively. The manual Platform Validation
workflow (`workflow_dispatch`) runs safe checks and regressions on Ubuntu 24.04,
Windows Server 2025 (`windows-2025`), and an OpenBSD 8.0 VM; it must never
execute administrative scripts against a host and must not run on pushes, pull
requests, or a schedule.
The Windows job pins `PSScriptAnalyzer` 1.25.0. `actions/checkout` is pinned to
v7.0.1 and `vmactions/openbsd-vm` to v1.4.9 by full commit SHA. Keep runner
images, VM releases, analyzer versions, and action SHAs as separate
dependencies: re-check the upstream repository and release notes, confirm the
SHA belongs to the documented tag, and run `actionlint` before changing a pin.
Do not substitute floating `ubuntu-latest` or `windows-latest` labels in a job
whose behavior depends on a specific image.
`zizmor` 1.32.0 must report zero findings in regular, pedantic and auditor
modes. The two `shell: cmd` steps are the only inline exception: the repository
batch installer and launchers must run under CMD, so the `misfeature` finding
is suppressed with that specific justification. Do not replace those steps
with a wrapper that hides whether the batch files actually ran.

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
     `DESTDIR`;
   - install, uninstall, help, and format loops live in
     `scripts/manage-install.sh`; keep new Makefile recipes declarative and
     pass lists/paths through the environment.

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
     `validate-agent-knowledge.pl`; `make test-validate` runs it against the
     current worktree. Pull request comparisons require
     `--scope range --base BASE_REF --head HEAD_REF`.
     The agent workflow runs the shared contract tests and range
     check; the platform workflow runs native/isolated checks. The standalone
     Windows xerj updater suite is `pwsh -NoProfile -File windows/tests/test-update-xerj.ps1`;
     it uses temporary paths and mocked downloads/clients, not real installs.
6. To add a regression test:
   - use POSIX `sh` or core-module Perl for portable shell/tool tests; use Perl
     (`File::Temp`, `IPC::Open3`) when a filesystem harness needs to exercise
     both platform-specific sync scripts without sourcing their deployment
     entry points;
   - keep fixtures in a `mktemp` tree with trap cleanup in shell tests, or use
     `File::Temp` in Perl tests;
   - store reusable mock programs as standalone files under `tests/fixtures/`
     instead of embedding them in a heredoc;
   - do not access the network, the user's home, or system configuration;
   - add it to `test-regression` and document it in the relevant README.
   - website sync filter coverage lives in
     `tests/test_sync_website_filters.pl`; it runs both the rsync and copy
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

### CI workflow checks

Workflow syntax and expression validation is static:

```sh
actionlint .github/workflows/*.yml
```

Run `yamllint` only when a repository configuration exists, so the check
reflects project policy rather than yamllint defaults; this tree currently has
no `.yamllint` configuration. Do not run the workflow to validate a pin.

Current platform CI pins:

| Dependency | Pin | Notes |
| --- | --- | --- |
| `actions/checkout` | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `vmactions/openbsd-vm` | `v1.4.9` | `f1ca8bc8ecc5b6ef7218e5b914836e067e1546d3` |
| `PSScriptAnalyzer` | `1.25.0` | Latest stable release |
| OpenBSD VM | `8.0` | Current stable release |
| Windows runner | `windows-2025` | Windows Server 2025 |
| Platform Linux runner | `ubuntu-24.04` | Ubuntu 24.04 |
| Agent-knowledge runner | `ubuntu-latest` | Needs only Git and Perl |

Before changing a pin, read the upstream release notes or changelog, confirm the
tag resolves to the recorded commit, check that the job's commands still work
with the new image or release, and run `actionlint`. Keep the version comment
next to the SHA. OpenBSD VM setup uses package names such as `pkg_add -I bash
git rsync--`; check for release-specific paths rather than assuming a version
bump is only a string change.

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
- The manual Platform Validation workflow runs
  `validate-shell.sh --check --strict`; shellcheck info and warning findings
  are failures. Fix them rather than suppressing them without a documented
  reason.
- Windows batch validators run on the `windows-2025` runner. `findstr /l /c:` can
  mishandle a pattern combining a backslash and wildcard such as
  `windows\*.ps1`; require a plain literal token such as `collect_ps_program`
  instead.
- Keep `scripts/validate-agent-knowledge.pl` tidy with both the Ubuntu
  `perltidy` package used by CI and newer releases. Long method chains can be
  split differently across versions, so prefer short assignments and separate
  method calls.
- The Windows job runs `test-normalize-files.pl`; keep POSIX-only cases
  (case-only rename rollback, raw 0xFF filenames, symlink creation) guarded by
  explicit Windows skips.
- The OpenBSD VM job sets `TMPDIR` under `GITHUB_WORKSPACE`; `normalize-files`
  also canonicalizes its root there because `/tmp` can be a symlink that
  unveil resolves separately. Its regression suite disables the sandbox with
  `NORMALIZE_FILES_NO_SANDBOX=1` because the VM veil rejects the temporary
  trees the suite creates.
- `tests/test_sync_website_filters.pl` exercises the Debian sync implementation
  only on Linux; the OpenBSD job runs the ksh implementation. Keep the Debian
  script's GNU staging assumptions out of the OpenBSD VM.
- The correctness command probe must ignore the internal `QQUOTED` placeholder
  and accept case labels containing `:`. Keep Debian-only tools such as
  `dracut`, `dtc`, and `lsinitrd` in `DEBIAN_CMDS` so the Ubuntu runner does
  not report them as missing.
- `validate-perl.sh --format` runs `perltidy` in place; it uses `-npro` so a developer
  profile does not change the result.
- `make test-tooling` covers the shell, Perl, and Make validator modes, strict
  missing tools, make execution opt-in, installation paths with spaces, and
  early failures using temporary paths and offline tool doubles. Installer failure tests must
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
`perl scripts/validate-agent-knowledge.pl --scope worktree`). The automated check
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
