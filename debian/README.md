# Debian scripts

Bash administration helpers for Debian-based systems. Support varies by script;
repository setup scripts validate the distribution, release, and architecture.
System installation and maintenance steps require root access or the elevation
method used by the script. Downloads and package installation require network
access.

From the repository root, install with `make install-debian`. Installed commands
omit the `.bash` extension and default to `/usr/local/bin`. To run a source file,
use `bash debian/<script>.bash` with the privileges required by that script.

| Script | Purpose |
| --- | --- |
| [add-gh-cli-repo.bash](add-gh-cli-repo.bash) | Adds the official GitHub CLI APT repository with a deb822 source and keyring, then installs `gh`. |
| [add-i2pd-repo.bash](add-i2pd-repo.bash) | Adds the Purple I2P APT repository, installs `i2pd`, and starts its service on supported init systems. |
| [add-lynis-repo.bash](add-lynis-repo.bash) | Adds the CISOfy APT repository and installs Lynis. |
| [add-tor-repo.bash](add-tor-repo.bash) | Adds the Tor Project APT repository, installs Tor, and configures its service. |
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, OpenCode, and project-local Swival history/state while retaining configuration and credentials. Crush data is preserved unless `--include-crush-data` is given. Supports `--dry-run`/`-n` or `DRY_RUN=1`. |
| [clean-logs.bash](clean-logs.bash) | Deletes compressed logs under `/var/log` and `.old` files older than 7 days in `/var/log`, `/var/tmp`, `/tmp` and `/etc`. Real deletion requires `--force`; `--older-than DAYS` changes the age. |
| [enable-tor-transport.bash](enable-tor-transport.bash) | Installs Tor transport support and rewrites APT sources to use it, keeping timestamped source backups. |
| [install-hardened-malloc.bash](install-hardened-malloc.bash) | Builds GrapheneOS hardened_malloc on Debian 13 and configures global preloading; supports amd64 and arm64. |
| [sync-website.bash](sync-website.bash) | Synchronizes a deployed website from GitHub, using `gh`, Git, or a ZIP fallback; applies permissions and restarts the configured service. |
| [sysupgrade.bash](sysupgrade.bash) | Updates APT packages, runs full-upgrade and cleanup, handles service maintenance, and collects system information. |
| [update-argon-one-v3.bash](update-argon-one-v3.bash) | Updates Argon One V3 EEPROM and fan/power-button scripts; supports reboot options. |
| [update-btop.bash](update-btop.bash) | Builds and installs the latest btop++ release and its build dependencies. |
| [update-fastfetch.bash](update-fastfetch.bash) | Downloads the latest Fastfetch Debian package and installs it through APT. |
| [update-golang.bash](update-golang.bash) | Installs the latest stable Go from official tarballs into `/usr/local/go` and updates the system PATH. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Tor transport with Go and Make and installs it into `/usr/local/bin`. |
| [update-monero.bash](update-monero.bash) | Updates Monero CLI binaries, configures `monerod`, and optionally builds and configures monero-lws. Verifies the signed hash list against the pinned binaryFate fingerprint and the upstream systemd unit against a pinned SHA-256. The LWS account is auto-detected (`monero-lws` if present, else the monerod user); override with `LWS_USER`/`LWS_GROUP`. Opens the firewall ports with nftables (`FIREWALL_TCP_PORTS`, default `18080 8443`). |
| [update-msedit.bash](update-msedit.bash) | Installs or updates Microsoft Edit from precompiled GitHub release binaries. |
| [update-openrsync.bash](update-openrsync.bash) | Builds and installs openrsync, installing build dependencies through APT. |
| [update-signify.bash](update-signify.bash) | Builds and installs the portable OpenBSD signify utility. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds and installs XD and configures its service; `--skip-service-and-user-setup` skips that setup. |
| [rpi-update-safe](rpi-update-safe) | Runs `rpi-update` without rebooting on Raspberry Pi 5, then validates and repairs the selected DTB and initramfs with backups. Requires root and can change firmware, modules, and boot files; it does not provide a complete updater rollback. |

Examples from the repository root:

```bash
bash debian/clean-logs.bash --dry-run
sudo bash debian/clean-logs.bash --force --older-than 7
bash debian/ai-purge-history.bash --dry-run
bash debian/update-monero.bash --help
bash debian/update-argon-one-v3.bash --help
```

For website deployment, inspect the repository, destination, and service settings
before running the synchronization script: it replaces deployment contents.
The script filters known repository-only documentation, Git metadata, agent
instructions, development settings, tests, caches, and editor backups from both
the staged source and the public destination. It removes these known paths from
older deployments while preserving the active `.sync.lock` and public site
assets. Validate filter changes only against temporary trees; do not run the
deployment script against a production document root as a test.
Run history cleanup as the user whose data should be removed; set
`SWIVAL_PROJECT_HOME` to select a different project.

## Website publication modes

`sync-website.bash` retains in-place copying by default. The deployment mutex
is now a sibling `.<docroot>.sync.lock`, outside the document root. It never
steals locks based solely on PID; after SIGKILL, verify that no deployment is
running before removing a stale lock. INT and TERM exit with 130 and 143 and
release only the owning run's lock.

`--check-atomic` checks whether the configured document root is an existing
symlink to a directory. Administrators can configure that symlink and verify
web-server symlink permissions before choosing `--atomic`. That mode stages
and filters a sibling release, prepares ownership and permissions, and
atomically replaces the public symlink using GNU `mv -T`. A subsequent failure
restores the previous link and attempts to restart the restored service.
Previous releases are retained for operator-managed recovery and pruning.
Keep the sibling parent directory administrator-controlled and on the same
filesystem. The check is structural; it does not validate the server's
virtual-host or symlink policy.

A legacy `.sync.lock` inside the document root also blocks synchronization.
Before upgrading the locking scheme, verify that no old deployment is active
and remove its stale lock explicitly; the new script never removes it.

## Release trust and recovery

`update-golang.bash` validates the exact release filename and SHA-256 against
`go.dev` JSON metadata. It prepares and checks a fresh tree before activation,
serializes updates with a sibling lock, and restores the previous tree if
activation fails or is interrupted. Old trees remain under
`/usr/local/.go-backup.*` for operator recovery/pruning. The lock fails closed;
inspect stale locks before removing them after forced termination.

`update-msedit.bash` requires the SHA-256 digest published in the exact GitHub
release asset metadata. It reads only one regular root `edit` entry and refuses
ambiguous/missing digest metadata. `update-btop.bash` extracts its GitHub
source-tarball fallback into a unique directory, rejecting links, special files,
duplicates, traversal and oversized archives. Go, msedit and btop use core Perl
modules and native tools rather than embedded Python. btop source authenticity
still trusts Git/HTTPS; no independent tag signature is verified.

Argon prepares and validates both installers before executing either. Script
execution now requires both `--eeprom-sha256 HASH` and
`--control-sha256 HASH`, or an explicit `--trust-upstream` decision. Environment
alternatives are `ARGON_EEPROM_SHA256` and `ARGON_CONTROL_SHA256`. Set
`ARGON_EEPROM_SCRIPT` and `ARGON_CONTROL_SCRIPT` to reviewed local regular files
to avoid downloads; the same digest requirements apply. Obtain reviewed hashes
through a trusted channel: calculating a hash from an unreviewed download does
not establish its authenticity. `--trust-upstream` preserves the upstream
bootstrap option but executes its unpinned contents as root. Reboot options are
unchanged. Never execute these utilities as a validation step.
