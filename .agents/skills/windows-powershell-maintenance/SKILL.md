---
name: windows-powershell-maintenance
description: >-
  Edit or review Windows batch, PowerShell, installer, launcher, or psfmt code
  in this repository. Use for files under windows/, including install-windows.bat,
  launcher.cmd, powershell-launcher.cmd, *.ps1, and windows/test-format/.
---

# Windows and PowerShell maintenance

## When to use

- Changing `windows/install-windows.bat`, either launcher, or a `.ps1` file.
- Adding a public Perl program that the Windows installer must install.
- Changing `windows/test-format/psfmt.ps1` or its tests.
- Updating `perl/programs.txt` when the Windows install set changes.

Windows-only behavior cannot be validated on Linux. Use static review here and
run the Windows checks on a Windows host. Do not claim a Windows test passed
without one. A portable `pwsh` build can still run the PowerShell parser,
PSScriptAnalyzer, and `psfmt -c` on Linux for syntax and formatting checks; it
does not prove Windows runtime behavior or Windows PowerShell 5.1 execution.

## Keep batch and PowerShell separate

- Batch and `.cmd` files are the installer and launchers. They use CRLF,
  ASCII, `setlocal EnableExtensions DisableDelayedExpansion`, quoted paths,
  and `%~dp0` for their own location.
- Launchers forward arguments with `%*` and return the child status with
  `exit /b %ERRORLEVEL%`.
- PowerShell files implement behavior. `psfmt.ps1` and its test runner require
  PowerShell 7; the installer uses Windows PowerShell for registry access and
  syntax parsing.
- Do not add `-ExecutionPolicy Bypass`, `setx`, `runas`, `Start-Process`,
  HKLM writes, or arbitrary downloads.

## Procedure

1. Read `windows/README.md`, `windows/test-format/README.md`, and the nearest
   script.
2. For the installer:
   - keep the supported options exactly `--dry-run`, `--no-path`,
     `--install-dir PATH`, and `--help`;
   - install only under the per-user root by default;
   - update only `HKCU\Environment\Path`, idempotently;
   - preserve unknown files and update the manifest;
   - resolve trusted absolute interpreters. Use the built-in Windows
     PowerShell path and standard protected PowerShell 7 installation path.
     Keep private portable Perl PATH entries eligible and record the
     absolute interpreter path for the launcher;
   - use the engine-specific .NET filesystem ACL API in the installer
     trust helper. Windows PowerShell started by PowerShell 7 can inherit a
     module path that breaks Security cmdlet autoload. Resolve WinGet from the
     registered Microsoft App Installer executable and validate the physical
     path without an exception for application aliases. `WindowsApps` denies
     ACL reads to users, so WinGet is validated by its physical path under
     `%ProgramFiles%\WindowsApps`, absence of reparse points, and a valid
     Authenticode signature from Microsoft instead of the ACL check;
   - keep `PERL_MODULES` aligned with the runtime modules required by the
     installed Perl programs, including Windows-specific bundled modules;
   - keep the dry-run path free of writes, Perl candidate execution,
     packaging, and PATH changes. Allocate verification files inside the
     private stage created by `windows/install-support/trust.ps1`. If the
     default `%LOCALAPPDATA%\Programs` path or the system temporary directory
     fails ACL validation, use `%USERPROFILE%\Programs` or private staging
     under `%USERPROFILE%` only after that location independently passes the
     same trust checks; never whitelist a shared sandbox identity.
3. For a new top-level `windows/*.ps1`, the installer picks it up
   automatically and creates `<name>.cmd`. For a new public Perl program,
   add it to `perl/programs.txt`; both the POSIX and Windows installers read
   that manifest.
   The installer verifies a private staging tree before calling
   `windows/install-support/publish.ps1`. Keep the publishing helper outside
   top-level program discovery and test rollback on a locked managed file.
   Validate canonical paths, reparse points, owners, ancestors and write
   grants before publication or adding an installed directory to PATH.
   Run `pwsh -NoProfile -File windows/tests/test-path-safety.ps1` on Windows.
4. For `psfmt.ps1`, preserve the four mutually exclusive modes and their exit
   codes: `0` success, `1` error, `2` formatting needed in `-c` mode. Keep
   encoding/BOM/newline preservation and the atomic replace path.
   Apply restrictive staging permissions before writing bytes and transfer
   the source ACL or Unix file mode before activation. Apply the same Windows
   staging and ACL rules to optional CLI profile updates.
5. For PowerShell scripts, use `[CmdletBinding()]` and typed parameters when
   the script takes options, set `$ErrorActionPreference = 'Stop'`, and return
   explicit exit codes.
6. Run the Windows validations below. Use `--dry-run` before a real install.

## Validations

