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
- `scripts/manage-install.sh`: POSIX install/uninstall/help/format logic used by the Makefile;
- `tests-format/`: POSIX validators and formatters;
- `tests/`: isolated regression suites;
- `scripts/` also contains the standalone agent-knowledge validator and
  the shared Linux agent delivery and XERJ client-discovery helpers;
- `shell/`: sourced interactive Bash helpers.

## Trust boundaries

Downloads are untrusted until a documented checksum, signature, or exact
GitHub asset digest is verified. The remaining trust boundary is stated in the
platform README for each updater. Administrative scripts are reviewed before
execution; tests use temporary trees and mocks, never a live system.

## Transactions

Release updaters use the transaction offered by their delivery mechanism.
Direct binary downloads can stage a verified candidate beside the destination.
APT and Homebrew manage their own transactions. Website synchronization
supports an opt-in atomic symlink release and a compatible in-place mode.
Stale locks require inspection before removal.

The Debian, OpenBSD, SecureBlue and Perl make targets preflight their
destinations and record the files they install. Uninstall preserves files whose
contents have changed. For a legacy installation from the same source revision,
`make install-PLATFORM ADOPT_LEGACY=1` records an existing file only if its
contents match the source and no other target has claimed it. Review or move
older copies before installing from a newer revision. Use trusted destination
directories that are writable only by the owning administrator or user.

## Tests and CI

`make check` is the read-only validation gate. `make test` runs isolated
regressions after validation. Static Validation checks shell parsing and
agent-knowledge references on pull requests and pushes to main. The manual
Platform Validation workflow runs Ubuntu, Debian 13 in a container, native
Windows, and an OpenBSD 8.0 VM. SecureBlue delivery logic is exercised with
Linux fixtures. SecureBlue image and policy behavior require a SecureBlue host.
