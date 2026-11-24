# SecureBlue scripts

Bash helpers for SecureBlue's rpm-ostree environment, user applications, and
services. Install from the repository root with `make install-secureblue`;
installed names omit `.bash`. Build helpers use Homebrew or other dependencies
specified in each script. Scripts whose entire operation needs root re-exec
themselves through `run0`; scripts that only elevate final installation steps
use `run0` for those commands. User services and desktop configuration run in
the target user's session.

| Script | Purpose |
| --- | --- |
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, Claude Code, OpenCode, and project-local Swival history/state while retaining configuration and credentials. Crush data is preserved unless `--include-crush-data` is given. Supports `--dry-run`/`-n` or `DRY_RUN=1`. |
| [down-music.bash](down-music.bash) | Downloads YouTube audio with `yt-dlp`, converts it to OGG Vorbis with FFmpeg, and normalizes the output filename. Takes a video URL. |
| [install-arti-service.bash](install-arti-service.bash) | Installs and starts the Arti systemd user service, creates XDG directories and configuration, and optionally enables the socat proxy. |
| [install-openrsync.bash](install-openrsync.bash) | Builds openrsync from its upstream master branch and installs it to `/usr/local`, using Homebrew build dependencies. |
| [install-signify.bash](install-signify.bash) | Builds and installs portable OpenBSD signify, using Homebrew build dependencies. |
| [postinstall.bash](postinstall.bash) | Runs an interactive sequence of `ujust` post-install tasks, defers reboot-related steps, and records a log in the user's home directory. Non-interactive input requires `--yes`. |
| [setup-clamav.bash](setup-clamav.bash) | Configures ClamAV updates, on-access scanning, periodic scans, SELinux contexts, and permissions. Requires root and re-executes through `run0`. |
| [sudo-wrapper.bash](sudo-wrapper.bash) | Routes `sudo` and `visudo` through `run0`, and `sudoedit` through `run0edit`; installed symlinks select the matching behavior. |
| [sync-gh-repos.bash](sync-gh-repos.bash) | Clones or refreshes a GitHub user's repositories over SSH. Retains old Git metadata and working files in a private sibling backup. Uses authenticated `gh`; accepts `OWNER`, `BASE_DIR`, and `--non-interactive`. |
| [sysupgrade.bash](sysupgrade.bash) | Maintains the rpm-ostree image, firmware, Homebrew, Flatpak, storage, and system diagnostics. Homebrew uplift also unlinks system-shadowing formulae and relinks `ffmpeg-full`/`imagemagick-full` before cleanup. Scrub runs by default; full btrfs balance/defrag is opt-in with `BTRFS_MAINTENANCE=1`, and a lock prevents concurrent runs. |
| [update-ai-clis.bash](update-ai-clis.bash) | Installs or updates selected coding agents using official Homebrew packages. See the [distribution and PATH details](../docs/update-ai-clis.md). |
| [update-arti-oniux.bash](update-arti-oniux.bash) | Builds and installs Arti and oniux with Rust/Cargo, manages OpenSSL dependencies, and patches binary library paths. |
| [update-krohnkite.bash](update-krohnkite.bash) | Builds the Krohnkite KWin package and installs or updates it with `kpackagetool6`. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Go-based Tor transport and installs it into `/usr/local/bin`. |
| [update-perl-modules.bash](update-perl-modules.bash) | Updates the Perl distributions in the user's local::lib (default `$HOME/perl5`) with `cpan-outdated` and `cpanm`, excluding dual-life core modules unless `--include-core` is given. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds XD and installs its systemd user service and XDG data directory; supports `--skip-service-and-user-setup`. |
| [update-xerj.bash](update-xerj.bash) | Installs the verified static xerj release in `~/.local/bin` and registers its stdio MCP server with selected installed agents. |

Claude Code cleanup removes local prompt history and conversation and subagent
transcripts under `CLAUDE_CONFIG_DIR` (default `~/.claude`). Settings, login
credentials, and project auto memory are preserved. See the
[Claude directory reference](https://code.claude.com/docs/en/claude-directory).

Examples from the repository root:

```bash
bash secureblue/down-music.bash 'YOUTUBE_VIDEO_URL'
bash secureblue/sysupgrade.bash --help
bash secureblue/sync-gh-repos.bash --help
```

Review `OWNER` and `BASE_DIR` before repository synchronization; existing
repositories have their Git metadata replaced. Run history cleanup as the
intended user and set `SWIVAL_PROJECT_HOME` to choose a project.

Bundled service templates are documented in
[systemd/README.md](systemd/README.md). Interactive Bash helpers are documented
in [../shell/README.md](../shell/README.md). `update-xerj` uses the auxiliary
`release-verify.pl` and `xerj-config.pl` helpers installed beside the command
without their source extensions; they are not user-facing commands.

## AI CLI updates

Set up Homebrew using your SecureBlue configuration, then run
`update-ai-clis` as your desktop user. The updater uses the platform's
Homebrew dispatcher and its authorization policy. It discovers the Homebrew
prefix and works with the official Homebrew packages and Charm's official
tap. No base-image changes are required. See the [agent matrix and PATH
behavior](../docs/update-ai-clis.md).

System maintenance stores its audit and information reports in the private
root-owned directory `/var/log/scripts-sysupgrade`.

## xerj

Run `update-xerj` to install xerj in `~/.local/bin` and configure compatible
installed clients. Run `update-xerj codex claude` to select clients or
`update-xerj --binary-only` to install only xerj. The updater verifies and
checks the staged executable before publication and runs as your desktop user.
See the [xerj configuration guide](../docs/update-xerj.md).

## Arti installation transactions

`install-arti-service.bash` uses the standalone `arti-config.pl` helper
(core Perl modules) and `systemd-analyze`. The helper is installed with the
SecureBlue target; no Python or inline Perl source is embedded in the shell
script.
It preserves an existing `arti.toml` by default. Select
`--replace-config` to replace it with the upstream example; the old file is
retained in a unique `arti.toml.bak.*` backup. Downloads are prepared in a
private staging directory, TOML syntax and the rendered service unit are
validated before publication, and activation failures restore the prior
configuration and unit. TOML parsing checks syntax, not every Arti setting.
The example still comes from the installed version's tag, with a fallback to
upstream main; TLS authenticates the origin but no independent signature is
available in this workflow.

XDG paths are quoted for systemd, including spaces, dollar signs and literal
percent signs. Control characters are refused; the optional socat bridge
also refuses commas in socket paths because socat treats them as delimiters.
The optional bridge remains a separate best-effort installation.

The xerj updater serializes runs through the user's installation directory
and verifies the active version after MCP registration. It publishes through
a unique same-directory temporary file,
so concurrent invocations cannot share an intermediate executable. Concurrent
successful updates may still select different releases; the last publication
wins. Each published binary has passed its own checksum and archive checks.

The Arti/oniux updater's last-resort Rust bootstrap uses the native rustup
installer pinned to 1.29.3, checked against its published SHA-256. Set
`RUSTUP_VERSION` to another reviewed release if needed. Existing toolchains
and Homebrew remain preferred. The installer and checksum share the official
HTTPS origin; the checksum is not an independent signature. Source builds still
trust the selected upstream Git tags and Cargo lockfiles.
