# Changelog

## Unreleased

- Harden temporary logs and validator state files with `mktemp` and `umask`.
- Verify Windows Codex release assets against GitHub SHA-256 digests and read
  only expected ZIP entries.
- Make PowerShell profile wrappers opt-in and write the profile atomically.
- Pin APT and Monero signing-key fingerprints; verify the Monero systemd unit.
- Add a smoke test and rollback for `install-hardened-malloc`.
- Make website synchronization reject source symlinks and fail on permission
  errors; validate ZIP fallback entries.
- Require `--force` for `clean-logs` and make Crush data removal opt-in.
- Move systemd user units out of `BINDIR`, add `DESTDIR`, and stop overwriting
  an existing real `sudo` binary.
- Remove embedded Python from shell scripts in favour of native tools and
  standalone Perl helpers.
- Migrate the agent-knowledge validator, Arti helper, and all Python test
  suites to Perl; remove Ruff/Python setup from CI and the Python validator.
- Make the permission gate ignore Git-ignored artifacts and fix tracked modes.
- Give every source script a filename extension and strip it only on install;
  move inline interpreter logic into focused helper programs.

## 1.0.0

- Initial public version metadata.
