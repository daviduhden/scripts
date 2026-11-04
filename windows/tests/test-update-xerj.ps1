#requires -Version 7.0
# See the LICENSE file at the top of the project tree for copyright
# and license details.
# Offline integration tests. No downloaded binary or client is executed.
# Test doubles must shadow the download cmdlet and share state across the
# updater's script scope. The signature matches Invoke-WebRequest on purpose.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('xerj-tests-' + [guid]::NewGuid().ToString('N'))
$originalLocal = $env:LOCALAPPDATA
$originalConfig = $env:XDG_CONFIG_HOME
$originalCodex = $env:CODEX_HOME
$updater = Join-Path $PSScriptRoot '../update-xerj.ps1'
$global:xerjTestBadDigest = $false
$global:xerjTestCodexCalls = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function codex {
    $global:xerjTestCodexCalls++
    Assert-True ($args[0] -eq 'mcp' -and $args[1] -eq 'add' -and $args[2] -eq 'xerj') 'Unexpected Codex invocation'
    $global:LASTEXITCODE = 0
}

function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    if ($Uri.EndsWith('.sha256')) {
        $archive = $OutFile.Substring(0, $OutFile.Length - 7)
        $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($global:xerjTestBadDigest) { $digest = '0' * 64 }
        [IO.File]::WriteAllText($OutFile, "$digest  $([IO.Path]::GetFileName($archive))`r`n")
    }
    else {
        $zip = [IO.Compression.ZipFile]::Open($OutFile, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $directory = [IO.Path]::GetFileNameWithoutExtension($OutFile)
            $entry = $zip.CreateEntry("$directory/xerj.exe")
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('fixture binary; never execute') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose() }
    }
}

try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'local'
    $env:XDG_CONFIG_HOME = Join-Path $testRoot "config with spaces and 'quote"
    $env:CODEX_HOME = Join-Path $testRoot 'codex'
    $null = New-Item -ItemType Directory -Force (Join-Path $env:XDG_CONFIG_HOME 'crush'), (Join-Path $env:XDG_CONFIG_HOME 'opencode'), $env:CODEX_HOME
    $crushConfig = Join-Path $env:XDG_CONFIG_HOME 'crush/crushrc'
    $openConfig = Join-Path $env:XDG_CONFIG_HOME 'opencode/opencode.json'
    Set-Content $crushConfig '# retained user configuration'
    Set-Content $openConfig '{"theme":"test","mcp":{"existing":{"type":"local","command":["example"]}}}'
    Set-Content (Join-Path $env:CODEX_HOME 'config.toml') '# retained Codex configuration'
    & $updater -Version 'v1.2.3' -Codex -Crush -OpenCode
    Assert-True ($LASTEXITCODE -eq 0) 'First installation failed'
    $binary = Join-Path $env:LOCALAPPDATA 'Programs/xerj/xerj.exe'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Wrong binary content'
    & $updater -Version 'v1.2.3' -Codex -Crush -OpenCode -Url 'http://127.0.0.1:9300'
    Assert-True ($LASTEXITCODE -eq 0) 'Repeated update failed'
    $config = Get-Content -Raw $openConfig | ConvertFrom-Json
    Assert-True ($config.theme -eq 'test' -and $config.mcp.existing.command[0] -eq 'example') 'Other OpenCode settings lost'
    Assert-True ($config.mcp.xerj.command[3] -eq 'http://127.0.0.1:9300') 'Endpoint was not updated'
    $crushText = Get-Content -Raw $crushConfig
    Assert-True ($crushText.Contains('# retained user configuration')) 'Crush settings lost'
    Assert-True ([regex]::Matches($crushText, '# BEGIN xerj managed').Count -eq 1) 'Duplicate managed blocks'
    Assert-True ($global:xerjTestCodexCalls -eq 2) 'Codex was not registered twice'
    Assert-True (@(Get-ChildItem "$openConfig.bak.*").Count -eq 2) 'Expected configuration backups'
    $before = Get-Content -Raw $openConfig
    $global:xerjTestBadDigest = $true
    & $updater -Version 'v1.2.3' -OpenCode -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Bad checksum accepted'
    Assert-True ((Get-Content -Raw $openConfig) -eq $before) 'Configuration changed after checksum failure'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Binary changed after checksum failure'
    $global:xerjTestBadDigest = $false
    Set-Content ([IO.Path]::ChangeExtension($openConfig, '.jsonc')) '// retain this file'
    & $updater -Version 'v1.2.3' -OpenCode -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Ambiguous JSONC was accepted'
    Assert-True ((Get-Content -Raw $openConfig) -eq $before) 'JSON changed despite JSONC refusal'
    Write-Output 'PASS: install, repeated update, backups, preserved settings, Codex registration, checksum rejection, JSONC refusal'
}
finally {
    $env:LOCALAPPDATA = $originalLocal
    $env:XDG_CONFIG_HOME = $originalConfig
    $env:CODEX_HOME = $originalCodex
    Remove-Variable -Name xerjTestBadDigest, xerjTestCodexCalls -Scope Global
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path $resolved) -eq $tempRoot -and (Split-Path $resolved -Leaf) -match '^xerj-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
