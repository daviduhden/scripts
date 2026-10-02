# Portable Perl programs

Public programs are listed in [programs.txt](programs.txt), the shared manifest
used by the POSIX and Windows installers. The scripts use Perl core modules.
The Windows installer checks for Perl 5.10.1 or newer and required modules.

| Script | Purpose |
| --- | --- |
| [normalize-files.pl](normalize-files.pl) | Normalizes file and directory names and text encodings/line endings, with collision handling, binary safety, and a dry-run mode. |
| [ssh-menu.pl](ssh-menu.pl) | Presents an interactive SSH menu from plain `known_hosts` entries, remembers users and connection frequency, and supports aliases and host-entry removal. Requires an SSH client. |

Run from the repository root:

```sh
perl perl/normalize-files.pl --help
perl perl/normalize-files.pl --dry-run ./example
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
