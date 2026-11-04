# Scripts

Shell, Perl, and PowerShell utilities for system administration and maintenance across multiple operating systems.

## Structure

```
.
├── debian/        # Scripts for Debian-based distributions
├── openbsd/       # Scripts for OpenBSD systems
├── perl/          # Perl scripts (portable)
├── secureblue/    # Scripts for SecureBlue
├── windows/       # Windows batch and PowerShell scripts
├── shell/         # Shell helpers for interactive shells
└── tests-format/  # Validation, formatting and permission tools
```

Each directory documents its scripts, requirements, and usage:

- [Debian](debian/README.md)
- [OpenBSD](openbsd/README.md)
- [Perl](perl/README.md)
- [SecureBlue](secureblue/README.md) and [systemd user services](secureblue/systemd/README.md)
- [Windows](windows/README.md), [PowerShell formatter](windows/test-format/README.md), and [formatter tests](windows/test-format/tests/README.md)
- [Interactive Bash helpers](shell/README.md)
- [Validation and formatting tools](tests-format/README.md)
- [Architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md), [security policy](SECURITY.md), and [changelog](CHANGELOG.md)

## Installation

Targets are system-specific. Install the set for your host with
`install-debian`, `install-openbsd` or `install-secureblue`; `make all`
installs only the OS-independent runtime helper (Perl), because the OS-specific
sets share installed command names and cannot coexist in one `BINDIR`. Adjust
`PREFIX`/`BINDIR` if you need a different path (defaults to `/usr/local/bin`).
`DESTDIR` is supported for staged packaging. SecureBlue user units are installed
under `${PREFIX}/lib/systemd/user`, not below `bin`.

```
# Debian
make install-debian

# OpenBSD
make install-openbsd

# SecureBlue
make install-secureblue

# SecureBlue shell aliases (~/.bashrc.d/aliases.bash with chattr -i/+i)
make install-shell

# Same as install-shell-bash
make install-shell-bash

# Perl
make install-perl

# Validation/formatting tools (for developers), installed under
# ${PREFIX}/libexec/scripts by default
make install-tests-format

# Remove an installed target explicitly
make uninstall-debian
make uninstall-secureblue
```

Recipes use `install(1)` and strip `.pl`/`.bash`/`.ksh`/`.sh` when placing shell scripts in `${DESTDIR}${BINDIR}`. Windows scripts remain in `windows/` and are not installed by the POSIX targets. Developer validators and formatters are installed only with `make install-tests-format`, under `${DESTDIR}${TESTS_FORMAT_DIR}` (default `${PREFIX}/libexec/scripts`); set `TESTS_FORMAT_LINKS=1` to add compatibility symlinks in `BINDIR`. `make all` no longer installs them.

## Windows installation

On Windows 10 and Windows 11, `windows\install-windows.bat` is a single per-user entry
point for every public Perl program listed in `perl/programs.txt` (currently
`normalize-files` and `ssh-menu`) and every PowerShell script in `windows/`
and the formatter `windows/test-format/psfmt.ps1` (installed as `psfmt`). Its
own steps never require administrator rights, it never touches the system PATH
and never downloads arbitrary binaries; installing Strawberry Perl through
winget uses the vendor MSI and may prompt for elevation.

```
git clone <repository>
cd <repository>
windows\install-windows.bat
```

If you prefer not to assume Git, download and extract the repository, then run
`windows\install-windows.bat` from the extracted directory. It may be started from any
working directory; the installer resolves its files relative to its own path.

```
windows\install-windows.bat --dry-run
windows\install-windows.bat --help
```

After installation:

```
normalize-files --help
```

What it does:

- Uses an existing Strawberry Perl when one is already available (version
  5.10.1 or newer with the required core modules). Otherwise it installs
  Strawberry Perl through `winget` (`StrawberryPerl.StrawberryPerl`) with
  `--exact --accept-package-agreements --accept-source-agreements --silent`.
  `winget` must be present (App Installer); it is only used for external
  the Perl dependency. The installed `update-aiclis` command also uses winget.
