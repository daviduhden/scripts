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
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, OpenCode, Crush, and project-local Swival history/state while retaining configuration and credentials. |
| [clean-logs.bash](clean-logs.bash) | Deletes compressed logs under `/var/log` and `.old` files on the root file system; supports `--dry-run` or `DRY_RUN=1`. |
| [enable-tor-transport.bash](enable-tor-transport.bash) | Installs Tor transport support and rewrites APT sources to use it, keeping timestamped source backups. |
| [install-hardened-malloc.bash](install-hardened-malloc.bash) | Builds GrapheneOS hardened_malloc on Debian 13 and configures global preloading; supports amd64 and arm64. |
| [sync-website.bash](sync-website.bash) | Synchronizes a deployed website from GitHub, using `gh`, Git, or a ZIP fallback; applies permissions and restarts the configured service. |
| [sysupgrade.bash](sysupgrade.bash) | Updates APT packages, runs full-upgrade and cleanup, handles service maintenance, and collects system information. |
| [update-argon-one-v3.bash](update-argon-one-v3.bash) | Updates Argon One V3 EEPROM and fan/power-button scripts; supports reboot options. |
| [update-btop.bash](update-btop.bash) | Builds and installs the latest btop++ release and its build dependencies. |
| [update-fastfetch.bash](update-fastfetch.bash) | Downloads the latest Fastfetch Debian package and installs it through APT. |
| [update-golang.bash](update-golang.bash) | Installs the latest stable Go from official tarballs into `/usr/local/go` and updates the system PATH. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Tor transport with Go and Make and installs it into `/usr/local/bin`. |
| [update-monero.bash](update-monero.bash) | Updates Monero CLI binaries, configures `monerod`, and optionally builds and configures monero-lws. The LWS account is auto-detected (`monero-lws` if present, else the monerod user); override with `LWS_USER`/`LWS_GROUP`. |
| [update-msedit.bash](update-msedit.bash) | Installs or updates Microsoft Edit from precompiled GitHub release binaries. |
| [update-openrsync.bash](update-openrsync.bash) | Builds and installs openrsync, installing build dependencies through APT. |
| [update-signify.bash](update-signify.bash) | Builds and installs the portable OpenBSD signify utility. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds and installs XD and configures its service; `--skip-service-and-user-setup` skips that setup. |

Examples from the repository root:

```bash
bash debian/clean-logs.bash --dry-run
bash debian/update-monero.bash --help
bash debian/update-argon-one-v3.bash --help
```

For website deployment, inspect the repository, destination, and service settings
before running the synchronization script: it replaces deployment contents.
Run history cleanup as the user whose data should be removed; set
`SWIVAL_PROJECT_HOME` to select a different project.
