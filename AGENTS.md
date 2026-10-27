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
| `debian/sync-website.bash`, `openbsd/sync-website.ksh` | Platform-specific staged website synchronization; public-tree filters are intentionally kept aligned. |
| `perl/` | Portable Perl programs (5.10.1+, core modules). `programs.txt` is the public manifest shared by the POSIX and Windows installers. |
| `secureblue/` | Bash helpers for SecureBlue's rpm-ostree environment, user services, and `run0`; `systemd/` holds user-unit templates. |
| `shell/` | Bash helpers that are sourced interactively; they target Linux/SecureBlue and are not standalone programs. |
| `windows/` | Batch installers/launchers and PowerShell utilities; Windows-only. `test-format/` contains `psfmt` and its tests. |
| `tests-format/` | POSIX `sh` validators/formatters, Perl regression tests, Python agent-knowledge validation and Ruff validation, and the Windows batch validator. |
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
- `tests-format/validate-python.sh` applies Ruff formatting and lint to Python
  files, then clears Ruff's caches under the selected root; formatting changes
  count as validation issues, and Ruff is required only when Python files are
  found.
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
make check-agent-knowledge
make fix-permissions
make install-debian
make install-openbsd
make install-secureblue
make install-shell
make install-perl
make install-tests-format
```

`make test` runs `validate-python.sh` first, then `validate-shell.sh`,
`validate-perl.sh`, `validate-make.sh`, `fix-permissions.sh --check`, `validate-correctness.sh
--target all`, `validate-agent-knowledge.py`, `validate-manpages.sh` (skipped
  without `mandoc`), then the regression tests, including temporary-tree tests
  for both website synchronizers. Windows checks are not part of it.

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
- Website sync stages a full repository checkout outside the document root,
  then filters known GitHub/agent documentation, VCS metadata, development
  settings, tests, and caches before copying. Both implementations also remove
  only those known stale internal paths from the existing document root;
  preserve the active `.sync.lock`, public content, and linked maintenance
  scripts. Keep the exclusion lists equivalent across Debian and OpenBSD, and
  validate both initial and update paths against temporary trees only.
  `tests/test_sync_website_filters.py` exercises rsync and copy fallback paths
  when their tools are available, verifies stale-file cleanup and lock
  preservation, and never sources the full deployment scripts.
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

## Continuous Agent & Skills Maintenance

Agent instructions and skills are living repository artifacts.

Every repository modification MUST include an agent/skills synchronization step.

Before completing any task, inspect the applicable AGENTS.md and SKILL.md files, update the affected instructions, and validate their consistency with the implementation.

A code change without the corresponding agent knowledge maintenance is considered incomplete.

Never claim completion when the synchronization step has been skipped or has failed.

This review is required after every change to code, configuration, dependencies, features, bug fixes, refactors, tests, workflows, documentation, or repository architecture. At task end, inspect the root and nested `AGENTS.md`, `.github/agents/*.agent.md`, `.agents/skills/**/SKILL.md`, `.github/skills/**/SKILL.md`, `.claude/skills/**/SKILL.md`, and any tool-specific instruction files present (including Cursor and Copilot files). The current repository has one root `AGENTS.md`, five skills under `.agents/skills/`, and a PR workflow at `.github/workflows/agent-knowledge-validation.yml`; no specialized agent definitions exist.

Map changed paths to the instructions whose scope covers them, then read the applicable skill(s) and their linked references. Update an existing skill when its procedures, tools, assumptions, validation, or reusable knowledge change. Create a skill only when a durable responsibility has no suitable existing skill. Update specialized agent instructions when their workflow or responsibility changes. Remove obsolete or conflicting guidance and verify that changed local references still resolve. Do not add cosmetic edits, timestamps, or task-specific notes solely to satisfy this rule.

Before declaring a task complete:

1. Make a relevant, substantive update to at least one agent instruction or skill for every project change. If no reusable change is warranted, record the reason in the relevant operational documentation; do not silently omit synchronization.
2. Check changed guidance against the implementation, examples, commands, paths, validation behavior, and cross-references.
3. Run `make check-agent-knowledge` (or `python3 scripts/validate-agent-knowledge.py --scope worktree`) and the checks appropriate to the changed code. The automated check verifies structural conditions and local references; semantic relevance still requires agent review.
4. If synchronization or validation cannot be completed, state the exact limitation and mark the task incomplete. Do not claim completion.

This applies to edits to AGENTS.md, skills, agent definitions, and these rules as well. Perform one complete synchronization review at task end; rerun the check only after correcting a detected failure.

### Mandatory definition of done

- [ ] Repository changes implemented.
- [ ] Relevant agent instructions reviewed.
- [ ] Relevant skills reviewed.
- [ ] Affected AGENTS.md / SKILL.md files updated.
- [ ] Obsolete knowledge removed.
- [ ] New reusable knowledge incorporated.
- [ ] Agent and skill references validated.
- [ ] Automated maintenance checks passed.
- [ ] Final synchronization status reported.

Final reports must include an **Agent & Skills Synchronization** section with agents and skills reviewed, instruction files updated, knowledge incorporated or corrected, validations actually run, and final status `PASS` or `FAIL`.

### Shared Agent Knowledge Validation Contract

Use `python3 scripts/validate-agent-knowledge.py --scope worktree` for local
changes and `python3 -m unittest discover -s tests/agent_knowledge_validator -v`
for its contract tests. The validator requires Python 3.11+ and Git, uses only
the Python standard library, and publishes contract version `1.0.0`. All
adopting repositories share the same CLI, AK001-AK006 identifiers, output
schema, and exit codes (`0` pass, `1` policy failure, `2` execution/configuration
error). For a pull request, pass both revisions with
`--scope range --base BASE_REF --head HEAD_REF`; compare from their merge base.

Read [Agent Knowledge Validation Contract](docs/agent-knowledge-validation.md)
for the complete rules, JSON schema, optional repository configuration,
warning semantics, and extension process. AK004 and AK006 can require human
review; their warnings do not prove or disprove semantic correctness. Keep the
canonical script and black-box unittest suite byte-identical across adopting
repositories. Repository-specific requirements belong in the documented TOML
configuration or a stable `AKX...` extension, never in a private fork of the
shared rules. The GitHub PR workflow runs the same tests and range command;
it does not edit files or require secrets.