On Windows, from the repository root:

```bat
windows\install-windows.bat --dry-run
tests-format\validate-windows-installer.bat
```

From PowerShell:

```powershell
.\windows\test-format\psfmt.ps1 -c .
Invoke-ScriptAnalyzer -Path .\windows\test-format\psfmt.ps1
pwsh -NoProfile -File .\windows\test-format\tests\run-tests.ps1
```

From `windows/test-format/`, the test runner is:

```powershell
.\tests\run-tests.ps1
```

The installer validator is static only: it checks required/forbidden text,
manifest entries, and CRLF endings for the three batch files. It does not run
the installer, winget, Perl, or any launcher. `run-tests.ps1` requires an
already-installed PSScriptAnalyzer; it does not install it.

## Common problems

- CRLF is required for batch files; PowerShell files are LF and must not be
  converted.
- `#requires -Version 7.0` fails if the launcher falls back to Windows
  PowerShell 5.1. The installer does not install PowerShell 7.
- The installer rejects spaces and cmd metacharacters in discovered
  PowerShell script names; the external validator still checks only the Perl
  manifest. Avoid awkward names in both places.
- Bun uses official oven-sh/bun release ZIPs with published SHA-256 digests,
  exact bun-windows-<arch>/bun.exe extraction, and atomic activation under
  BUN_INSTALL or %USERPROFILE%\.bun. Bun is an explicit compatibility target.
  Its WinGet cleanup requires `-RemoveWinget`, as does cleanup for selected
  OpenCode, Codex and Crush targets. Verify the managed executable first.
  The dispatch fixture defines its own version probe. Keep progress on the
  information stream so it cannot become part of a function's result.
  Capture the previous Codex directory type before swapping paths, because
  file metadata queried afterward may describe the new junction.
  Validate custom Crush purge paths before deleting any history, including
  in dry-run previews.
- `update-ai-clis.ps1` resolves OpenCode from the stable `v2.*` release tags
  because the repository's GitHub `latest` alias still points at 1.x. Do not
  replace that filter with `releases/latest`. Use the baseline x64 artifact
  and the ARM64 artifact, and keep the versioned-copy layout for OpenCode and
  Crush. Keep the implementation in `update-ai-clis.ps1` so automatic
  discovery produces one launcher. Reinstalls remove the retired
  `update-aiclis` files through the existing install manifest. Keep the
  old profile block markers to update existing opt-in wrappers in place.
- `ai-purge-history.ps1` preserves Crush data by default. `-IncludeCrushData`
  removes the entire `%LOCALAPPDATA%\crush` directory, which can include
  configuration; do not describe that opt-in path as configuration-safe. Use
  `-DryRun` to preview.
  Preflight every selected path in both modes. Refuse broad roots, unsafe
  file types and ancestor or descendant reparse points. Recheck each target
  immediately before removal.
- `psfmt.ps1` requires PSScriptAnalyzer 1.25.0. Missing modules fail without
  network access by default; `-install-dependency` explicitly opts in to the
  pinned PSGallery install. Keep the runner and CI version aligned.
  Release updaters `update-ai-clis.ps1` and `update-xerj.ps1` also download
  upstream artifacts as their documented purpose. Keep downloads confined
  to those flows rather than adding them to launchers or checks.
- `update-ai-clis.ps1` verifies Codex, OpenCode, Crush and Copilot release archives
  against the GitHub asset digest and reads only the expected executable
  entries. Claude Code uses Anthropic's stable channel, its manifest size and
  SHA-256, and a valid Authenticode signature from `Anthropic, PBC`. These
  native distributions avoid installing package-manager language runtimes.
  PowerShell profile wrappers (`codex --yolo`, `opencode --auto`) are opt-in
  with `-Wrappers`. Profile updates use a backup and atomic replacement.
- Swival uses a hash-verified Astral uv release and a private managed Python.
  Keep the uv tool environment at the path used to generate the launcher.
  Verify its version before publishing the launcher and check the effective
  command from a new session. The Swival wheel and dependency index must
  come from official PyPI. Keep the Python interpreter outside user PATH.
  Validate Swival's xerj TOML using a private staging directory with no
  project configuration and keep credentials in the inherited environment.
- Probe the command actually resolved from PATH and explicitly recognize
  executable, CMD and PowerShell script candidates. Report shadowed paths
  without running every candidate. Parse semantic version tokens across
  output lines, keep the upstream stable and post-update values separate,
  and verify the expected path and version in a new profile-free shell
  using registry-backed PATH. Never count acquisition or activation alone
  as a successful update. Keep PATH changes per-user and preserve the
  registry value type and existing entry order.
