# Scripts

A collection of shell scripts for system administration and maintenance across multiple operating systems: Debian-based Linux distributions, OpenBSD, POSIX-compliant systems, and Secureblue (Fedora Atomic).

## Structure

```
.
├── debian/        # Scripts for Debian-based distributions
├── openbsd/       # Scripts for OpenBSD systems
├── posix/         # POSIX-compliant scripts (portable)
└── secureblue/    # Scripts for Secureblue (Fedora Atomic/rpm-ostree)
```

## Debian Scripts

Scripts designed for Debian-based distributions (Debian, Ubuntu, Devuan, and derivatives).

| Script | Description |
|--------|-------------|
| `add-i2pd-repo.bash` | Adds the Purple I2P APT repository, installs i2pd, and enables the service. Supports systemd, SysV-init, OpenRC, runit, and GNU Shepherd. |
| `add-tor-repo.bash` | Adds the official Tor Project APT repository, installs Tor, and enables the service. Supports multiple init systems. |
| `clean-logs.bash` | Removes old compressed log files (`*.gz`) and backup files (`*.old`). Supports dry-run mode. |
| `sync-website.bash` | Synchronizes a website repository from Git, sets proper permissions, and restarts Apache. |
| `update-fastfetch.bash` | Automatically updates [fastfetch](https://github.com/fastfetch-cli/fastfetch) to the latest version from GitHub releases. |
| `update-golang.bash` | Installs or updates Go to the latest stable version from official tarballs. |
| `update-monero.bash` | Installs or updates Monero CLI tools to the latest version, configures the systemd service, and creates a basic configuration. |

## OpenBSD Scripts

Scripts designed specifically for OpenBSD systems using ksh.

| Script | Description |
|--------|-------------|
| `apply-sysclean.ksh` | Automates cleanup based on sysclean(8) output. Removes obsolete files, users, and groups. Supports dry-run mode. |
| `clean-logs.ksh` | Removes obsolete files based on sysclean output. |
| `sudo-wrapper.ksh` | Compatibility shim that redirects `sudo` calls to `doas`. Can also be symlinked as `visudo` or `sudoedit`. |
| `sync-website.ksh` | Synchronizes a website repository from Git, sets permissions, and restarts httpd. |
| `sysclean/` | Contains the sysclean utility source for OpenBSD. |

## POSIX Scripts

Portable scripts that work across POSIX-compliant systems.

| Script | Description |
|--------|-------------|
| `global-vi-mode.sh` | Enables vi-style line editing for bash, zsh, and ksh. Intended for `/etc/profile.d/`. |
| `setup-gpg.sh` | Comprehensive GnuPG installation and key generation script. Supports PQC (post-quantum cryptography) when available. Works on Linux (various distros), macOS, and BSD. |
| `gpg-conf/` | GnuPG configuration files to be installed in `~/.gnupg/`. |

### GnuPG Setup Script Features

The `setup-gpg.sh` script supports:

- **Multiple platforms**: Linux (Debian, Ubuntu, Fedora, Arch, Alpine, Void, Gentoo, NixOS, GNU Guix, and more), macOS, FreeBSD, OpenBSD, NetBSD, ChromeOS, and Termux.
- **Post-quantum cryptography (PQC)**: Generates ECC+Kyber keys when GnuPG 2.5+ is available.
- **Official GnuPG repository**: On Debian/Ubuntu/Devuan, can install from the official GnuPG upstream repository.
- **Automatic key upload**: Uploads generated keys to keys.openpgp.org.

Options:
- `--no-pqc`: Skip PQC key generation
- `--pqc-only`: Generate only PQC keys
- `--install-only`: Only install GnuPG, don't generate keys
- `--keygen-only`: Only generate keys, don't install GnuPG
- `--name NAME`: Set the name for the key UID
- `--email EMAIL`: Set the email for the key UID
- `--gnupg-branch stable|devel`: Force stable or development branch

## Secureblue Scripts

Scripts for [Secureblue](https://github.com/secureblue/secureblue) and Fedora Atomic (rpm-ostree based) systems.

| Script | Description |
|--------|-------------|
| `sysupgrade.bash` | Full non-interactive system maintenance: rpm-ostree, firmware, Homebrew, Flatpak, and filesystem maintenance. Collects debug info and uploads to fpaste. |
| `luks-ext4-to-btrfs.bash` | Interactive helper to convert an ext4 filesystem inside LUKS to Btrfs in-place. |
| `sudo-wrapper.bash` | Compatibility shim that redirects `sudo` calls to `run0`. Can also be symlinked as `visudo` or `sudoedit`. |
| `brew/gnupg25.rb` | Homebrew formula for GnuPG 2.5.x (development branch with PQC/Kyber support). |

### Sysupgrade Script Features

The `sysupgrade.bash` script performs:

1. **System image update**: rpm-ostree update/upgrade/cleanup
2. **Firmware update**: fwupdmgr refresh and update
3. **Homebrew update**: brew update/upgrade/cleanup
4. **Flatpak update**: System and per-user Flatpak repair and update
5. **Filesystem maintenance**: btrfs scrub/balance/defrag and ext4 defragmentation
6. **Debug collection**: Gathers system info and uploads to fpaste

## Requirements

Scripts require root privileges for most operations. They will attempt to use `sudo`, `doas`, or `run0` for privilege escalation as appropriate.

### Platform-specific requirements:

- **Debian scripts**: `curl`, `gpg`, system package manager (`apt-get` or `apt`)
- **OpenBSD scripts**: Standard OpenBSD tools, `doas`
- **Secureblue scripts**: `run0`, `rpm-ostree`, optionally `brew`, `flatpak`, `fwupdmgr`

## Usage

1. Clone the repository
2. Make scripts executable: `chmod +x script-name.sh`
3. Run with appropriate privileges

Example:
```bash
# Update Go to the latest version on Debian
sudo ./debian/update-golang.bash

# Run sysclean cleanup on OpenBSD (dry-run first)
doas ./openbsd/apply-sysclean.ksh --dry-run

# Full system maintenance on Secureblue
./secureblue/sysupgrade.bash

# Install GnuPG with PQC support
./posix/setup-gpg.sh
```

## License

ISC License. See [LICENSE](LICENSE) for details.

Copyright (c) 2025 David Uhden Collado
