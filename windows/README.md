# Windows scripts

Batch and PowerShell utilities for Windows 10/11. Run the installer from a
checkout or an extracted copy; its paths are resolved relative to the installer.

| Script | Purpose |
| --- | --- |
| [install-windows.bat](install-windows.bat) | Installs public Perl programs, the PowerShell scripts in this directory, and `test-format/psfmt.ps1`; creates command launchers and optionally adds their directory to the user PATH. |
| [update-aiclis.ps1](update-aiclis.ps1) | Installs or updates Codex, OpenCode 2.x, Crush, and Bun for the current user, maintains versioned copies and PATH entries, and optionally adds PowerShell wrappers with `-Wrappers`. |
| [update-xerj.ps1](update-xerj.ps1) | Installs/updates SHA-256-verified xerj for the current user; `-Codex`, `-Crush`, and `-OpenCode` optionally register its stdio MCP server. |
| [ai-purge-history.ps1](ai-purge-history.ps1) | Deletes Codex, Copilot, OpenCode, and project-local Swival history/state. Crush data is preserved unless `-IncludeCrushData` is given; that switch removes the entire `%LOCALAPPDATA%\crush` directory, including any configuration stored there. Use `-DryRun` to preview. |
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
.\windows\update-aiclis.ps1 -Target Crush -Check
```

Other updater parameters are `-Target All|Codex|OpenCode|Crush|Bun`,
`-OpenCodeVersion`, `-CodexVersion`, `-CrushVersion`, `-Force`, `-Check`,
`-RemoveWinget`, and `-Wrappers`. The last option installs optional profile
functions that add `--yolo`/`--auto`; wrappers are off by default.
`-RemoveWinget` removes the winget copies of OpenCode, Codex, and Crush after
installation; Bun is installed through winget and is left in place. Codex,
OpenCode, and Crush use upstream downloads and require the exact SHA-256 digest
published in GitHub release metadata. OpenCode selects the newest stable 2.x
release because the repository's `latest` alias still points at the 1.x line.
Crush is installed if missing and updated on later runs.

Run history cleanup in the intended user's session. Crush data is preserved by
default; pass `-IncludeCrushData` to remove the entire Crush data directory,
which may contain configuration. `SWIVAL_PROJECT_HOME` selects the project whose
`.swival` state is removed; it defaults to the working directory. Launcher
templates are copied under program-specific names and are not intended to be
run directly.

## xerj

Windows x64 and ARM64 are supported. No administrator privileges, PATH edits,
profile changes, or execution policy changes are required:

```powershell
.\windows\update-xerj.ps1
.\windows\update-xerj.ps1 -Codex -Crush -OpenCode
.\windows\update-xerj.ps1 -Version v1.0.0-rc.100 -OpenCode
```

The destination is `%LOCALAPPDATA%\Programs\xerj\xerj.exe`. Without switches,
only the binary is installed. Each run downloads and verifies the release;
`-Version TAG` pins it, otherwise the latest GitHub release is used. `-Url URL`
sets the ES-compatible node endpoint (default `http://127.0.0.1:9200`). Close a
running xerj process before replacing its binary on Windows.

Codex must already be installed when selected; the script uses `codex mcp add`
and respects `CODEX_HOME`. Crush gets a managed block in
`%USERPROFILE%\.config\crush\crushrc`, using the current Bash config format.
OpenCode gets `mcp.xerj` in `%USERPROFILE%\.config\opencode\opencode.json`.
`XDG_CONFIG_HOME` overrides the latter two roots. Existing configurations are
backed up, other entries are retained, and repeated registration replaces the
xerj entry/block. JSONC files are refused for manual merging; OpenCode JSON
must be a valid object. Project configuration and environment overrides may
take precedence. Clients are not installed by this script.

MCP needs a running engine. Start a local authenticated node in another terminal:

```powershell
$xerj = Join-Path $env:LOCALAPPDATA 'Programs\xerj\xerj.exe'
$data = Join-Path $HOME '.xerj\data'
New-Item -ItemType Directory -Force $data | Out-Null
& $xerj --bind 127.0.0.1 --data-dir $data
```

Before launching a configured client, pass the generated key in its environment
if automatic local key discovery does not locate this data directory:

```powershell
$env:XERJ_AUTH = 'ApiKey ' + (Get-Content -Raw (Join-Path $HOME '.xerj\data\admin.key')).Trim()
codex  # or crush / opencode
```

Restart clients after registration. Remote nodes require `XERJ_AUTH` in the
client's environment. No service or key is created by the updater. Sources:
[xerj installation](https://xerj.org/docs/install),
[xerj MCP](https://xerj.org/docs/cli#mcp),
[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp),
[OpenCode MCP](https://opencode.ai/docs/mcp-servers/), and
[Crush configuration](https://github.com/charmbracelet/crush/blob/main/docs/config/README.md).

Offline regression tests run in temporary directories with mocked downloads
and Codex, without executing xerj or modifying real client configurations:

```powershell
pwsh -NoProfile -File windows/tests/test-update-xerj.ps1
```

## Verified and recoverable release updates

Codex, OpenCode, and Crush downloads use the official GitHub release metadata
and require an exact asset with a published SHA-256 digest. Codex reads only the
expected executable entries from its ZIP; OpenCode reads only the single regular
root `opencode.exe`; Crush reads only `crush.exe` inside the expected versioned
archive folder. Duplicate expected entries and checksum failures are rejected
before activation. The check trusts GitHub HTTPS and its release metadata, not
an independent signature. Older releases without digest metadata are refused.

xerj verifies the archive's checksum, rejects duplicate executable entries and
prepares the binary next to its destination. Existing binaries/configurations
are replaced with `File.Replace` and unique recovery copies; a locked binary
fails without being overwritten in place. Successful xerj replacements retain
`.bak.*` files for manual recovery and pruning. AI CLI activation likewise uses
a verified same-directory pending file and has no overwrite fallback for locked
targets. These filesystems must support the requested replacement operation.

`test-format/psfmt.ps1` requires PSScriptAnalyzer 1.25.0 and never installs a
missing module unless `-install-dependency` is explicitly selected. The
installer writes `installed-files.txt` through a temporary manifest and updates
the user PATH only after post-install verification succeeds. A PowerShell
launcher is exercised with `psfmt.ps1 -version` when `pwsh` is available. See the
[formatter guide](test-format/README.md) for offline and installation behavior.
