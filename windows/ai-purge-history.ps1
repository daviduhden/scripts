#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
$opencodeDataHome = if ($env:OPENCODE_DATA_HOME) { $env:OPENCODE_DATA_HOME } else { Join-Path $env:LOCALAPPDATA 'opencode' }
$crushDataHome = if ($env:CRUSH_GLOBAL_DATA) { $env:CRUSH_GLOBAL_DATA } else { Join-Path $env:LOCALAPPDATA 'crush' }
$swivalProjectHome = if ($env:SWIVAL_PROJECT_HOME) { $env:SWIVAL_PROJECT_HOME } else { (Get-Location).Path }

$paths = @(
    (Join-Path $codexHome 'sessions'),
    (Join-Path $codexHome 'archived_sessions'),
    (Join-Path $copilotHome 'session-state'),
    (Join-Path $copilotHome 'logs'),
    (Join-Path $opencodeDataHome 'prompt-history.jsonl'),
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

foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

Write-Output 'AI assistant history purged for Windows'
