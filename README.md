# Scripts

Shell and Perl utilities for system administration and maintenance across multiple operating systems.

## Structure

```
.
├── debian/        # Scripts for Debian-based distributions
├── shell/         # Shell helpers for interactive shells
├── openbsd/       # Scripts for OpenBSD systems
├── perl/          # Perl scripts (portable)
└── secureblue/    # Scripts for Secureblue (Fedora Atomic/rpm-ostree)
```

## Installation

Targets are system-specific; there is no generic "install all". Adjust `PREFIX`/`BINDIR` if you need a different path (defaults to `/usr/local/bin`).

```
# Debian
make install-debian

# OpenBSD
make install-openbsd

# Secureblue
make install-secureblue

# Shell helpers (install to /etc/profile.d)
make install-shell

# Perl
make install-perl
```

Recipes use `install(1)` and strip `.pl`/`.bash`/`.zsh`/`.ksh` when placing shell scripts in `${BINDIR}`.
