# Scripts

Shell and Perl utilities for system administration and maintenance across multiple operating systems.

## Structure

```
.
├── debian/        # Scripts for Debian-based distributions
├── lib/           # Shared libraries for scripts
├── openbsd/       # Scripts for OpenBSD systems
├── perl/          # Perl scripts (portable)
├── secureblue/    # Scripts for SecureBlue (Fedora Atomic/rpm-ostree)
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

# Shell helpers (install to /etc/profile.d)
make install-shell

# Perl
make install-perl

# Tests/formatting scripts (for developers)
make install-tests-format
```

Recipes use `install(1)` and strip `.pl`/`.bash`/`.zsh`/`.ksh`/`.sh` when placing shell scripts in `${BINDIR}`.
