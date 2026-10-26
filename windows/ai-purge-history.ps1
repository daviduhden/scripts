#!/usr/bin/env pwsh

# AI assistant history cleanup for Windows.
# - Removes session history for Codex and GitHub Copilot.
# - Removes OpenCode prompt history, database files and logs.
# - Removes Crush data and project-local Swival history/state.
# - Keeps Codex/Copilot/OpenCode configuration and credentials intact.
# - Removes the entire Crush data directory, including any configuration
#   stored there.
# - Use -DryRun to preview without deleting anything.
#
# Set SWIVAL_PROJECT_HOME to select the project whose .swival state is purged.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    $helpText = @'
Usage: ai-purge-history.ps1 [-DryRun] [-Help]

Removes Codex, Copilot, OpenCode, Crush, and project-local Swival
history/state for the current user. Codex/Copilot/OpenCode configuration is
kept; the whole Crush data directory is removed.

  -DryRun  Show the paths that would be removed, delete nothing
  -Help    Show this help
'@
    Write-Host $helpText
    exit 0
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
$opencodeDataHome = if ($env:OPENCODE_DATA_HOME) { $env:OPENCODE_DATA_HOME } else { Join-Path $env:LOCALAPPDATA 'opencode' }
$opencodeStateHome = if ($env:OPENCODE_STATE_HOME) { $env:OPENCODE_STATE_HOME } else { Join-Path $env:LOCALAPPDATA 'opencode' }
$crushDataHome = if ($env:CRUSH_GLOBAL_DATA) { $env:CRUSH_GLOBAL_DATA } else { Join-Path $env:LOCALAPPDATA 'crush' }
$swivalProjectHome = if ($env:SWIVAL_PROJECT_HOME) { $env:SWIVAL_PROJECT_HOME } else { (Get-Location).Path }

# Missing targets are ignored, so an installation that never created one of
# these paths is not an error.
$paths = @(
    (Join-Path $codexHome 'sessions'),
    (Join-Path $codexHome 'archived_sessions'),
    (Join-Path $copilotHome 'session-state'),
    (Join-Path $copilotHome 'logs'),
    (Join-Path $opencodeStateHome 'prompt-history.jsonl'),
    (Join-Path $opencodeDataHome 'opencode.db'),
    (Join-Path $opencodeDataHome 'opencode.db-wal'),
    (Join-Path $opencodeDataHome 'opencode.db-shm'),
    (Join-Path $opencodeDataHome 'log'),
    $crushDataHome,
    (Join-Path $swivalProjectHome '.swival\HISTORY.md'),
    (Join-Path $swivalProjectHome '.swival\HISTORY.md.lock'),
    (Join-Path $swivalProjectHome '.swival\continue.md'),
    (Join-Path $swivalProjectHome '.swival\repl_history'),
    (Join-Path $swivalProjectHome '.swival\memory'),
    (Join-Path $swivalProjectHome '.swival\cache.db'),
    (Join-Path $swivalProjectHome '.swival\audit')
)

<#
.SYNOPSIS
    Removes one history or state path unless -DryRun is set.
.PARAMETER Path
    Literal file or directory path. A missing path is ignored.
.NOTES
    Directories are removed recursively with -Recurse -Force, so the whole tree
    is deleted. $ErrorActionPreference is Stop, which makes a removal failure
    terminate the script.
#>
function Remove-Target {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would remove: $Path"
        }
        else {
            Remove-Item -LiteralPath $Path -Recurse -Force
            Write-Host "[INFO] Removed: $Path"
        }
    }
}

foreach ($path in $paths) {
    Remove-Target -Path $path
}

if ($DryRun) {
    Write-Host '[INFO] Dry run complete; no files were removed.'
}
else {
    Write-Host '[INFO] AI assistant history purged for Windows'
}
