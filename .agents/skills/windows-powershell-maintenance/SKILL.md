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
without one.

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
   - keep `PERL_MODULES` aligned with the runtime modules required by the
     installed Perl programs, including Windows-specific bundled modules;
   - keep the dry-run path free of writes, packaging, and PATH changes.
3. For a new top-level `windows/*.ps1`, the installer picks it up
   automatically and creates `<name>.cmd`. For a new public Perl program,
   add it to `perl/programs.txt`; both the POSIX and Windows installers read
   that manifest.
4. For `psfmt.ps1`, preserve the four mutually exclusive modes and their exit
   codes: `0` success, `1` error, `2` formatting needed in `-c` mode. Keep
   encoding/BOM/newline preservation and the atomic replace path.
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
- `-RemoveWinget` removes the winget copies of OpenCode and Codex, not Bun;
  keep the documentation aligned with that behavior.
- `ai-purge-history.ps1` removes the entire `%LOCALAPPDATA%\crush` directory,
  which can include configuration; do not describe it as configuration-safe.
  Use `-DryRun` to preview.
- `psfmt.ps1` auto-installs PSScriptAnalyzer from PSGallery when missing. That
  is the explicit exception to the no-download rule; do not add others.
- The validator now checks that `psfmt.ps1` exists and declares PowerShell 7,
  and that the launcher mentions `pwsh.exe` and `powershell.exe`. It still does
  not execute any of them.

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
`python3 scripts/validate-agent-knowledge.py --scope worktree .`). The automated check
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
