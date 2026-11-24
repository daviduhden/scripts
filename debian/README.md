# Debian scripts

Bash administration helpers for Debian-based systems. Support varies by script;
repository setup scripts validate the distribution, release, and architecture.
System installation and maintenance steps require root access. Scripts whose
entire operation needs root re-exec themselves through `sudo`; scripts that
elevate only individual steps use `sudo` for those commands. Downloads and
package installation require network access.

From the repository root, install with `make install-debian`. Installed commands
omit the `.bash` extension and default to `/usr/local/bin`. To run a source file,
use `bash debian/<script>.bash` as your normal user; global-root scripts request
elevation automatically.
The release updaters use the auxiliary `release-verify.pl` helper, and
`rpi-update-safe` uses `bootargs.pl`; both are installed beside the commands
without their source extension and are not intended to be called directly by
users.

| Script | Purpose |
| --- | --- |
| [add-gh-cli-repo.bash](add-gh-cli-repo.bash) | Adds the official GitHub CLI APT repository with a deb822 source and a fingerprint-checked keyring, then installs `gh`. |
| [add-i2pd-repo.bash](add-i2pd-repo.bash) | Adds the Purple I2P APT repository with a fingerprint-checked keyring, installs `i2pd`, and starts its service on supported init systems. |
| [add-lynis-repo.bash](add-lynis-repo.bash) | Adds the CISOfy APT repository with a fingerprint-checked keyring and installs Lynis. |
| [add-tor-repo.bash](add-tor-repo.bash) | Adds the Tor Project APT repository with a fingerprint-checked keyring, installs Tor, and configures its service. |
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, Claude Code, OpenCode, and project-local Swival history/state while retaining configuration and credentials. Crush data is preserved unless `--include-crush-data` is given. Supports `--dry-run`/`-n` or `DRY_RUN=1`. |
| [clean-logs.bash](clean-logs.bash) | Deletes compressed logs under `/var/log` and `.old` files older than 7 days in `/var/log`, `/var/tmp`, `/tmp` and `/etc`. Real deletion requires `--force`; `--older-than DAYS` changes the age. |
| [enable-tor-transport.bash](enable-tor-transport.bash) | Installs Tor transport support and rewrites APT sources to use it, keeping timestamped source backups. |
| [install-hardened-malloc.bash](install-hardened-malloc.bash) | Builds GrapheneOS hardened_malloc on Debian 13 and configures global preloading; supports amd64 and arm64. |
| [sync-website.bash](sync-website.bash) | Synchronizes a deployed website from GitHub, using `gh`, Git, or a ZIP fallback; applies permissions and restarts the configured service. |
| [sysupgrade.bash](sysupgrade.bash) | Updates APT packages, runs full-upgrade and cleanup, handles service maintenance, and collects system information. |
| [update-ai-clis.bash](update-ai-clis.bash) | Installs or updates selected coding agents. See the [distribution and PATH details](../docs/update-ai-clis.md). |
| [update-argon-one-v3.bash](update-argon-one-v3.bash) | Updates Argon One V3 EEPROM and fan/power-button scripts; supports reboot options. |
| [update-btop.bash](update-btop.bash) | Builds and stages btop++ as an unprivileged account in a disposable directory. Publishes selected outputs under `/usr/local`. |
| [update-fastfetch.bash](update-fastfetch.bash) | Verifies the latest Fastfetch package against the GitHub release digest and checks Debian package metadata before installing through APT. |
| [update-golang.bash](update-golang.bash) | Installs the latest stable Go from official tarballs into `/usr/local/go` and updates the system PATH. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Tor transport with Go and Make as an unprivileged account in a disposable directory. Publishes the binary in `/usr/local/bin`. |
| [update-monero.bash](update-monero.bash) | Updates Monero CLI binaries, configures `monerod`, and optionally builds and configures monero-lws. Verifies the signed hash list against the pinned binaryFate fingerprint and the upstream systemd unit against a pinned SHA-256. The LWS account is auto-detected (`monero-lws` if present, else the monerod user); override with `LWS_USER`/`LWS_GROUP`. Opens the firewall ports with nftables (`FIREWALL_TCP_PORTS`, default `18080 8443`). |
| [update-msedit.bash](update-msedit.bash) | Installs or updates Microsoft Edit from precompiled GitHub release binaries. |
| [update-openrsync.bash](update-openrsync.bash) | Builds and installs openrsync, installing build dependencies through APT. |
| [update-signify.bash](update-signify.bash) | Builds and installs the portable OpenBSD signify utility. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds XD as an unprivileged account and installs the system unit defined by this repository. The service runs as `xd`. `--skip-service-and-user-setup` skips service setup. |
| [update-xerj.bash](update-xerj.bash) | Installs verified upstream xerj assets through APT on Debian 13 or later. |
| [rpi-update-safe.bash](rpi-update-safe.bash) | Runs `rpi-update` without rebooting on Raspberry Pi 5, then validates and repairs the selected DTB and initramfs with backups. Requires root and can change firmware, modules, and boot files; it does not provide a complete updater rollback. |

