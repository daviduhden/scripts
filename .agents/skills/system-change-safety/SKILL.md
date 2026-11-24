---
name: system-change-safety
description: >-
  Review or change privileged, destructive, deployment, service, firewall, or
  configuration-writing code in this repository. Use for root/elevation paths,
  rm/find deletion, /etc or /var writes, package installation, systemd or rc.d
  services, firewall rules, history purges, and website synchronization.
---

# System change safety

## When to use

- Editing a script that runs as root or elevates through `sudo`, `doas`, or
  `run0`.
- Changing deletion, permission, ownership, package, service, firewall,
  deployment, or configuration logic.
- Reviewing `clean-logs`, `sync-website`, `sysupgrade`, `update-*`,
  `install-*`, `ai-purge-history`, or `setup-clamav`.
- Adding a post-upgrade task such as `sysmerge`, `dbupdate`, or `pkg_add`.

## Procedure

1. Classify the change:
   - read-only inspection;
   - bounded write;
   - destructive or irreversible operation;
   - remote code or package installation.
2. Identify the required privilege and use the existing mechanism:
   - Debian: `require_root` re-execs the whole script through `sudo`;
     `detect_root_cmd`/`run_root` elevate individual commands.
   - OpenBSD: run as root or use `doas`; never add `sudo` to OpenBSD code.
   - SecureBlue: `require_root` re-execs the whole script through `run0`,
     not `sudo`; `run_root` elevates individual commands.
   - Windows: per-user operations only; do not add HKLM or elevation.
   Preserve the original arguments and documented environment settings across
   a re-exec, and fail closed when the elevation tool is absent.
3. Prefer the existing preview path. `clean-logs`, `ai-purge-history`, and
   the Windows installer have a dry-run flag; do not claim one exists
   elsewhere. If you add a destructive step, add an explicit opt-in or
   dry-run where practical.
4. Bound every deletion:
   - quote the operand and use `--`;
   - resolve or validate the target before deleting;
   - keep `find` scoped and use `-xdev` for root-filesystem walks;
   - never delete from an unset or empty variable;
   - never add `rm -rf /`.
5. Use `mktemp` with a template and an `EXIT` trap. Do not use fixed names
   under `/tmp`. Root-run audits and system reports must use a private
   directory (`umask 077`, `mktemp -d`), not a predictable path opened with
   `tee` before `chmod`.
6. Make the change idempotent:
   - check installed versions before rebuilding;
   - upsert configuration keys instead of appending duplicates;
   - deduplicate PATH and firewall entries;
   - use timestamped backups before rewriting shared configuration.
7. Provide reversal where the current design allows it. Stop a service only
   if it was active, restart it on failure, restore a previous unit or binary,
   and leave a backup path in the output. State clearly when an operation is
   irreversible.
8. Treat downloads as untrusted: download to a file, verify a checksum or
   signature, then install. Do not add `curl | sh`.
9. For deployments, inspect the destination and service before running.
   Existing website synchronization replaces content; existing repository
   synchronization replaces Git metadata.
10. Website synchronization must stage repository sources outside the public
    tree, omit known repository-only documentation and tooling from the public
    copy, remove those same known paths left by an older deployment, and keep
    the active `.sync.lock`. Test the copy/filter behavior in temporary trees;
    never use a production document root for validation. The opt-in atomic
    mode requires an existing symlink docroot, stages a sibling release and
    rolls the link back on post-publication failure. Keep its parent private
    to administrators; retain old releases until operators prune them. Locks
    live beside the docroot and are not automatically stolen by PID.
    `--check-atomic` validates only the filesystem layout, not server policy.
    Apply the same single-root ZIP entry policy before extraction on Debian
    and OpenBSD. Check types and declared expansion size from ZIP metadata
    before extraction, then check the resulting tree before publication.
    Execute Git clone and LFS as the non-root fetch account. Capture via
    that account into a root-private archive and validate its extraction
    before deployment. Never run Git as root against the live tree or the
    fetch account's checkout. Keep static public content root-owned and
    service-readable. In-place publication can be partial on failure,
    while the configured symlink mode supports activation rollback.
11. For Debian repository keys, check the entire set of primary keys and
    restrict the deb822 `Signed-By` declaration to the approved fingerprint.
    For GitHub .deb releases such as Fastfetch, verify the exact published
    digest and inspect package metadata before invoking APT. Validate the
    GitHub `sha256:` prefix and digest syntax before comparing raw hex.
    Use system
    install(1) to publish selected build outputs instead of elevating an
    upstream Makefile.
12. For a Debian AI CLI package downloaded as the target user, retain the
    expected digest from the verified publisher metadata. Before granting
    APT access, copy the file to a root-owned temporary directory and
    verify the copy against that digest. Pass only the root-owned path to
    APT and retain `--no-remove`. Claude Code uses an isolated APT index
    pinned to Anthropic's signing fingerprint. Crush checks the release
    manifest's Sigstore publisher identity before the handoff; Codex
    validates the equivalent package signature before its user-level
    deployment.
13. Keep xerj MCP registration under the desktop account. On Debian limit
    the elevated phase to the binary package and its dependencies. Never
    pass a node credential in a command argument or print configuration
    parse excerpts. Refuse to replace an existing Codex registration when
    its inspection API omits supported fields. Use the Claude user MCP
    JSON schema directly so the native CLI does not create state backups.

## Risk checklist for this tree

- `debian/clean-logs.bash` and `openbsd/clean-logs.ksh` delete compressed logs
  under `/var/log` and `.old` files older than a configurable age in a bounded
  set of system directories. A real run requires `--force`.
