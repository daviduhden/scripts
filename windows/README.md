# Windows scripts

Batch and PowerShell utilities for Windows 10/11. Run the installer from a
checkout or an extracted copy; its paths are resolved relative to the installer.

| Script | Purpose |
| --- | --- |
| [install-windows.bat](install-windows.bat) | Installs public Perl programs, the PowerShell scripts in this directory, and `test-format/psfmt.ps1`; creates command launchers and optionally adds their directory to the user PATH. |
| [update-ai-clis.ps1](update-ai-clis.ps1) | Installs or updates OpenCode 2.x, Codex, Crush, GitHub Copilot CLI, and Claude Code for the current user. |
| [update-xerj.ps1](update-xerj.ps1) | Installs or updates verified xerj and registers its stdio MCP server with selected installed agents. |
| [ai-purge-history.ps1](ai-purge-history.ps1) | Deletes Codex, Copilot, OpenCode, and project-local Swival history/state. Crush data is preserved unless `-IncludeCrushData` is given; that switch removes the entire `%LOCALAPPDATA%\crush` directory, including any configuration stored there. Use `-DryRun` to preview. |
| [launcher.cmd](launcher.cmd) | Internal template for installed Perl launchers. Uses the recorded Perl interpreter and forwards arguments and exit status. |
| [powershell-launcher.cmd](powershell-launcher.cmd) | Internal template for PowerShell launchers. Prefers PowerShell 7 in its standard Program Files location, falls back to the system Windows PowerShell, and forwards arguments and exit status. |
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
install it separately to run `psfmt`. The installer verifies staged files
before publishing them and restores existing managed files if publication
fails. Helpers run under the current Windows PowerShell execution policy.
Perl discovery inspects absolute paths from the process and registry PATH
and standard Strawberry Perl locations. A portable Perl can be selected
from a trusted absolute PATH entry. The launcher requires the recorded
interpreter at runtime. Dry-run lists eligible paths without executing
Perl or creating scratch files. Installation, publication and PATH changes
require a local directory whose ancestors, ownership and write permissions
pass the installer checks. `--no-path` leaves the registry alone.

`ai-purge-history.ps1` checks every selected path and its ancestors before
removing anything. It needs local absolute history roots and refuses
reparse points or unexpected file types. Dry-run applies the same checks.

### AI CLI updates

Run the installed command from CMD or PowerShell. Omit the agent names or
pass `all` to process all five agents.

```powershell
update-ai-clis --help
update-ai-clis
update-ai-clis codex claude
update-ai-clis copilot-cli -Check
```

From a checkout, use `./windows/update-ai-clis.ps1` with the same arguments.
Reinstalling removes the previous `update-aiclis` script and launcher when
they are managed by the install manifest.
The supported Windows architectures for all five agents are x64 and ARM64.
Crush also supports Windows x86.
The updater uses these native packages, which bundle their language runtimes.

