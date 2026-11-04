# Portable Perl programs

Public programs are listed in [programs.txt](programs.txt), the shared manifest
used by the POSIX and Windows installers. The programs use Perl core modules
for portable behavior. On Windows, `normalize-files` also uses the bundled
`Win32` module to handle names in the active Windows ANSI code page. The
Windows installer checks for Perl 5.10.1 or newer and the required modules.

| Script | Purpose |
| --- | --- |
| [normalize-files.pl](normalize-files.pl) | Normalizes file and directory names and text encodings/line endings, with collision handling, binary safety, and a dry-run mode. |
| [ssh-menu.pl](ssh-menu.pl) | Presents an interactive SSH menu from plain `known_hosts` entries, remembers users and connection frequency, and supports aliases and host-entry removal. Requires an SSH client. |

Run from the repository root:

```sh
perl perl/normalize-files.pl --help
perl perl/normalize-files.pl --dry-run ./some-directory
perl perl/ssh-menu.pl
```

`ssh-menu` skips hashed hosts and marker entries. It uses the default
`~/.ssh/known_hosts` unless `SSH_MENU_KNOWN_HOSTS` selects another file.
`SSH_MENU_USER` provides a default SSH username. The embedded POD documentation
describes additional behavior and configuration:

```sh
perldoc perl/normalize-files.pl
perldoc perl/ssh-menu.pl
```

Install with `make install-perl` on POSIX systems or
`windows\install-windows.bat` on Windows. Installed commands are named
`normalize-files` and `ssh-menu`. Regression tests live in
[../tests-format](../tests-format/README.md).

## File safety and audit status

`normalize-files` reads content in chunks capped by `--max-bytes`, rejects
read failures, and compares path/handle identity and modification metadata
before and after reading and before replacement. These checks detect common
concurrent changes; they are not a lock against a hostile writer preserving
file size and timestamps. Run it on a quiescent tree when consistency matters.
Replacement is aborted if original permissions or requested timestamps cannot
be applied to the temporary output. Report write/close failures count toward
the exit status. Ownership, ACLs and extended attributes are not preserved.

On Windows, both programs use unique recovery names when replacement requires
moving an existing destination aside. A failed restoration leaves the original
at the recovery path reported in the diagnostic. Do not remove that file until
the original has been recovered. Simulated rename-failure tests exercise this
logic on Linux; native Windows filesystem behavior still requires Windows.

The [Perl audit and individual critic triage](../docs/perl-audit.md) records
retained severity 4/3 diagnostics and their engineering rationale. It does not
claim default-policy compliance, and no policy configuration is weakened to
hide warnings.
