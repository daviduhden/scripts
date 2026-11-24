#requires -Version 7.0
# Offline, Windows-only tests for installer and history path validation.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'These ACL and junction checks require Windows.' }

. (Join-Path $PSScriptRoot '../install-support/trust.ps1')
$root = Initialize-InstallStage
$purge = Join-Path $PSScriptRoot '../ai-purge-history.ps1'
$variables = @('CODEX_HOME', 'COPILOT_HOME', 'OPENCODE_DATA_HOME', 'OPENCODE_STATE_HOME', 'SWIVAL_PROJECT_HOME',
    'CLAUDE_CONFIG_DIR')
$previous = @{}

function Assert-RejectedPath {
    param([string]$Candidate)
    $rejected = $false
    try { $null = Assert-InstallPath $Candidate -Directory }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'An unsafe path was accepted.' }
}

try {
    foreach ($name in $variables) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, (Join-Path $root $name))
    }
    $codex = Join-Path $root 'CODEX_HOME'
    $sessions = Join-Path $codex 'sessions'
    $null = New-Item -ItemType Directory -Path $sessions -Force
    $file = Join-Path $sessions 'fixture.txt'
    [IO.File]::WriteAllText($file, 'keep')
    $null = Assert-InstallPath $codex -Directory
    $claude = $env:CLAUDE_CONFIG_DIR
    $project = Join-Path $claude 'projects/example'
    $memory = Join-Path $project 'memory/subagents'
    $subagents = Join-Path $project 'session/subagents'
    $null = New-Item -ItemType Directory -Path $memory, $subagents -Force
    $selected = @((Join-Path $claude 'history.jsonl'), (Join-Path $project 'session.jsonl'),
        (Join-Path $project 'session.jsonl.superseded-1'), (Join-Path $subagents 'agent.jsonl'))
    $preserved = @((Join-Path $claude 'settings.json'), (Join-Path $claude '.credentials.json'),
        (Join-Path $memory 'notes.jsonl'))
    foreach ($path in ($selected + $preserved)) { [IO.File]::WriteAllText($path, 'fixture') }
    $preview = & $purge -DryRun 6>&1 | Out-String
    foreach ($path in $selected) {
        if (-not $preview.Contains([IO.Path]::GetFullPath($path)) -or -not [IO.File]::Exists($path)) {
            throw "Claude dry run missed a transcript or changed it: $path"
        }
    }
    foreach ($path in $preserved) {
        if ($preview.Contains([IO.Path]::GetFullPath($path)) -or -not [IO.File]::Exists($path)) {
            throw "Claude dry run selected a preserved file: $path"
        }
    }
    if (-not [IO.File]::Exists($file)) { throw 'The dry run modified history.' }

    $writable = Join-Path $root 'shared'
    $null = New-Item -ItemType Directory -Path $writable
    $acl = Get-Acl -LiteralPath $writable
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Write', 'Allow'))
    Set-Acl -LiteralPath $writable -AclObject $acl
    Assert-RejectedPath $writable

    $junction = Join-Path $root 'junction'
    $null = New-Item -ItemType Junction -Path $junction -Target $codex
    try {
        Assert-RejectedPath (Join-Path $junction 'sessions')
        $env:CODEX_HOME = $junction
        $rejected = $false
        try { & $purge -DryRun }
        catch { $rejected = $true }
        if (-not $rejected -or -not [IO.File]::Exists($file)) {
            throw 'The history dry run accepted a junction ancestor or modified history.'
        }
    }
    finally { [IO.Directory]::Delete($junction, $false) }
    Write-Output 'PASS: private installer paths and history dry-run validation'
}
finally {
    foreach ($name in $variables) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
