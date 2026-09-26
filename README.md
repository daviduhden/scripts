# Scripts

Shell and Perl utilities for system administration and maintenance across multiple operating systems.

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

## Installation

Targets are system-specific; there is no generic "install all". Adjust `PREFIX`/`BINDIR` if you need a different path (defaults to `/usr/local/bin`).

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

# Tests/formatting scripts (for developers)
make install-tests-format
```

Recipes use `install(1)` and strip `.pl`/`.bash`/`.ksh`/`.sh` when placing shell scripts in `${BINDIR}`. Windows scripts remain in `windows/` and are not installed by the POSIX targets.

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
Run `perl tests-format/test-clang-format-all.pl` for isolated selection,
fallback, failure propagation and installed-style regression checks.

`fourmolu-all [ROOT_DIR]` (default `.`) formats Haskell sources (`.hs`,
`.hsig` and `.hs-boot`) in place with `fourmolu`. Like `clang-format-all`, it
always forces a bundled style (`tests-format/fourmolu-all.yaml`, installed as
`${BINDIR}/fourmolu-all.yaml`) and ignores project-local
`fourmolu.yaml`/`.fourmolu.yaml` files, so the shared style cannot drift per
repository. The bundled style pins the Fourmolu 0.20 defaults explicitly;
edit that one file to evolve the shared style. If `fourmolu` is not present in
`PATH`, the script reports it and skips Haskell formatting.
Run `perl tests-format/test-fourmolu-all.pl` for isolated discovery,
bundled-style, skip and failure-propagation regression checks.

`make test` runs, in order:

- shell validation/formatting (`tests-format/validate-shell.sh`, incluye sintaxis sh/bash/ksh)
- perl validation/formatting (`tests-format/validate-perl.sh`)
- make validation/formatting (`tests-format/validate-make.sh`)
- permission validation (`tests-format/fix-permissions.sh --check`, read-only)
- correctness validation (`tests-format/validate-correctness.sh --target all`)
- regression tests for both new tools (`test-fix-permissions.sh`, `test-validate-correctness.sh`)
- ssh-menu parser regression test (`test-ssh-menu.pl`)
- fourmolu-all discovery/format regression test (`test-fourmolu-all.pl`)

`make test` is a validation operation: it **never** modifies file permissions or file contents on its own (the format validators may rewrite formatting when the optional formatters are installed). Permission corrections are only applied by `make fix-permissions`.

## File permissions

File modes are derived from the actual content, as classified by `file(1)`:

| Content                                | Mode |
| -------------------------------------- | ---- |
| directories                            | 0755 |
| scripts (shell, Perl, Python, ...)     | 0755 |
| native executables (ELF)               | 0755 |
| text, config, documentation, Makefiles, data | 0644 |

A shebang (`#!`) is used as an additional signal for files that `file(1)` classifies as plain text. File extensions alone never make a file executable. Content is authoritative: a file that looks like a script (script content detected by `file(1)`, or a shebang) is treated as executable even if it was deliberately non-executable — to keep a script non-executable by design, give it no shebang.

- `make fix-permissions` (or `tests-format/fix-permissions.sh`): applies the policy above to the whole tree. `-n`/`--dry-run` shows what would change; `-v`/`--verbose` shows every decision; after fixing, the mode changes visible to git are shown with `git diff --summary`.
- `make check-permissions` (or `fix-permissions.sh --check`): read-only; exits 1 when any file has incorrect permissions.

Excluded from processing: `.git/` and all git-internal metadata, symlinks (never followed, never chmod'ed), sockets, FIFOs, devices and other special files. setuid/setgid/sticky bits on files are preserved. On filesystems that do not store the executable bit (or with `core.fileMode=false`), git cannot detect the mode changes; the script warns about this.

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

`make install-shell` installs `shell/aliases.bash` to `${BASH_CONF_DST_DIR}/aliases.bash`.

- Default user: `SECUREBLUE_USER=david`
- Default path: `BASH_CONF_DST_DIR=/var/home/${SECUREBLUE_USER}/.bashrc.d`
- Immutable handling: removes immutable bit (`chattr -i`) on directory/file before install, then restores it (`chattr +i`) afterwards.

Examples:

```
# Install for default SecureBlue user
make install-shell

# Install for a custom user
make install-shell SECUREBLUE_USER=alice

# Override full destination directory
make install-shell BASH_CONF_DST_DIR=/var/home/alice/.bashrc.d
```