| Agent | Official distribution | Runtime |
| --- | --- | --- |
| `opencode` | [OpenCode 2.x ZIP](https://github.com/anomalyco/opencode/releases), baseline build on x64. Selects stable 2.x tags independently of the GitHub latest alias. | Bundled |
| `codex` | [OpenAI GitHub releases](https://github.com/openai/codex/releases), canonical package archive. | Windows `tar.exe` for extraction. Ripgrep, code-mode host and sandbox resources are bundled. |
| `crush` | [Charm GitHub releases](https://github.com/charmbracelet/crush/releases), platform ZIP. | Bundled. Project-specific LSP tools are optional. |
| `copilot-cli` | [GitHub Copilot CLI releases](https://github.com/github/copilot-cli/releases), standalone ZIP. | [Windows PowerShell 5.1 or PowerShell 7](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli#prerequisites) |
| `claude` | [Anthropic native binary](https://code.claude.com/docs/en/setup), stable channel. | Windows PowerShell. Git for Windows is optional for Bash tools. |

The GitHub paths verify the upstream release asset SHA-256 before publishing.
Cached release packages record the verified archive digest and packaged file
hashes. A mismatched cache is bypassed, and pruning applies only to complete
packages attributable to the updater. Version probes have time and output limits.
GitHub rate limiting can prevent a release lookup. Claude verifies the manifest
size and SHA-256 and requires a valid Authenticode signature from
`Anthropic, PBC`. A selected native distribution has no external requirement
for Node.js, npm, Bun, Python, or GitHub CLI.

The summary shows the previous version, available stable version, final version,
and outcome for each selected agent. Version checks resolve executables and
`.cmd` and `.ps1` wrappers. The updater reports duplicate installation paths,
verifies the active command and its version, and repeats verification in a
profile-free shell with the machine and user PATH from the registry. Managed
paths under the user profile are added to the current and persistent user PATH
when needed. Existing entries and the registry value type are preserved.
Resolve duplicate or outdated external installations through their original
package manager before running an update. Launch a new terminal session
after PATH changes.

`-Check` reports versions without installing or changing PATH. Exit status is
`0` for success, `1` when a selected operation or verification fails, and
`2` for invalid selection or pin. Existing stable versions and prereleases
with a higher version core are retained unless an explicit pin is provided.

The Windows launcher also accepts legacy `-Target`, explicit `bun` selection,
pins `-OpenCodeVersion`, `-CodexVersion`, and `-CrushVersion`, and `-Force`.
Codex pins require a release with the canonical Windows package archive.
`-Wrappers` adds opt-in PowerShell profile wrappers for OpenCode and Codex.
`-RemoveWinget` opts in to removing old WinGet copies of selected OpenCode,
Codex, Crush, or Bun after verifying the managed executable. Bun uses
[official direct downloads](https://bun.com/docs/installation) under
`BUN_INSTALL` or `%USERPROFILE%\.bun`.

`-UpdateCodexDaemon` opts in to the
[Codex daemon lifecycle command](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)
when selecting managed Codex. The daemon package updates separately and
respects `CODEX_HOME`. A running daemon may restart. `-Check` skips it.

Run history cleanup in the intended user's session. Crush data is preserved by
default; pass `-IncludeCrushData` to remove the entire Crush data directory,
which may contain configuration. `SWIVAL_PROJECT_HOME` selects the project whose
`.swival` state is removed; it defaults to the working directory. Launcher
templates are copied under program-specific names and are not intended to be
run directly.

## xerj

The updater installs xerj in `%LOCALAPPDATA%\Programs\xerj\xerj.exe` for the
current user. Close a running xerj process before replacing its binary.

```powershell
update-xerj --help
update-xerj codex claude
update-xerj --binary-only
```

Use `./windows/update-xerj.ps1` from a checkout. With no selectors, the
updater configures the supported installed agents. See the [xerj configuration
guide](../docs/update-xerj.md) for authentication and config paths.

Run the offline regression with `pwsh -NoProfile -File windows/tests/test-update-xerj.ps1`.

## Verified and recoverable release updates

Codex, OpenCode, and Crush downloads use the official GitHub release metadata
and require an exact asset with a published SHA-256 digest. Codex reads only the
expected executable entries from its ZIP; OpenCode reads only the single regular
root `opencode.exe`; Crush reads only `crush.exe` inside the expected versioned
archive folder. Duplicate expected entries and checksum failures are rejected
before activation. The check trusts GitHub HTTPS and its release metadata, not
an independent signature. Older releases without digest metadata are refused.

Codex packages may contain both root and `codex-resources/` copies of their
helpers. The updater prefers each exact resource path and supports the legacy
root path when absent; duplicate entries at the selected path are rejected.
Incomplete cached Codex packages are downloaded again. A leftover old binary
that cannot be deleted after activation is retained with a warning, rather
than reporting an otherwise successful OpenCode or Crush update as failed.
If activation itself is blocked, close the affected CLI and retry.

Offline AI CLI regressions use temporary trees and fixture archives without
executing downloaded binaries, changing PATH, or updating a real daemon:

```powershell
pwsh -NoProfile -File windows/tests/test-update-ai-clis.ps1
```

xerj verifies the archive's checksum, rejects duplicate executable entries and
checks the staged executable's version before activation. It publishes binaries and
configuration edits with `File.Replace` without creating recovery copies. A
locked binary causes the publication to fail. Existing `.bak.*` files remain
untouched. The destination filesystem must support `File.Replace`.

`test-format/psfmt.ps1` requires PSScriptAnalyzer 1.25.0 and never installs a
missing module unless `-install-dependency` is explicitly selected. The
installer writes `installed-files.txt` through a temporary manifest and updates
the user PATH only after post-install verification succeeds. A PowerShell
launcher is exercised with `psfmt.ps1 -version` when `pwsh` is available. See the
[formatter guide](test-format/README.md) for offline and installation behavior.
