# OpenBSD scripts

These helpers target OpenBSD and use its base `ksh` and native tools. Install
from the repository root with `make install-openbsd`; installed command names
omit `.ksh`. System upgrades, log cleanup, and deployment changes need the
appropriate root permissions. User history cleanup uses the current user's data.

| Script | Purpose and usage |
| --- | --- |
| [ai-purge-history.ksh](ai-purge-history.ksh) | Deletes Codex and Copilot sessions and project-local Swival history/state; preserves configuration and credentials. Crush data is preserved unless `--include-crush-data` is given. Supports `--dry-run`/`-n` or `DRY_RUN=1`. OpenCode is not handled on OpenBSD. |
| [clean-logs.ksh](clean-logs.ksh) | Removes `.gz` logs under `/var/log` and `.old` files older than 7 days in a bounded set of system directories. Use `--dry-run` to preview; real deletion requires `--force`. |
| [sudo-wrapper.ksh](sudo-wrapper.ksh) | Routes `sudo` to `doas` and handles `visudo` and `sudoedit`. The install target creates matching symlinks; configure `doas` permissions separately. |
| [sync-website.ksh](sync-website.ksh) | Synchronizes the configured website from GitHub through `gh`, Git, or a ZIP fallback, fixes permissions, and restarts its service. |
| [sysupgrade-current.ksh](sysupgrade-current.ksh) | Upgrades to an OpenBSD snapshot and schedules post-upgrade tasks through `/upgrade.site` and `/etc/rc.firsttime`, including configuration maintenance, `dbupdate` system databases, package upgrades, and system reporting. |
| [update-crush.ksh](update-crush.ksh) | Installs the latest OpenBSD Crush binary after checksum verification, keeps a timestamped backup of the previous binary, and configures DeepSeek for the specified user. Usage: `update-crush.ksh [USER]`; the default user is root. |

Example from the repository root:

```sh
ksh openbsd/clean-logs.ksh --dry-run
```

Inspect deployment settings before running `sync-website.ksh`. For history
cleanup, `SWIVAL_PROJECT_HOME` selects the project whose `.swival` state is
removed. The upgrade helper targets snapshots rather than stable releases.

The website synchronizer filters known repository-only documentation, Git
metadata, agent instructions, development settings, tests, caches, and editor
backups from staged source and the public document root. It removes these known
paths from earlier deployments while preserving the active `.sync.lock` and
public site assets. Test changes with temporary trees; never use the live
document root for validation.

## Website publication modes

`sync-website.ksh` keeps its compatible in-place copy mode by default. Its
mutex now lives beside the configured document root as `.<docroot>.sync.lock`,
outside the public tree. Locks are never stolen by PID: after an abnormal exit
such as SIGKILL, an administrator must verify that no deployment is active
before removing the lock. Normal exits and handled signals release only this
run's PID file and empty lock directory; INT and TERM terminate the run.

`--check-atomic` checks whether the document root is an existing symlink to a
directory. After configuring the web server and that symlink, `--atomic`
stages a sibling release, filters private files, sets ownership and modes,
and replaces the document-root symlink atomically through base Perl
`rename` (OpenBSD `mv` has no `-h` or `-T` option).
Post-publication failure restores the previous link and attempts to restart
the restored service. Previous releases are retained for operator-managed
recovery and pruning. The same-filesystem parent directory must be controlled
by the administrator. `--check-atomic` only checks the filesystem prerequisite;
it cannot prove that the web server permits symlinks or serves the intended
virtual host. Validate that server configuration before enabling this mode.

A legacy `.sync.lock` inside the document root also blocks synchronization.
Before upgrading the locking scheme, verify that no old deployment is active
and remove its stale lock explicitly; the new script never removes it.