- Use the canonical Codex package archive with bundled launchers, ripgrep
  and sandbox resources. Validate tar member types and paths, check the
  manifest and required binaries, and verify the staged CLI before switching
  the visible junction. Keep a working package untouched during same-version
  repair and report failed activation. Successful activation must remain
  successful if deleting a locked old copy fails.
  Associate cached releases with the upstream archive SHA-256 and hashes of
  every extracted file. Reuse only matching caches and prune only attributable
  packages. Limit native version probes in duration and output size.
- `-UpdateCodexDaemon` invokes `codex app-server daemon update` when selected
  Codex is managed and verified. The daemon selects latest stable separately
  from `-CodexVersion`. Respect `CODEX_HOME`, skip mutation with `-Check`, and
  propagate nonzero or unsupported results without skipping Crush. Never run
  this lifecycle command during validation: it may restart a running daemon.
  Use `pwsh -NoProfile -File windows/tests/test-update-ai-clis.ps1` for offline
  archive, incomplete-cache, activation-lock, daemon, and dispatch regressions.
- `update-xerj.ps1` is a release-download updater: it verifies the archive's
  SHA-256 against an exact published filename/digest line before reading only
  the expected executable entry. Keep its per-user destination and absolute
  MCP command paths. Default registration processes the installed clients.
  Validate selectors and endpoint syntax before any install or config write.
  Follow the user scopes and schemas in the
  [xerj configuration matrix](../../../docs/update-xerj.md). OpenCode V2
  uses `mcp.servers`. Leave ambiguous JSONC, conflicting unowned
  registrations and unrelated settings intact. Keep tokens out of
  arguments, diagnostics and on-disk edits.
  MCP registration does not start a node; document local authenticated startup
  and inherited `XERJ_AUTH` separately. Never run the updater for validation.
  Use `pwsh -NoProfile -File windows/tests/test-update-xerj.ps1` instead:
  it redirects configuration and install paths into temporary directories,
  mocks downloads and Codex, and checks repeated updates and failure paths.
  Resolve the default version using a HEAD request to the public release
  redirect, not the shared GitHub API quota. Validate the final repository/tag
  URL and support both Windows PowerShell's `ResponseUri` and PowerShell 7's
  `RequestMessage.RequestUri`. Pinned versions must bypass release discovery.
  Offline tests cover API unavailability and both response shapes; simulated
  Windows PowerShell responses do not prove native 5.1 execution.
- xerj activation uses unique same-directory files. Pass
  `[NullString]::Value` to `File.Replace` to avoid creating a backup. Never
  fall back to overwriting a locked target. Verify the staged executable's
  version before activation and clean up its temporary file on failure. Leave
  existing `.bak.*` files untouched.
  Check ownership, write permissions and ancestor path types before staging
  releases in the temporary or installation directory and before writing MCP
  configuration. Recheck newly created directories before writing.
  OpenCode requires an exact GitHub release asset/digest and one regular root
  executable entry; Crush requires `crush.exe` in the expected versioned archive
  folder. Reject duplicates and checksum failures before activation.
- The validator now checks that `psfmt.ps1` exists and declares PowerShell 7,
  and that the launcher mentions `pwsh.exe` and `powershell.exe`. It still does
  not execute any of them.
- The installer discovery check requires the literal `collect_ps_program`
  token rather than the `windows\*.ps1` glob: `findstr /l /c:` is unreliable
  for patterns containing both a backslash and `*`. Keep that function name
  stable or update the validator with the change.
- Isolated Windows profiles may grant a sandbox identity write access to
  `%LOCALAPPDATA%` and `%TEMP%`. Keep those ACLs untrusted; the installer may
  fall back to `%USERPROFILE%\Programs` and private staging under the profile
  only after validating those paths.

## Maintenance & Continuous Learning

After using this skill to modify the repository, review this skill and the
applicable agent instructions as part of the task's final synchronization
step. Update this skill when procedures, tools, configuration, assumptions,
validation commands, or reusable knowledge have changed. Correct guidance
that proved inaccurate and keep examples and validation steps aligned with
the repository. Add only knowledge that will help future work; omit
execution-specific notes and cosmetic edits. Review affected specialized
agent instructions for consistency and run
`make check-agent-knowledge` (or
`perl scripts/validate-agent-knowledge.pl --scope worktree`). The automated check
covers structure and resolvable local references; semantic relevance still
requires review. Report the synchronization result in the final summary and
do not claim completion if it was skipped or failed.

## References

- [Root agent instructions](../../../AGENTS.md)
- [Windows scripts](../../../windows/README.md)
- [psfmt documentation](../../../windows/test-format/README.md)
- [psfmt tests](../../../windows/test-format/tests/README.md)
- [Windows installer validator](../../../tests-format/validate-windows-installer.bat)
- [Perl manifest](../../../perl/programs.txt)