- Installs by default under
  `%LOCALAPPDATA%\Programs\<repository-name>\` with `perl\`, `windows\`, `bin\`, a
  `perl-path.txt` recording the interpreter, a `VERSION` file and an
  `installed-files.txt` manifest.
- Creates one launcher per program (`normalize-files.cmd`, `ssh-menu.cmd`) that
  runs the matching `.pl` file with all arguments and preserves the Perl exit
  status.
- Creates launchers for the PowerShell scripts, forwarding arguments and exit
  status with PowerShell 7 (`pwsh`) when available, or Windows PowerShell
  otherwise. Installation checks their syntax without executing them and
  leaves the PowerShell execution policy unchanged.
- Adds only `...\bin` to the **user** PATH (`HKCU\Environment\Path`), in an
  idempotent way; re-running the installer updates the scripts and launchers
  without duplicating PATH entries or removing unknown files.

Validate the Windows installer and launchers from a Windows terminal:

```bat
tests-format\validate-windows-installer.bat
```

The validator accepts an optional repository directory and requires no POSIX
shell tools or Make.

Options:

| Option | Meaning |
| --- | --- |
| `--dry-run` | Show the plan (Perl, install root, scripts, launchers, PATH) and exit without changing anything. |
| `--no-path` | Do not modify the user PATH. |
| `--install-dir PATH` | Install to `PATH` instead of the per-user default. It is still a per-user install unless you explicitly choose otherwise. |
| `--help` | Show usage. |

The installer ends by validating itself: `perl -c` for every installed script,
`normalize-files --version`, `--help`, exit-status propagation (a bad option
must return 3) and a dry run over a temporary directory. It does not exercise
destructive operations on real files.

Already-open terminals and applications keep their old environment. Start a new
terminal (or sign out and back in) so they see the updated PATH; the launchers
also work through their full path. Perl is provided by Strawberry Perl and is
not removed automatically: other applications may depend on it.

`ssh-menu` needs an SSH client at runtime. Windows 10/11 usually provide
OpenSSH through *Settings → Apps → Optional features → OpenSSH Client*. The
installer does not install or verify it; `ssh-menu` reports a missing client
when it runs.

## Validation and formatting

`clang-format-all [ROOT_DIR]` (default `.`) prefers `clang-format` for
C11, C17 and C23, including GNU variants and the C18/C2x aliases. Otherwise
it prefers `knfmt`; if the preferred tool is absent, it uses the available
one and warns when modern C must fall back to `knfmt`.
Literal standards are detected in ancestor Makefiles, CMakeLists.txt,
meson.build and compile_commands.json, stopping at the repository boundary.
This does not evaluate build logic or resolve per-target compilation commands;
use `C_FORMAT_STANDARD=c23 clang-format-all path` to override detection.
The nearest directory with an explicit standard wins.

Every `clang-format` invocation uses the bundled Openbar configuration
(`tests-format/clang-format`, installed as `${BINDIR}/clang-format-all.yaml`),
ignoring project-local style files. This is the single source of the shared
style, maintained in this repository. The configuration targets
LLVM 23 and approximates OpenBSD style(9): tabs of eight columns, four-column
continuations, an 80-column limit, KNF braces and system/network/local include
groups. It is not byte-for-byte equivalent to `knfmt` (for example, declaration
alignment and comment wrapping can differ). `knfmt` keeps its own style handling;
the LLVM 23 configuration is not a portable knfmt configuration schema.

`clang-tidy-all [ROOT_DIR]` runs `clang-tidy` over C and C++ sources with
C23/C++23 defaults (`CLANG_TIDY_BUILD_DIR` supplies a compilation database).
Every invocation uses the bundled security-focused configuration
(`tests-format/clang-tidy`, installed as `${BINDIR}/clang-tidy-all.yaml`),
ignoring project-local `.clang-tidy` files. It is based on the `knfmt`
project's `.clang-tidy` and extended for maximum safety: all CERT rule sets,
the C++ Core Guidelines, concurrency and `clang-analyzer` families are enabled,
the safety-related `knfmt` suppressions are dropped, and findings are treated
as errors. The script examines every source file and exits non-zero when any
finding is reported.

`fourmolu-all [ROOT_DIR]` (default `.`) formats Haskell sources (`.hs`,
`.hsig` and `.hs-boot`) in place with `fourmolu`. Like `clang-format-all`, it
always forces a bundled style (`tests-format/fourmolu-all.yaml`, installed as
`${BINDIR}/fourmolu-all.yaml`) and ignores project-local
`fourmolu.yaml`/`.fourmolu.yaml` files, so the shared style cannot drift per
repository. The bundled style pins the Fourmolu 0.21 defaults explicitly;
edit that one file to evolve the shared style. If `fourmolu` is not present in
`PATH`, the script reports it and skips Haskell formatting.

`make check` runs agent-knowledge checks and contract tests, Python/Ruff,
shell, Perl, Makefile, permissions, correctness, and manual-page checks.
It checks formatting without rewriting sources or creating/removing caches.
Validators retain private diagnostic logs under `${TMPDIR:-/tmp}`. The
permission check skips Git-ignored artifacts and requires normalized modes;
run `make fix-permissions` once after cloning with a restrictive umask.
Missing optional tools are reported as skipped checks; a completed run does
not imply that those tools ran.

Scripts in `debian/`, `openbsd/`, `secureblue/`, `shell/`, and `tests-format/`
must not embed Python with `python3 -c` or a heredoc. Use native tools, core
Perl modules, or a standalone helper program. The Arti installer uses the
standalone `secureblue/arti-config.py` helper for TOML/unit rendering.

`make test` completes validation before starting isolated regression tests for
validators, installer failure handling, permissions, shell correctness, both
Perl programs, delivery transactions, release verification, and website
synchronization filters. Python test invocations
disable bytecode caches. This order also holds with `make -j`.

Use `make format` to apply available formatters explicitly. Each validator
accepts `--check` (the default), `--format`, and `--strict` before `[ROOT_DIR]`.
Formatting drift is reported with exit status 2 even when successfully fixed;
review the diff and rerun checks. Strict mode makes missing optional tools and
unloadable Perl modules fail validation; platform-inapplicable Makefile checks
remain explicit skips. Ruff is always required when Python sources exist.

The Makefile validator does not invoke make unless `--make-dry-run` is supplied.
Use that flag only for trusted Makefiles: parsing a Makefile can execute shell
commands even with `-n`. Likewise, `perl -c` executes compile-time blocks and
loads modules; these source validators assume trusted input.

The platform CI workflow runs analysis and isolated regression tests on Linux,
Windows, and an OpenBSD 7.8 VM. It installs analysis dependencies only in those
disposable runners; it never runs the administrative utilities against the
host. Actions are pinned to verified commit hashes. Windows/OpenBSD jobs need
their native environments; a local Linux pass does not establish their result.


## File permissions

File modes are derived from the actual content, as classified by `file(1)`:

| Content                                | Mode |
| -------------------------------------- | ---- |
| directories                            | 0755 |
| scripts (shell, Perl, Python, ...)     | 0755 |
| native executables (ELF)               | 0755 |
| text, config, documentation, data     | 0644 |
| Makefiles                              | 0755 |

A shebang (`#!`) is used as an additional signal for files that `file(1)` classifies as plain text. File extensions alone never make a file executable. Content is authoritative: a file that looks like a script (script content detected by `file(1)`, or a shebang) is treated as executable even if it was deliberately non-executable. To keep a script non-executable, avoid both a shebang and content that `file(1)` recognizes as a script; removing only the shebang is not sufficient.

