# AGENTS.md

## Scope

This repository provides system-administration utilities for Debian-based
systems, SecureBlue, OpenBSD, Windows, and portable Perl. Agent-facing
documentation lives in this file and `.agents/skills/`; those files are not
runtime code.

Keep guidance tied to the tree. Verify commands, paths, flags, and script
behavior before documenting them. If a requested change is outside the
repository's scope, say so instead of inventing support.

## Layout

| Path | Runtime and purpose |
| --- | --- |
| `debian/` | Bash helpers for Debian-based systems; several require Debian 13 or a supported derivative. |
| `openbsd/` | OpenBSD base `ksh` helpers using native tools; not Bash. |
| `perl/` | Portable Perl programs (5.10.1+, core modules). `programs.txt` is the public manifest shared by the POSIX and Windows installers. |
| `secureblue/` | Bash helpers for SecureBlue's rpm-ostree environment, user services, and `run0`; `systemd/` holds user-unit templates. |
| `shell/` | Bash helpers that are sourced interactively; they target Linux/SecureBlue and are not standalone programs. |
| `windows/` | Batch installers/launchers and PowerShell utilities; Windows-only. `test-format/` contains `psfmt` and its tests. |
| `tests-format/` | POSIX `sh` validators/formatters, Perl regression tests, and the Windows batch validator. |
| `Makefile` | POSIX-sh install and test entry points; recipes must remain BSD make compatible. |
| `VERSION` | Installed version metadata (`1.0.0`). |

`make all` installs only `install-perl` and `install-tests-format`. The
OS-specific install targets install the same command names, so they cannot
share one `BINDIR`. Installed names omit `.bash`, `.ksh`, `.sh`, and `.pl`.

## Conventions

- Preserve the copyright/license header that points to `LICENSE`. Do not edit
  `LICENSE` or copyright notices unless the task explicitly requires it.
- Shell scripts use tabs and `shfmt -s` style. Perl uses 4-space indentation
  and an 80-column limit. Makefile recipes use tabs.
- Bash scripts in `debian/` and `secureblue/` generally use
  `set -euo pipefail`, reset `PATH`, define `log`/`warn`/`error`, use
  `require_cmd`, and expose `main "$@"`. `secureblue/postinstall.bash`
  intentionally uses `set -uo pipefail` because it is interactive.
- `openbsd/` scripts use `#!/bin/ksh`, `print`, and `typeset`. The project
  validator rejects `local`, `declare`, `readarray`, `mapfile`, `shopt`,
  unguarded `set -o pipefail`, here-strings, process substitution, and
  `$'...'` in that tree.
- `tests-format/` scripts use `#!/bin/sh` and POSIX constructs.
- Windows batch files use CRLF, `DisableDelayedExpansion`, quoted paths, and
  `exit /b %ERRORLEVEL%` in launchers. PowerShell formatter/tests require
  PowerShell 7; the installer uses Windows PowerShell for registry and syntax
  checks.
- Reuse the existing helper names and patterns instead of adding a second
  logging, elevation, or install mechanism.
- Most scripts do not implement `--help`; do not assume it exists.

## Commands

Run these from the repository root. All of them exist in the `Makefile`.

```sh
make help
make test
make test-validate
make test-manpages
make test-regression
make check-permissions
make fix-permissions
make install-debian
make install-openbsd
make install-secureblue
make install-shell
make install-perl
make install-tests-format
```

`make test` runs, in order: `validate-shell.sh`, `validate-perl.sh`,
`validate-make.sh`, `fix-permissions.sh --check`, `validate-correctness.sh
--target all`, `validate-manpages.sh` (skipped without `mandoc`), then the
four regression tests. Windows checks are not part of it.

Read-only checks that do not apply formatting:

```sh
/bin/sh tests-format/validate-correctness.sh --target all .
/bin/sh tests-format/fix-permissions.sh --check .
shfmt -l -s .
perltidy -npro -ast -se -o /dev/null perl/normalize-files.pl
perltidy -npro -ast -se -o /dev/null perl/ssh-menu.pl
```

`validate-shell.sh`, `validate-perl.sh`, and `validate-make.sh` rewrite files
when `shfmt`, `perltidy`, or `mbake` are installed and formatting has drifted.
Run `git diff` afterwards. Each of these three writes its findings to a log
file under `${TMPDIR:-/tmp}` and prints the path.

Windows validation must run on Windows:

```bat
windows\install-windows.bat --dry-run
tests-format\validate-windows-installer.bat
```

```powershell
.\windows\test-format\psfmt.ps1 -c .
pwsh -NoProfile -File .\windows\test-format\tests\run-tests.ps1
```

## Safety and testing

- Do not run scripts that modify the host as part of an agent task. This
  includes package installs, `sudo`/`doas`/`run0`, service changes, firewall
  rules, `/etc` rewrites, history purges, and deployments. Review the code and
  run static checks instead.
- If execution is explicitly requested, use the script's existing dry-run
  flag when present (`clean-logs.bash --dry-run`, `ai-purge-history --dry-run`,
  `install-windows.bat --dry-run`) and a disposable target. Never test
  deletion on real data.
- Distinguish these levels in your report:
  - static analysis: validators, `shellcheck`, `perl -c`, `PSScriptAnalyzer`;
  - formatting: shfmt/perltidy/mbake, which may rewrite files;
  - tests: `make test` and the Windows test runner;
  - real execution: running the system-changing script itself.
- Record the exact command and result. Report skipped optional tools as
  skipped, not passed.
- There is no CI in the current tree. Do not claim that a platform was tested
  unless it was.
- Before changing a script, read its platform README and check `git status`.
  Do not revert, reformat, or commit unrelated changes.
- Do not commit, push, or tag unless asked. Change `VERSION` only for an
  intentional release.

## Skills

| Skill | Use when |
| --- | --- |
| [platform-script-maintenance](.agents/skills/platform-script-maintenance/SKILL.md) | Adding or updating scripts under `debian/`, `openbsd/`, `secureblue/`, or `shell/`, or changing install lists, modes, or platform docs. |
| [shell-and-perl-quality](.agents/skills/shell-and-perl-quality/SKILL.md) | Editing shell or Perl code, quoting, portability, formatting, or lint findings. |
| [windows-powershell-maintenance](.agents/skills/windows-powershell-maintenance/SKILL.md) | Editing anything under `windows/`, batch launchers, the installer, or `psfmt`. |
| [system-change-safety](.agents/skills/system-change-safety/SKILL.md) | Reviewing or changing privileged, destructive, deployment, service, firewall, or configuration-writing code. |
| [script-tests-and-formatting](.agents/skills/script-tests-and-formatting/SKILL.md) | Changing `tests-format/`, Makefile test targets, regression tests, or formatting policy. |
