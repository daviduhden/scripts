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
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, OpenCode, and project-local Swival history/state while retaining configuration and credentials. Crush data is preserved unless `--include-crush-data` is given. Supports `--dry-run`/`-n` or `DRY_RUN=1`. |
| [down-music.bash](down-music.bash) | Downloads YouTube audio with `yt-dlp`, converts it to OGG Vorbis with FFmpeg, and normalizes the output filename. Takes a video URL. |
| [install-arti-service.bash](install-arti-service.bash) | Installs and starts the Arti systemd user service, creates XDG directories and configuration, and optionally enables the socat proxy. |
| [install-openrsync.bash](install-openrsync.bash) | Builds openrsync from its upstream master branch and installs it to `/usr/local`, using Homebrew build dependencies. |
| [install-signify.bash](install-signify.bash) | Builds and installs portable OpenBSD signify, using Homebrew build dependencies. |
| [postinstall.bash](postinstall.bash) | Runs an interactive sequence of `ujust` post-install tasks, defers reboot-related steps, and records a log in the user's home directory. Non-interactive input requires `--yes`. |
| [setup-clamav.bash](setup-clamav.bash) | Configures ClamAV updates, on-access scanning, periodic scans, SELinux contexts, and permissions. Requires root and re-executes through `run0`. |
| [sudo-wrapper.bash](sudo-wrapper.bash) | Routes `sudo` and `visudo` through `run0`, and `sudoedit` through `run0edit`; installed symlinks select the matching behavior. |
| [sync-gh-repos.bash](sync-gh-repos.bash) | Clones or refreshes a GitHub user's repositories over SSH, preserving existing working-tree contents while replacing Git metadata. Uses authenticated `gh`; accepts `OWNER`, `BASE_DIR`, and `--non-interactive`. |
| [sysupgrade.bash](sysupgrade.bash) | Maintains the rpm-ostree image, firmware, Homebrew, Flatpak, storage, and system diagnostics. Homebrew uplift also unlinks system-shadowing formulae and relinks `ffmpeg-full`/`imagemagick-full` before cleanup. Scrub runs by default; full btrfs balance/defrag is opt-in with `BTRFS_MAINTENANCE=1`, and a lock prevents concurrent runs. |
| [update-arti-oniux.bash](update-arti-oniux.bash) | Builds and installs Arti and oniux with Rust/Cargo, manages OpenSSL dependencies, and patches binary library paths. |
| [update-krohnkite.bash](update-krohnkite.bash) | Builds the Krohnkite KWin package and installs or updates it with `kpackagetool6`. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Go-based Tor transport and installs it into `/usr/local/bin`. |
| [update-perl-modules.bash](update-perl-modules.bash) | Updates the Perl distributions in the user's local::lib (default `$HOME/perl5`) with `cpan-outdated` and `cpanm`, excluding dual-life core modules unless `--include-core` is given. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds XD and installs its systemd user service and XDG data directory; supports `--skip-service-and-user-setup`. |
| [update-xerj.bash](update-xerj.bash) | Installs/updates the SHA-256-verified static musl xerj release in `~/.local/bin`; optional `--codex`, `--crush`, and `--opencode` register its stdio MCP server. No elevation or service changes. |

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

## xerj

Requires `curl`, Perl with core `JSON::PP`/`Archive::Tar`, `sha256sum`, and
standard GNU utilities.
Supports x86_64 and aarch64. Run as your desktop user:

```bash
bash secureblue/update-xerj.bash
bash secureblue/update-xerj.bash --codex --crush --opencode
bash secureblue/update-xerj.bash --version v1.0.0-rc.100 --opencode
```

Without client flags, only the binary is installed. Re-running downloads and
verifies the requested release again. `--version TAG` pins a release; otherwise
the latest GitHub release is used. `--url URL` selects the ES-compatible node
endpoint (default `http://127.0.0.1:9200`). Add `~/.local/bin` to your PATH if
needed; MCP registrations use the absolute binary path.

Codex must already be installed when selected: registration uses `codex mcp
add` and respects `CODEX_HOME`. Crush uses a managed block in
`${XDG_CONFIG_HOME:-~/.config}/crush/crushrc` (current Bash config format).
OpenCode merges `mcp.xerj` into `opencode/opencode.json` under the same config
root. Existing JSONC configurations are refused for manual merging; JSON must
be a valid object. Shared configurations are backed up before modification.
Project settings and environment overrides can take precedence over these
global registrations. The scripts do not install the clients.

MCP does not start the engine. In a separate terminal, start a local authenticated
node (no service is installed):

```bash
mkdir -p "$HOME/.xerj/data"
"$HOME/.local/bin/xerj" --bind 127.0.0.1 --data-dir "$HOME/.xerj/data"
```

Before launching a configured client, supply the generated key in that client's
environment if automatic local key discovery does not find this data directory:

```bash
export XERJ_AUTH="ApiKey $(cat "$HOME/.xerj/data/admin.key")"
codex  # or crush / opencode
```

Restart existing clients after registration. For a remote endpoint, supply
`XERJ_AUTH` explicitly through the client environment. No key is written by the
updater. Sources: [installation](https://xerj.org/docs/install),
[MCP and authentication](https://xerj.org/docs/cli#mcp),
[OpenCode MCP](https://opencode.ai/docs/mcp-servers/),
[Crush configuration](https://github.com/charmbracelet/crush/blob/main/docs/config/README.md),
and [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp).

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

The xerj updater publishes through a unique same-directory temporary file,
so concurrent invocations cannot share an intermediate executable. Concurrent
successful updates may still select different releases; the last publication
wins. Each published binary has passed its own checksum and archive checks.

The Arti/oniux updater's last-resort Rust bootstrap uses the native rustup
installer pinned to 1.29.3, checked against its published SHA-256. Set
`RUSTUP_VERSION` to another reviewed release if needed. Existing toolchains
and Homebrew remain preferred. The installer and checksum share the official
HTTPS origin; the checksum is not an independent signature. Source builds still
trust the selected upstream Git tags and Cargo lockfiles.
