# Architecture

The repository is a collection of self-contained administration programs.
Each source script carries an extension (`.bash`, `.ksh`, `.sh`, or `.pl`);
install targets remove it from the installed command name. Scripts do not
require a shared runtime library, but focused helpers such as
`release-verify.pl`, `bootargs.pl`, `xerj-config.pl`, and `rename-link.pl`
are installed beside their caller when non-shell logic is needed.

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
