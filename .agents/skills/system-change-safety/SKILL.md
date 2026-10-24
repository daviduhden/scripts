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
   - Debian: `require_root` or `detect_root_cmd`/`run_root`.
   - OpenBSD: run as root or use `doas`; never add `sudo` to OpenBSD code.
   - SecureBlue: `run0`, not `sudo`; the `sudo-wrapper` maps `sudo` to `run0`.
   - Windows: per-user operations only; do not add HKLM or elevation.
   Fail closed with a clear message when the required privilege is absent.
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
   under `/tmp`.
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

## Risk checklist for this tree

- `debian/clean-logs.bash` and `openbsd/clean-logs.ksh` delete under
  `/var/log` and `/`.
- `*sync-website*` replaces the deployed tree and restarts the web service.
- `*ai-purge-history*` deletes session/state data; use its `--dry-run` /
  `-DryRun` preview. The Windows variant removes the whole Crush data
  directory, including configuration stored there.
- `debian/install-hardened-malloc.bash` edits `/etc/ld.so.preload` and a
  sysctl file.
- `debian/enable-tor-transport.bash` rewrites APT sources and keeps a
  timestamped backup.
- `debian/update-monero.bash` edits service units, Tor/I2P/Monero configs,
  and adds runtime nftables rules.
- `secureblue/setup-clamav.bash` changes SELinux contexts, ClamAV configs,
  units, and timers.
- `secureblue/sync-gh-repos.bash` replaces Git metadata and restores from a
  backup on error.
- `openbsd/sysupgrade-current.ksh` runs `sysmerge`, `dbupdate`, package
  upgrades, and Lynis on first boot, then `sysupgrade -sf` reboots by default.
- `openbsd/update-crush.ksh` installs over `/usr/local/bin/crush` after
  checksum verification and rewrites the user's `crushrc`.

## Validations

Read-only static checks:

```sh
/bin/sh tests-format/validate-correctness.sh --target all .
/bin/sh tests-format/fix-permissions.sh --check .
shellcheck -x PATH
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

## References

- [Root agent instructions](../../../AGENTS.md)
- [Read-only and write modes](../../../tests-format/README.md)
- [Correctness validator](../../../tests-format/validate-correctness.sh)
- [Debian scripts](../../../debian/README.md)
- [OpenBSD scripts](../../../openbsd/README.md)
- [SecureBlue scripts](../../../secureblue/README.md)
- [Windows scripts](../../../windows/README.md)
