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
$variables = @('CODEX_HOME', 'COPILOT_HOME', 'OPENCODE_DATA_HOME', 'OPENCODE_STATE_HOME', 'SWIVAL_PROJECT_HOME')
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
    & $purge -DryRun
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
