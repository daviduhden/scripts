# Scripts

Shell and Perl utilities for system administration and maintenance across multiple operating systems.

## Structure

```
.
├── debian/        # Scripts for Debian-based distributions
├── openbsd/       # Scripts for OpenBSD systems
├── perl/          # Perl scripts (portable)
├── secureblue/    # Scripts for SecureBlue
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

Recipes use `install(1)` and strip `.pl`/`.bash`/`.ksh`/`.sh` when placing shell scripts in `${BINDIR}`.

## Validation and formatting

`make test` runs, in order:

- shell validation/formatting (`tests-format/validate-shell.sh`, incluye sintaxis sh/bash/ksh)
- perl validation/formatting (`tests-format/validate-perl.sh`)
- make validation/formatting (`tests-format/validate-make.sh`)
- permission validation (`tests-format/fix-permissions.sh --check`, read-only)
- correctness validation (`tests-format/validate-correctness.sh --target all`)
- regression tests for both new tools (`test-fix-permissions.sh`, `test-validate-correctness.sh`)
- ssh-menu parser regression test (`test-ssh-menu.pl`)

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
