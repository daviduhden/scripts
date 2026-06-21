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
└── tests-format/  # Test scripts for validating formatting
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
make install-shell-secureblue

# fish shell config (~/.config/fish/conf.d with chattr -i/+i)
make install-shell-fish

# Same as install-shell-secureblue
make install-shell

# Perl
make install-perl

# Tests/formatting scripts (for developers)
make install-tests-format
```

Recipes use `install(1)` and strip `.pl`/`.bash`/`.ksh`/`.sh` when placing shell scripts in `${BINDIR}`.

## Validation and formatting

`make test` runs:

- shell validation/formatting (`tests-format/validate-shell.sh`, incluye sintaxis sh/bash/ksh/fish cuando estén disponibles)
- perl validation/formatting (`tests-format/validate-perl.sh`)
- make validation/formatting (`tests-format/validate-make.sh`)

## SecureBlue shell aliases

`make install-shell-secureblue` installs `shell/aliases.bash` to `${SECUREBLUE_BASHRCD_DIR}/aliases.bash`.

- Default user: `SECUREBLUE_USER=david`
- Default path: `SECUREBLUE_BASHRCD_DIR=/var/home/${SECUREBLUE_USER}/.bashrc.d`
- Immutable handling: removes immutable bit (`chattr -i`) on directory/file before install, then restores it (`chattr +i`) afterwards.

## fish shell config

`make install-shell-fish` installs the fish configuration into `${HOME}/.config/fish/conf.d`.

- Default destination: `${HOME}/.config/fish/conf.d`
- Override: `FISH_CONF_DST_DIR=/path/to/conf.d`
- Immutable handling: removes immutable bit (`chattr -i`) on destination directory/files before install, then restores it (`chattr +i`) afterwards.

Examples:

```
# Install fish config for the current user
make install-shell-fish

# Install fish config to a custom destination
make install-shell-fish FISH_CONF_DST_DIR=/var/home/alice/.config/fish/conf.d
```

Examples:

```
# Install for default SecureBlue user
make install-shell-secureblue

# Install for a custom user
make install-shell-secureblue SECUREBLUE_USER=alice

# Override full destination directory
make install-shell-secureblue SECUREBLUE_BASHRCD_DIR=/var/home/alice/.bashrc.d
```
