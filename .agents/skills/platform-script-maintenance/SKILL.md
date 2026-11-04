---
name: platform-script-maintenance
description: >-
  Add or update Debian, OpenBSD, SecureBlue, or interactive shell scripts in
  this repository. Use when changing files under debian/, openbsd/,
  secureblue/, or shell/, or when updating Makefile script lists, install
  targets, file modes, or platform READMEs.
---

# Platform script maintenance

## When to use

- Adding, removing, or renaming a script in `debian/`, `openbsd/`,
  `secureblue/`, or `shell/`.
- Changing an install target, `BINDIR`, `PREFIX`, or a script list in the
  `Makefile`.
- Updating a platform README or documenting a script's privileges.
- Porting behavior between platforms.

Read `AGENTS.md`, the platform README, and the nearest similar script before
editing. Check `git status --short` so you do not mix your changes with
unrelated work.

## Choose the right runtime

| Directory | Shebang / form | Notes |
| --- | --- | --- |
| `debian/` | `#!/bin/bash` (one uses `#!/usr/bin/env bash`) | Bash 4+ features; GNU utilities. |
| `secureblue/` | `#!/bin/bash` | Bash, `run0`, rpm-ostree, Homebrew, systemd user units. |
| `openbsd/` | `#!/bin/ksh` | OpenBSD base `ksh` and native tools. No Bashisms. |
| `shell/` | no shebang; sourced by Bash | Interactive helpers; `# shellcheck shell=bash`. |
| `tests-format/` | `#!/bin/sh` or Perl | POSIX `sh` for validators. |

Do not copy a Bash script into `openbsd/` and change only the shebang. Translate
GNU options, paths, privilege tools, and service commands. Do not add `sudo`,
`systemctl`, `run0`, `apt`, or `/etc/systemd` to OpenBSD code.

## Procedure

1. Classify the change: new script, behavior change, packaging change, or
   documentation only.
2. Read a nearby script that already solves the same class of problem. Reuse
   its helpers (`log`, `warn`, `error`, `require_cmd`, `require_root`,
   `detect_root_cmd`, `run_root`) instead of inventing parallel ones.
3. Keep the copyright/license header that points to `LICENSE`.
4. For a new executable script:
   - add the correct shebang and set mode `0755`;
   - add it to the appropriate `*_SCRIPTS` list in `Makefile`;
   - add it to the platform README table;
   - for a public Perl program, add it to `perl/programs.txt` instead of a
     shell list;
   - update the install description if command names change.
5. Honor `DESTDIR` in new install rules and add a matching `uninstall-*`
   target. Developer tools belong under `${PREFIX}/libexec/scripts`, units
   under `${PREFIX}/lib/systemd/user`, and runtime commands in `BINDIR`.

6. Keep the target's conventions:
   - Bash: `set -euo pipefail`, quoted expansions, `main "$@"`.
   - ksh: `set -eu`, `typeset`, `print`, guarded `pipefail` if needed.
   - POSIX `sh`: no arrays, `[[ ]]`, `local`, or `pipefail`.
7. Make update scripts idempotent. Check installed versions, upsert
   configuration keys, and do not duplicate PATH or firewall entries.
8. For privileged or destructive code, follow `system-change-safety` before
   writing the implementation.
9. Run the validations below. Do not run the script against the host.
   For website sync changes, exercise the source filtering and stale-path
   cleanup against temporary source and destination trees, including a
   destination with an active `.sync.lock`. Keep the known internal-path list
   aligned between Debian and OpenBSD and retain public content files.

## Validations

Static, read-only:

```sh
/bin/sh tests-format/validate-correctness.sh --target debian .
/bin/sh tests-format/validate-correctness.sh --target openbsd .
/bin/sh tests-format/validate-correctness.sh --target secureblue .
/bin/sh tests-format/fix-permissions.sh --check .
shfmt -l -s .
```

`--target secureblue` also scans `shell/`. `--target all` covers all three
trees; it scans `shell/` once through the secureblue family.

