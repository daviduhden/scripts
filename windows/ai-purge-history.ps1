#!/usr/bin/env pwsh

# AI assistant history cleanup for Windows.
# - Removes session history for Codex and GitHub Copilot.
# - Removes OpenCode prompt history, database files and logs.
# - Removes project-local Swival history/state.
# - Keeps Codex/Copilot/OpenCode configuration and credentials intact.
# - Preserves the Crush data directory unless -IncludeCrushData is given.
#   That switch removes the entire directory, including any configuration
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
    [switch]$IncludeCrushData,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    $helpText = @'
Usage: ai-purge-history.ps1 [-DryRun] [-IncludeCrushData] [-Help]

Removes Codex, Copilot, OpenCode, and project-local Swival history/state for
the current user. Codex/Copilot/OpenCode configuration and credentials are
kept. Crush data is preserved unless -IncludeCrushData is given; that switch
removes the whole Crush data directory, including any configuration stored
there.

  -DryRun             Show the paths that would be removed, delete nothing
  -IncludeCrushData   Also remove the whole Crush data directory
  -Help               Show this help
'@
    Write-Output $helpText
    exit 0
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
$opencodeDataHome = if ($env:OPENCODE_DATA_HOME) { $env:OPENCODE_DATA_HOME } else { Join-Path $env:LOCALAPPDATA 'opencode' }
$opencodeStateHome = if ($env:OPENCODE_STATE_HOME) { $env:OPENCODE_STATE_HOME } else { Join-Path $env:LOCALAPPDATA 'opencode' }
$crushDataHome = if ($env:CRUSH_GLOBAL_DATA) { $env:CRUSH_GLOBAL_DATA } else { Join-Path $env:LOCALAPPDATA 'crush' }
$swivalProjectHome = if ($env:SWIVAL_PROJECT_HOME) { $env:SWIVAL_PROJECT_HOME } else { (Get-Location).Path }

function Resolve-HistoryRoot {
    param([string]$Path)

    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'History roots must be absolute paths on a local filesystem.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($protected in @([IO.Path]::GetPathRoot($Path), $HOME, $env:LOCALAPPDATA, $env:APPDATA,
            $env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, $env:ProgramData)) {
        if (-not $protected) { continue }
        $protected = [IO.Path]::GetFullPath($protected).TrimEnd('\', '/')
        if ($protected -ieq $full -or $protected.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing broad history root: $full"
        }
    }
    return $full
}

function Assert-HistoryTarget {
    param([string]$Path, [bool]$Directory)

    # Inspect every ancestor and the leaf before recursing. Missing paths
    # are harmless, but a file masquerading as an ancestor is not.
    $current = $Path
    $isDirectory = $Directory
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                [bool]$item.PSIsContainer -ne $isDirectory)) {
            throw "Refusing an unexpected history file type or reparse path: $current"
        }
        $isDirectory = $true
        $current = [IO.Path]::GetDirectoryName($current)
    }
    if (-not $Directory -or -not [IO.Directory]::Exists($Path)) { return }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        foreach ($child in Get-ChildItem -LiteralPath ($pending.Pop()) -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a reparse point in a history directory: $($child.FullName)"
            }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

function Get-HistoryTarget {
    param([string]$Root, [string[]]$Files, [string[]]$Directories)

    $resolvedRoot = Resolve-HistoryRoot $Root
    foreach ($name in @($Files) + @($Directories)) {
        if (-not $name) { continue }
        $path = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $name))
        if (-not $path.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'History target escapes the application root.'
        }
        [pscustomobject]@{ Path = $path; Directory = $name -in $Directories }
    }
}

function Remove-HistoryTarget {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [bool]$Directory)

    Assert-HistoryTarget $Path $Directory
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) {
        Write-Information "[DRY-RUN] Would remove: $Path" -InformationAction Continue
    }
    elseif ($PSCmdlet.ShouldProcess($Path, 'Remove history or state')) {
        Remove-Item -LiteralPath $Path -Recurse:$Directory -Force
        Write-Information "[INFO] Removed: $Path" -InformationAction Continue
    }
}

$paths = @(
    Get-HistoryTarget $codexHome -Directories @('sessions', 'archived_sessions')
    Get-HistoryTarget $copilotHome -Directories @('session-state', 'logs')
    Get-HistoryTarget $opencodeStateHome -Files @('prompt-history.jsonl')
    Get-HistoryTarget $opencodeDataHome -Files @('opencode.db', 'opencode.db-wal', 'opencode.db-shm') -Directories @('log')
    Get-HistoryTarget (Join-Path $swivalProjectHome '.swival') -Files @('HISTORY.md', 'HISTORY.md.lock', 'continue.md',
        'repl_history', 'cache.db') -Directories @('memory', 'audit')
)
if ($IncludeCrushData) {
    $paths += [pscustomobject]@{ Path = Resolve-HistoryRoot $crushDataHome; Directory = $true }
}

# Preflight all selected targets before deleting any of them.
foreach ($target in $paths) { Assert-HistoryTarget $target.Path $target.Directory }
foreach ($target in $paths) { Remove-HistoryTarget $target.Path $target.Directory }
if (-not $IncludeCrushData) {
    Write-Information "[INFO] Preserving Crush data directory (use -IncludeCrushData to remove it): $crushDataHome" -InformationAction Continue
}

if ($DryRun) {
    Write-Information '[INFO] Dry run complete; no files were removed.' -InformationAction Continue
}
else {
    Write-Information '[INFO] AI assistant history purged for Windows' -InformationAction Continue
}
