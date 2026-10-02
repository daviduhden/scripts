# Interactive Bash helpers

These files are sourced by Bash rather than executed as standalone programs.
They target a Linux/SecureBlue environment and refer to GNU utilities and
optional tools that must be installed separately.

| File | Purpose |
| --- | --- |
| [aliases.bash](aliases.bash) | Defines navigation, file-operation, editor, networking, and system-information aliases, plus archive extraction and `sysupgrade-all`. AI CLI aliases enable their automatic/full-permission modes. |
| [vi-mode.bash](vi-mode.bash) | Enables vi editing in interactive Bash sessions and sets `EDITOR=vim` and `VISUAL=kak` only when they are unset. |

To load both files from a checkout:

```bash
source /path/to/scripts/shell/aliases.bash
source /path/to/scripts/shell/vi-mode.bash
```

Add those lines to your interactive Bash configuration if desired. On
SecureBlue, `make install-shell` installs both files into
`/var/home/${SECUREBLUE_USER}/.bashrc.d` (default user: `david`). The installer
uses `chattr` to manage immutable attributes. Override `SECUREBLUE_USER` or
`BASH_CONF_DST_DIR` to select another destination; your Bash configuration must
source that directory's files.

`sysupgrade-all` calls the maintenance helpers documented in
[../secureblue/README.md](../secureblue/README.md), followed by `pipx upgrade-all`.
The `extract` function selects an archive tool based on the filename extension.
