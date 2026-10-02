# OpenBSD scripts

These helpers target OpenBSD and use its base `ksh` and native tools. Install
from the repository root with `make install-openbsd`; installed command names
omit `.ksh`. System upgrades, log cleanup, and deployment changes need the
appropriate root permissions. User history cleanup uses the current user's data.

| Script | Purpose and usage |
| --- | --- |
| [ai-purge-history.ksh](ai-purge-history.ksh) | Deletes Codex and Copilot sessions, Crush data, and project-local Swival history/state; preserves configuration and credentials. OpenCode is not handled on OpenBSD. |
| [clean-logs.ksh](clean-logs.ksh) | Removes `.gz` logs under `/var/log` and `.old` files on the root file system. Use `--dry-run`, `-n`, or `DRY_RUN=1` to preview. |
| [sudo-wrapper.ksh](sudo-wrapper.ksh) | Routes `sudo` to `doas` and handles `visudo` and `sudoedit`. The install target creates matching symlinks; configure `doas` permissions separately. |
| [sync-website.ksh](sync-website.ksh) | Synchronizes the configured website from GitHub through `gh`, Git, or a ZIP fallback, fixes permissions, and restarts its service. |
| [sysupgrade-current.ksh](sysupgrade-current.ksh) | Upgrades to an OpenBSD snapshot and schedules post-upgrade tasks through `/upgrade.site` and `/etc/rc.firsttime`, including configuration/package maintenance and system reporting. |
| [update-crush.ksh](update-crush.ksh) | Installs the latest OpenBSD Crush binary after checksum verification and configures DeepSeek for the specified user. Usage: `update-crush.ksh [USER]`; the default user is root. |

Example from the repository root:

```sh
ksh openbsd/clean-logs.ksh --dry-run
```

Inspect deployment settings before running `sync-website.ksh`. For history
cleanup, `SWIVAL_PROJECT_HOME` selects the project whose `.swival` state is
removed. The upgrade helper targets snapshots rather than stable releases.
