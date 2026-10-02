# SecureBlue scripts

Bash helpers for SecureBlue's rpm-ostree environment, user applications, and
services. Install from the repository root with `make install-secureblue`;
installed names omit `.bash`. Build helpers use Homebrew or other dependencies
specified in each script. Some final installation steps require elevation;
user services and desktop configuration run in the target user's session.

| Script | Purpose |
| --- | --- |
| [ai-purge-history.bash](ai-purge-history.bash) | Deletes Codex, Copilot, OpenCode, Crush, and project-local Swival history/state while retaining configuration and credentials. |
| [down-music.bash](down-music.bash) | Downloads YouTube audio with `yt-dlp`, converts it to OGG Vorbis with FFmpeg, and normalizes the output filename. Takes a video URL. |
| [install-arti-service.bash](install-arti-service.bash) | Installs and starts the Arti systemd user service, creates XDG directories and configuration, and optionally enables the socat proxy. |
| [install-openrsync.bash](install-openrsync.bash) | Builds openrsync from its upstream master branch and installs it to `/usr/local`, using Homebrew build dependencies. |
| [install-signify.bash](install-signify.bash) | Builds and installs portable OpenBSD signify, using Homebrew build dependencies. |
| [postinstall.bash](postinstall.bash) | Runs an interactive sequence of `ujust` post-install tasks, defers reboot-related steps, and records a log in the user's home directory. |
| [setup-clamav.bash](setup-clamav.bash) | Configures ClamAV updates, on-access scanning, periodic scans, SELinux contexts, and permissions. |
| [sudo-wrapper.bash](sudo-wrapper.bash) | Routes `sudo` and `visudo` through `run0`, and `sudoedit` through `run0edit`; installed symlinks select the matching behavior. |
| [sync-gh-repos.bash](sync-gh-repos.bash) | Clones or refreshes a GitHub user's repositories over SSH, preserving existing working-tree contents while replacing Git metadata. Uses authenticated `gh`; accepts `OWNER`, `BASE_DIR`, and `--non-interactive`. |
| [sysupgrade.bash](sysupgrade.bash) | Maintains the rpm-ostree image, firmware, Homebrew, Flatpak, storage, and system diagnostics. |
| [update-arti-oniux.bash](update-arti-oniux.bash) | Builds and installs Arti and oniux with Rust/Cargo, manages OpenSSL dependencies, and patches binary library paths. |
| [update-krohnkite.bash](update-krohnkite.bash) | Builds the Krohnkite KWin package and installs or updates it with `kpackagetool6`. |
| [update-lyrebird.bash](update-lyrebird.bash) | Builds the Lyrebird Go-based Tor transport and installs it into `/usr/local/bin`. |
| [update-xd-torrent.bash](update-xd-torrent.bash) | Builds XD and installs its systemd user service and XDG data directory; supports `--skip-service-and-user-setup`. |

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
in [../shell/README.md](../shell/README.md).
