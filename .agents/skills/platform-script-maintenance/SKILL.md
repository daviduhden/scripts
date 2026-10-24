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
5. Keep the target's conventions:
   - Bash: `set -euo pipefail`, quoted expansions, `main "$@"`.
   - ksh: `set -eu`, `typeset`, `print`, guarded `pipefail` if needed.
   - POSIX `sh`: no arrays, `[[ ]]`, `local`, or `pipefail`.
6. Make update scripts idempotent. Check installed versions, upsert
   configuration keys, and do not duplicate PATH or firewall entries.
7. For privileged or destructive code, follow `system-change-safety` before
   writing the implementation.
8. Run the validations below. Do not run the script against the host.

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

`validate-shell.sh` runs `shfmt -w` and can rewrite files. Run `git diff`
afterwards. `make test` includes the same formatter behavior. If an optional
tool is missing, report the check as skipped rather than passed.

## Common problems

- A script was added to the directory but not to `*_SCRIPTS` or the README.
- The installed name still contains `.bash`, `.ksh`, `.sh`, or `.pl`; the
  Makefile strips one of those suffixes.
- Two OS-specific targets were installed into the same `BINDIR`; they share
  command names and cannot coexist.
- `make install-secureblue` removes `${BINDIR}/systemd` before recopying the
  unit templates.
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

## References

- [Root agent instructions](../../../AGENTS.md)
- [Makefile](../../../Makefile)
- [Debian scripts](../../../debian/README.md)
- [OpenBSD scripts](../../../openbsd/README.md)
- [SecureBlue scripts](../../../secureblue/README.md)
- [Interactive shell helpers](../../../shell/README.md)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