- `*sync-website*` replaces the deployed tree and restarts the web service.
  Its source checkout is private staging data; the document root must not
  expose `.git`, GitHub or agent instructions, maintainer documentation, test
  and cache directories, or development-only configuration. The Debian Bash
  and OpenBSD ksh filters should stay aligned, and cleanup must preserve the
  live `.sync.lock` and site assets.
- `*ai-purge-history*` deletes session/state data; use its `--dry-run` /
  `-DryRun` preview. Crush data is preserved by default; removing the whole
  directory requires `--include-crush-data` on POSIX or `-IncludeCrushData` on
  Windows.
  For Claude Code, use `CLAUDE_CONFIG_DIR` (default `~/.claude`). Remove the
  prompt history and known transcript files individually. The `projects`
  tree also contains auto memory and must never be removed wholesale.
  Reject symbolic links or reparse points on transcript paths and their
  ancestors in both preview and deletion.
- `debian/install-hardened-malloc.bash` edits `/etc/ld.so.preload` and a
  sysctl file.
- `debian/enable-tor-transport.bash` rewrites APT sources and keeps a
  timestamped backup.
- `debian/update-monero.bash` edits service units, Tor/I2P/Monero configs,
  and adds runtime nftables rules.
- Debian btop and Lyrebird build in disposable staging as an unprivileged
  account. Publish selected files through root-owned staging. Keep the
  Perl interpreter and helper discovery fixed for the Go and btop updaters.
  Debian XD builds as a non-root account and installs the repository-defined
  unit, which runs as the dedicated XD account. Monero stages and backs up its
  release binaries before stopping the service, and restores them on an
  incomplete core update. Optional LWS work follows that commit point.
- `debian/rpi-update-safe.bash` runs `rpi-update` as root with rebooting disabled,
  then runs `depmod` and can replace the Raspberry Pi 5 DTB and initramfs in
  `/boot/firmware`. Backups cover replaced boot files, not every firmware or
  module change made by the updater. Its DTB validation must compare the
  repaired bootargs against the original with the removed token excluded, and
  `dtc -q` suppresses expected upstream warnings without hiding errors. Never
  execute it during review or tests.
- `secureblue/setup-clamav.bash` changes SELinux contexts, ClamAV configs,
  units, and timers.
- `secureblue/sync-gh-repos.bash` replaces Git metadata and restores from a
  backup on error.
- `openbsd/sysupgrade-current.ksh` runs `sysmerge`, `dbupdate`, package
  upgrades, and Lynis on first boot, then `sysupgrade -sf` reboots by default.
  Debian, SecureBlue and newly generated OpenBSD first-boot reports use
  `/var/log/scripts-sysupgrade` with root-only access. Keep retention scoped
  there and collect process names in Debian reports.
  `--skip-audit` must reach the generated `/upgrade.site` and the existing
  `/etc/rc.firsttime` policy without rewriting unrelated tasks.
- `secureblue/sysupgrade.bash` relinks selected Homebrew formulae before
  `brew cleanup`; keep the `unlink && link` ordering and run both as the
  administrative linuxbrew account.
- `openbsd/update-crush.ksh` verifies the Charm release's Sigstore checksum
  manifest and extracts named regular members only. Check the staged binary's
  version under an unprivileged account before activation. Publish the
  `crushrc` edit atomically as the target user.
- Keep SecureBlue xerj's per-user lock held until binary publication, MCP
  registration and active-version verification finish. Debian AI CLI version
  discovery uses existing tools so a current installation can skip APT.

## Validations

Read-only static checks:

```sh
/bin/sh tests-format/validate-correctness.sh --target all .
/bin/sh tests-format/fix-permissions.sh --check .
shellcheck -x <ruta>
perl -c PATH
```

The correctness audit flags unguarded destructive operations, `curl | sh`,
fixed `/tmp` files, unsafe `xargs`, and platform-specific commands. It is not
a proof of safety. Review every changed destructive line manually.

Do not execute a privileged or destructive script to validate a documentation
or code change. If execution is explicitly requested, use a disposable host
or container, the script's dry-run mode, and a backup.

## Common problems

- A destructive script lacks a root check but writes to `/etc`, `/var`, or
  `/usr/local`.
- `chmod -R` or `chown -R` follows an unvalidated path.
- A configuration rewrite has no backup and no rollback.
- A service is stopped and not restarted when a later step fails.
- A firewall rule is added at runtime but not persisted.
- A download is executed without checksum or signature verification.
- A lock directory is left behind after `SIGKILL`; check staleness.
- `sysupgrade -sf` reboots unless the environment suppresses it.
- Here-document bodies are only partially analyzed by
  `validate-correctness.sh`; review generated scripts manually.

## Maintenance & Continuous Learning

After using this skill to modify the repository, review this skill and the
applicable agent instructions as part of the task's final synchronization
step. Update this skill when procedures, tools, configuration, assumptions,
validation commands, or reusable knowledge have changed. Correct guidance
that proved inaccurate and keep examples and validation steps aligned with
the repository. Add only knowledge that will help future work; omit
execution-specific notes and cosmetic edits. Review affected specialized
agent instructions for consistency and run
`make check-agent-knowledge` (or
`perl scripts/validate-agent-knowledge.pl --scope worktree`). The automated check
covers structure and resolvable local references; semantic relevance still
requires review. Report the synchronization result in the final summary and
do not claim completion if it was skipped or failed.

## References

- [Root agent instructions](../../../AGENTS.md)
- [Read-only and write modes](../../../tests-format/README.md)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
- [Debian scripts](../../../debian/README.md)
- [OpenBSD scripts](../../../openbsd/README.md)
- [SecureBlue scripts](../../../secureblue/README.md)
- [Windows scripts](../../../windows/README.md)
