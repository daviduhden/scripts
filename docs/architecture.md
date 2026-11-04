# Architecture

The repository is a collection of self-contained administration programs.
Each script is installed as one command; scripts do not require a shared
runtime library. The platform directories are:

- `debian/`: Bash 4+, GNU utilities, APT, systemd;
- `openbsd/`: base `ksh`, `doas`, `rcctl`, native tools;
- `secureblue/`: Bash, `run0`, rpm-ostree, Homebrew, systemd user units;
- `perl/`: portable Perl 5.10.1+ programs using core modules;
- `windows/`: batch installers/launchers and PowerShell utilities;
- `tests-format/`: POSIX validators and formatters;
- `tests/`: isolated regression suites;
- `scripts/`: the standalone agent-knowledge validator;
- `shell/`: sourced interactive Bash helpers.

## Trust boundaries

Downloads are untrusted until a documented checksum, signature, or exact
GitHub asset digest is verified. The remaining trust boundary is stated in the
platform README for each updater. Administrative scripts are reviewed before
execution; tests use temporary trees and mocks, never a live system.

## Transactions

Release updaters stage beside the destination and activate with `rename` or
`File.Replace`. Website synchronization supports an opt-in atomic symlink
release and a compatible in-place mode. Locks fail closed; stale locks require
an operator decision.

## Tests and CI

`make check` is the read-only validation gate. `make test` runs isolated
regressions after validation. Platform CI runs Linux, Windows, and OpenBSD 7.8
checks; native platform behavior cannot be established by a Linux-only run.