- `make fix-permissions` (or `tests-format/fix-permissions.sh`): applies the policy above to the whole tree. `-n`/`--dry-run` shows what would change; `-v`/`--verbose` shows every decision; after fixing, the mode changes visible to git are shown with `git diff --summary`.
- `make check-permissions` (or `fix-permissions.sh --check`): read-only; exits 1 when any file has incorrect permissions.

Excluded from processing: `.git/` and all git-internal metadata, symlinks (never followed, never chmod'ed), sockets, FIFOs, devices and other special files. setuid/setgid/sticky bits on files are preserved. On filesystems that do not store the executable bit, git cannot detect mode changes (the script cannot detect this itself); inside a Git work tree, `fix-permissions.sh` warns when `core.fileMode` is `false`.

## Correctness auditing

`tests-format/validate-correctness.sh` performs static semantic and portability checks on the scripts, complementing the syntax/format validators. It verifies that the commands, options and paths used by each script are valid on the system the script targets:

- GNU-only options (`grep -P`, `sed -r`, `stat -c`, `date -d`, `find -printf/-quit`, `xargs --null`, `sort -V`, `mktemp` without a template, ...) are **ERRORs** in OpenBSD scripts and informational notes in Debian/SecureBlue ones.
- Linux-only commands/paths in the OpenBSD tree and OpenBSD-only commands/paths in the Linux trees.
- Shebang correctness per script family.
- Bashisms that do not exist in OpenBSD's ksh (pdksh): `local`, `declare`, `pipefail`, here-strings, process substitution, `$'...'`.
- For scripts that enable `pipefail`: pipelines whose consumer exits early (`| head`, `| grep -q`), which makes the producer die of SIGPIPE and the pipeline fail with 141.
- Unguarded destructive operations (`rm -rf`, `chmod -R`, `chown -R`, `find /`), `curl | sh`, unsafe temp files, TOCTOU patterns.
- For scripts targeting the host system, external commands are checked with `command -v` against per-platform allowlists.

Findings are classified as `ERROR`, `WARNING`, `INFO` or `UNVERIFIED`. The exit status is non-zero only when real `ERROR`s exist, unless `--strict` is given (then `WARNING`/`UNVERIFIED` also fail). Options: `--target openbsd|debian|secureblue|all|host`, `--verbose`, `--quiet`, `--format text|json`.

## SecureBlue shell aliases

`make install-shell` installs `shell/aliases.bash` and `shell/vi-mode.bash` to
`${BASH_CONF_DST_DIR}`.

- Default user: `SECUREBLUE_USER=david`
- Default path: `BASH_CONF_DST_DIR=/var/home/${SECUREBLUE_USER}/.bashrc.d`
- Immutable handling: removes the immutable bit (`chattr -i`) from the destination directory before install, then restores it (`chattr +i`) afterwards. The installed files themselves are not made immutable.

Examples:

```
# Install for default SecureBlue user
make install-shell

# Install for a custom user
make install-shell SECUREBLUE_USER=alice

# Override full destination directory
make install-shell BASH_CONF_DST_DIR=/var/home/alice/.bashrc.d
```
