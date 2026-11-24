#!/usr/bin/env pwsh

# AI assistant history cleanup for Windows.
# - Removes session history for Codex, GitHub Copilot, and Claude Code.
# - Removes OpenCode prompt history and sessions through the OpenCode CLI.
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
    [switch]$All,
    [switch]$Codex,
    [Alias('CopilotCli', 'copilot-cli')]
    [switch]$Copilot,
    [switch]$Claude,
    [switch]$OpenCode,
    [switch]$Crush,
    [switch]$Swival,
    [switch]$IncludeCrushData,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    $helpText = @'
Usage: ai-purge-history.ps1 [-Codex] [-Copilot] [-Claude] [-OpenCode] [-Crush] [-Swival]
                            [-All] [-DryRun] [-IncludeCrushData] [-Help]

Without selectors, the default agents are selected. -All selects the default
agents and cannot be combined with individual selectors. OpenCode 2 sessions
are scoped to the current project. -Crush requires -IncludeCrushData.

  -DryRun             Show the paths that would be removed, delete nothing
  -IncludeCrushData   Also remove the whole Crush data directory
  -Help               Show this help
'@
    Write-Output $helpText
    exit 0
}

$explicitSelection = $Codex -or $Copilot -or $Claude -or $OpenCode -or $Crush -or $Swival
if ($All -and $explicitSelection) { throw '-All cannot be combined with agent selectors.' }
if ($Crush -and -not $IncludeCrushData) {
    throw '-Crush requires -IncludeCrushData (removes the entire Crush data directory).'
}
if ($explicitSelection -and $IncludeCrushData -and -not $Crush) {
    throw 'Select -Crush to use -IncludeCrushData with individual selectors.'
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$opencodeStateHome = if ($env:OPENCODE_STATE_HOME) { $env:OPENCODE_STATE_HOME }
elseif ($env:XDG_STATE_HOME) { Join-Path $env:XDG_STATE_HOME 'opencode' }
else { Join-Path $HOME '.local/state/opencode' }
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
    param([string]$Path, [bool]$Directory, [switch]$SkipDescendants)

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
    if ($SkipDescendants -or -not $Directory -or -not [IO.Directory]::Exists($Path)) { return }

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

function Get-ClaudeHistoryTarget {
    param([string]$Root)

    $resolved = Resolve-HistoryRoot $Root
    $projects = Join-Path $resolved 'projects'
    Assert-HistoryTarget $projects $true -SkipDescendants
    Get-HistoryTarget $resolved -Files @('history.jsonl')
    if (-not [IO.Directory]::Exists($projects)) { return }

    foreach ($project in Get-ChildItem -LiteralPath $projects -Directory -Force) {
        Assert-HistoryTarget $project.FullName $true -SkipDescendants
        $children = Get-ChildItem -LiteralPath $project.FullName -Force
        foreach ($entry in $children) {
            if (-not $entry.PSIsContainer) {
                if ($entry.Name -like '*.jsonl' -or $entry.Name -like '*.jsonl.superseded-*') {
                    [pscustomobject]@{ Path = $entry.FullName; Directory = $false }
                }
                continue
            }
            if ($entry.Name -ieq 'memory') { continue }
            Assert-HistoryTarget $entry.FullName $true -SkipDescendants
            $subagents = Join-Path $entry.FullName 'subagents'
            Assert-HistoryTarget $subagents $true -SkipDescendants
            if (-not [IO.Directory]::Exists($subagents)) { continue }
            foreach ($transcript in Get-ChildItem -LiteralPath $subagents -File -Filter '*.jsonl' -Force) {
                [pscustomobject]@{ Path = $transcript.FullName; Directory = $false }
            }
        }
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

function Clear-OpenCodeSession {
    if ($DryRun) {
        Write-Information '[DRY-RUN] Would delete OpenCode sessions through the CLI if available.' -InformationAction Continue
        return
    }

    $cli = Get-Command opencode -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cli) {
        if ($explicitSelection) { throw 'OpenCode session cleanup requires opencode on PATH.' }
        Write-Warning 'OpenCode session cleanup skipped: opencode was not found.'
        return
    }

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $previous = ''
    while ($true) {
        $global:LASTEXITCODE = 0
        $batch = (& $cli.Source session list --max-count 100 --format json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'OpenCode could not list sessions.' }
        # OpenCode 1 may produce no output when no sessions remain.
        $batch = $batch.Trim()
        if (-not $batch) { return }
        if (-not $batch.StartsWith('[') -or -not $batch.EndsWith(']')) {
            throw 'OpenCode returned an invalid session list.'
        }
        try { $rows = @(ConvertFrom-Json -InputObject $batch -ErrorAction Stop) }
        catch { throw 'OpenCode returned an invalid session list.' }
        $ids = @(foreach ($row in $rows) {
                if ($row.id -isnot [string] -or $row.id -cnotmatch '\Ases_[a-zA-Z0-9]+\z') {
                    throw 'OpenCode returned an invalid session ID.'
                }
                $row.id
            })
        if (-not $ids.Count) { return }
        $fingerprint = ($ids | Sort-Object -CaseSensitive -Unique) -join ' '
        if ($fingerprint.Split(' ').Count -ne $ids.Count) { throw 'OpenCode returned duplicate session IDs.' }
        if ($fingerprint -ceq $previous) { throw 'OpenCode session deletion made no progress.' }
        $previous = $fingerprint
        foreach ($id in $ids) {
            $global:LASTEXITCODE = 0
            & $cli.Source session delete $id >$null 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'OpenCode could not delete a session.' }
        }
    }
}

$paths = @(
    if ($Claude -or -not $explicitSelection) { Get-ClaudeHistoryTarget $claudeHome }
    if ($Codex -or -not $explicitSelection) {
        Get-HistoryTarget $codexHome -Directories @('sessions', 'archived_sessions')
    }
    if ($Copilot -or -not $explicitSelection) {
        Get-HistoryTarget $copilotHome -Directories @('session-state', 'logs')
    }
    if ($OpenCode -or -not $explicitSelection) {
        Get-HistoryTarget $opencodeStateHome -Files @('prompt-history.jsonl')
    }
    if ($Swival -or -not $explicitSelection) {
        Get-HistoryTarget (Join-Path $swivalProjectHome '.swival') -Files @('HISTORY.md', 'HISTORY.md.lock', 'continue.md',
            'repl_history', 'cache.db') -Directories @('memory', 'audit')
    }
    if ($IncludeCrushData) {
        [pscustomobject]@{ Path = Resolve-HistoryRoot $crushDataHome; Directory = $true }
    }
)

# Preflight all selected file targets before deleting any history.
foreach ($target in $paths) { Assert-HistoryTarget $target.Path $target.Directory }
if ($OpenCode -or -not $explicitSelection) { Clear-OpenCodeSession }
foreach ($target in $paths) { Remove-HistoryTarget $target.Path $target.Directory }

if ($DryRun) {
    Write-Information '[INFO] Dry run complete; no files were removed.' -InformationAction Continue
}
else {
    Write-Information '[INFO] AI assistant history purged for Windows' -InformationAction Continue
}
