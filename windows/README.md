# Windows scripts

Batch and PowerShell utilities for Windows 10/11. Run the installer from a
checkout or an extracted copy; its paths are resolved relative to the installer.

| Script | Purpose |
| --- | --- |
| [install-windows.bat](install-windows.bat) | Installs public Perl programs, the PowerShell scripts in this directory, and `test-format/psfmt.ps1`; creates command launchers and optionally adds their directory to the user PATH. |
| [update-aiclis.ps1](update-aiclis.ps1) | Installs or updates Codex, OpenCode, and Bun for the current user, maintains versioned copies and PATH entries, and adds PowerShell wrappers. |
| [ai-purge-history.ps1](ai-purge-history.ps1) | Deletes Codex, Copilot, OpenCode, Crush, and project-local Swival history/state while retaining configuration and credentials. |
| [launcher.cmd](launcher.cmd) | Internal template for installed Perl launchers. Uses the recorded Perl interpreter and forwards arguments and exit status. |
| [powershell-launcher.cmd](powershell-launcher.cmd) | Internal template for PowerShell launchers. Prefers `pwsh`, falls back to Windows PowerShell, and forwards arguments and exit status. |
| [test-format/psfmt.ps1](test-format/psfmt.ps1) | Formats and checks PowerShell files with PSScriptAnalyzer; requires PowerShell 7. See [its README](test-format/README.md). |

From the repository root, in Command Prompt:

```bat
windows\install-windows.bat --dry-run
windows\install-windows.bat
tests-format\validate-windows-installer.bat
```

Installer options are `--dry-run`, `--no-path`, `--install-dir PATH`, and
`--help`. The default destination is
`%LOCALAPPDATA%\Programs\<repository-name>`. The installer reuses suitable
Perl or installs Strawberry Perl with winget. It does not install PowerShell 7;
install it separately to run `psfmt`. The execution policy is left unchanged.

From PowerShell, check AI CLI versions without installing updates:

```powershell
.\windows\update-aiclis.ps1 -Check
.\windows\update-aiclis.ps1 -Target Codex -Check
```

Other updater parameters are `-Target All|Codex|OpenCode|Bun`,
`-OpenCodeVersion`, `-CodexVersion`, `-Force`, and `-RemoveWinget`. The last
option explicitly removes winget CLI packages after installation. Bun uses
winget; Codex and OpenCode use upstream downloads.

Run history cleanup in the intended user's session. `SWIVAL_PROJECT_HOME`
selects the project whose `.swival` state is removed; it defaults to the working
directory. Launcher templates are copied under program-specific names and are
not intended to be run directly.