Claude Code cleanup removes local prompt history and conversation and subagent
transcripts under `CLAUDE_CONFIG_DIR` (default `~/.claude`). Settings, login
credentials, and project auto memory are preserved. See the
[Claude directory reference](https://code.claude.com/docs/en/claude-directory).

Examples from the repository root:

```bash
bash debian/clean-logs.bash --dry-run
bash debian/clean-logs.bash --force --older-than 7
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

## System maintenance

System maintenance stores its reports in the private root-owned directory
`/var/log/scripts-sysupgrade`. Process summaries use executable names.

## AI CLI updates

Run `update-ai-clis codex claude` as your normal user. The updater uses
`sudo` for APT operations. It tracks the Debian candidates for its selected
download, metadata and verification tools. APT resolves the declared
dependencies of Crush and Claude Code.
Version discovery uses existing tools when available. An installation or
update refreshes Debian package metadata before installing its prerequisites.

OpenCode, Codex and Copilot use `~/.local/bin` launchers for releases under
`~/.local/share/scripts-ai-clis`. The updater queries Anthropic's signed
stable APT index in a temporary directory. Crush and Claude Code install under
`/usr/bin`. For a version managed by a different package channel, the
updater reports the existing path. See the [agent matrix and PATH
behavior](../docs/update-ai-clis.md).

## xerj

```bash
update-xerj
update-xerj codex claude
update-xerj --binary-only
update-xerj --help
```

The Debian updater supports amd64 and arm64. It verifies the published
SHA-256 checksum and inspects the Debian package metadata. If the package
requires a newer system C library, it uses the upstream verified static
musl binary in a locally built Debian package. This fallback uses Perl and
the bundled `release-verify` helper. APT manages installation
and dependencies. Both packages install `/usr/bin/xerj`. The
repository's `uninstall-debian` target removes the updater. Use APT to remove
the installed xerj package.

Run as your normal user. Installation requests elevation for system work
and client registration runs with your account. With no selectors, the
updater registers xerj with compatible installed clients. See the
[xerj configuration guide](../docs/update-xerj.md).

The upstream latest release can be a release candidate. Use `--version TAG`
to pin a release. `--verify-attestation` additionally requires an authenticated
GitHub CLI that supports `gh release verify-asset`. Under sudo it uses the
invoking user's GitHub CLI configuration. See the [xerj Debian packaging
documentation](https://github.com/xerj-org/xerj/blob/main/docs/PACKAGING_DEBIAN.md).

## Website publication modes

Both Git download methods and Git LFS run as the configured non-root
`GH_USER`. The configured `GH_HOST` and `REPO_SLUG` select the source.
Publication uses a separately captured, validated snapshot. The document
tree must be root-owned, contain only regular files and directories, and
deny write access to the web-service account. Keep application data that
requires web-service write access outside the static document tree.

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
modules and native tools rather than Python. btop source authenticity
still trusts Git/HTTPS; no independent tag signature is verified.

Argon prepares and validates both installers before executing either. Script
execution now requires both `--eeprom-sha256 HASH` and
`--control-sha256 HASH`, or an explicit `--trust-upstream` decision. Environment
alternatives are `ARGON_EEPROM_SHA256` and `ARGON_CONTROL_SHA256`. Set
`ARGON_EEPROM_SCRIPT` and `ARGON_CONTROL_SCRIPT` to reviewed local regular files
to avoid downloads; the same digest requirements apply. Obtain reviewed hashes
through a trusted channel: calculating a hash from an unreviewed download does
not establish its authenticity. Monero pins the binaryFate fingerprint and the
upstream `monerod.service` SHA-256; `BINARYFATE_FPR` and
`MONEROD_UNIT_SHA256` allow an explicitly reviewed rotation. `--trust-upstream` preserves the upstream
bootstrap option but executes its unpinned contents as root. Reboot options are
unchanged. Never execute these utilities as a validation step.
