# Troubleshooting

## `make check` reports permission errors

The policy expects directories/scripts at `0755` and data at `0644`. Clone with
a normal umask or run `make fix-permissions` once. `--check` skips Git-ignored
artifacts, but tracked modes must still match their content.

## A validator reports a missing optional tool

Non-strict runs print `[SKIP]` and continue. Use `--strict` when every optional
analyzer must be present. Logs are private files under `${TMPDIR:-/tmp}`.

## A release updater refuses to install

The script requires the exact upstream digest or signature. Check that the
release metadata publishes it and that the asset name/architecture matches.
Do not bypass the check by editing the digest in place; use the documented
`--trust-*` escape only after review.

## A website synchronization lock remains

Locks are not stolen by PID. Verify that no deployment is running, then remove
the sibling `.<docroot>.sync.lock` directory. A legacy `.sync.lock` inside the
document root must be removed explicitly after the same check.

## A PowerShell launcher fails

Install PowerShell 7 for `psfmt`, or run the documented Windows PowerShell
fallback. The installer never changes the execution policy. Downloaded scripts
may carry Mark-of-the-Web; unblock them only after reviewing the source.