Formatting and full suite:

```sh
/bin/sh tests-format/validate-shell.sh .
make test
```

`validate-shell.sh` defaults to read-only `--check`; use `--format` explicitly
when applying formatting. `make test` checks before running regressions. If an optional
tool is missing, report the check as skipped rather than passed.

## Common problems

- Release updates must verify their documented trust boundary before activation.
  Go stages a fresh checked tree and retains `.go-backup.*` for recovery;
  msedit requires the exact GitHub asset digest; btop fallback archives require
  one bounded source root without links or traversal. These helpers use core
  Perl modules (`JSON::PP`, `Archive::Tar`) or native tools, not embedded
  Python. Argon requires operator-pinned digests or explicit
  `--trust-upstream`; reviewed local scripts can avoid downloads. Never
  validate by executing their administrative entry points.

- Arti installation preserves existing TOML unless `--replace-config` is
  selected. TOML validation and unit rendering are delegated to the standalone
  `secureblue/arti-config.py` helper (installed with the SecureBlue target),
  never an embedded heredoc. Validate the rendered systemd unit before
  publishing and exercise activation rollback with mocked systemctl. Escape
  complete systemd arguments, including `%` specifiers and `$` expansion in
  Exec directives; socat socket paths cannot contain commas.
- Website sync locks are siblings of the document root and fail closed on
  existing locks. Atomic mode requires an already configured symlink docroot;
  `--check-atomic` checks this prerequisite only. Keep Debian's GNU `mv -T`
  and OpenBSD's base-Perl `rename` publication behavior distinct. Never migrate a
  production directory to a symlink automatically during validation.

- `secureblue/update-xerj.bash` installs the static musl release per user in
  `~/.local/bin`, without rpm-ostree layering or run0. Verify the archive's own
  SHA-256 and exact checksum filename before reading the expected binary.
  Client flags register stdio MCP only: Codex uses its CLI, Crush a managed
  `crushrc` block, and OpenCode `mcp.xerj` in strict JSON. Preserve other
  settings and backups; refuse existing JSONC for manual merging. The user
  must run an authenticated node separately and supply `XERJ_AUTH` when local
  key discovery cannot find its data directory. Do not execute this updater
  during validation.

- A script was added to the directory but not to `*_SCRIPTS` or the README.
- A source script is missing its extension, or an installed name still
  contains `.bash`, `.ksh`, `.sh`, `.pl`, `.py`, or a bundled `.yaml` suffix.
  Source files always carry an extension; install targets strip it.
- Two OS-specific targets were installed into the same `BINDIR`; they share
  command names and cannot coexist.
- `install-secureblue` installs units under `${PREFIX}/lib/systemd/user`
  (`SYSTEMD_USER_UNIT_DIR`) and never deletes `${BINDIR}/systemd`.
- A new inline `perl -e`/`-n`/`-c` program or Python `-c`/heredoc appeared in
  a shell script; move it to a focused helper installed by the target.
- GNU-only options in `openbsd/`: bare `mktemp`, `sort -V`, `sed -r`,
  `readlink -e`, `find -printf`, `xargs --null`.
- Linux commands or paths in `openbsd/`: `systemctl`, `apt`, `run0`,
  `/etc/systemd`, `/proc`, `/etc/os-release`.
- Bashisms in `openbsd/`: `local`, `declare`, `readarray`, `mapfile`,
  here-strings, process substitution, `$'...'`.
- Missing executable bit or a shebang on a sourced `shell/` helper.
- The correctness validator audits only high-confidence patterns inside
  here-documents (remote pipe to shell, unguarded `rm -rf`, recursive
  `chmod`/`chown`, `find /`, bare `mktemp`). Review other generated code
  manually.

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
- [Makefile](../../../Makefile)
- [Debian scripts](../../../debian/README.md)
- [OpenBSD scripts](../../../openbsd/README.md)
- [SecureBlue scripts](../../../secureblue/README.md)
- [Interactive shell helpers](../../../shell/README.md)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
