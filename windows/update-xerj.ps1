#!/usr/bin/env pwsh

# xerj installer and updater for Windows.
# - Installs a checksum-verified release for the current user without admin.
# - Optional -Codex, -Crush and -OpenCode register stdio MCP with backups.
# - Does not change PATH or profiles, or start the engine.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
<#
.SYNOPSIS
Installs or updates xerj for the current user and optionally registers MCP.
.EXAMPLE
./update-xerj.ps1 -Codex -Crush -OpenCode
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Codex,
    [switch]$Crush,
    [switch]$OpenCode,
    [string]$Url = 'http://127.0.0.1:9200'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Information "[INFO] $Message" -InformationAction Continue
}

function Write-Fail {
    param([string]$Message)
    Write-Information "[ERROR] $Message" -InformationAction Continue
}

# Both paths must be in the destination directory. File.Replace preserves the
# old destination if a locked executable or another failure prevents activation.
function Complete-FileReplacement {
    param([string]$Pending, [string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace a directory or reparse point: $Path"
        }
        $backup = "$Path.bak.$([guid]::NewGuid().ToString('N'))"
        try {
            [IO.File]::Replace($Pending, $Path, $backup)
        }
        catch {
            if (Test-Path -LiteralPath $backup) { Write-Info "Recovery copy retained at $backup" }
            throw
        }
        # Keep the recovery copy: callers can recover the prior version/config.
        Write-Info "Previous file retained at $backup"
    }
    else {
        [IO.File]::Move($Pending, $Path)
    }
}

function Save-Config {
    param([string]$Path, [string]$Text)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        Complete-FileReplacement $temporary $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function ConvertTo-BashLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# ---------------------------------------------------------------------------
# Install and configure
# ---------------------------------------------------------------------------
$stage = $null
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
    if ($Codex) { $null = Get-Command codex -ErrorAction Stop }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($architecture) {
        'X64' { $target = 'x86_64' }
        'Arm64' { $target = 'aarch64' }
        default { throw "Unsupported architecture: $architecture" }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $Version) {
        $Version = (Invoke-RestMethod 'https://api.github.com/repos/xerj-org/xerj/releases/latest').tag_name
    }
    $tag = 'v' + $Version.TrimStart('v')
    if ($tag -cnotmatch '^v[0-9][A-Za-z0-9.+-]*$') { throw 'Invalid release tag.' }
    $asset = "xerj-$($tag.Substring(1))-$target-pc-windows-msvc.zip"
    $base = "https://github.com/xerj-org/xerj/releases/download/$tag"
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('update-xerj-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    $archive = Join-Path $stage $asset
    Invoke-WebRequest "$base/$asset" -OutFile $archive -UseBasicParsing
    Invoke-WebRequest "$base/$asset.sha256" -OutFile "$archive.sha256" -UseBasicParsing
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines = [IO.File]::ReadAllLines("$archive.sha256")
    if ($lines -cnotcontains "$digest  $asset" -and $lines -cnotcontains "$digest *$asset") {
        throw 'SHA-256 mismatch; refusing installation.'
    }
    # Read only the expected entry; do not extract archive paths.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $expected = "$($asset.Substring(0, $asset.Length - 4))/xerj.exe"
        $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $expected })
        if ($entries.Count -ne 1) { throw 'Expected exactly one xerj.exe in release.' }
        $entry = $entries[0]
        if ($entry.Length -le 0 -or $entry.Length -gt 536870912 -or
            (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
            throw 'Invalid executable entry in release.'
        }
        $root = Join-Path $env:LOCALAPPDATA 'Programs/xerj'
        $null = New-Item -ItemType Directory -Force -Path $root
        $binary = Join-Path $root 'xerj.exe'
        $pending = Join-Path $root ('.xerj-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $pending)
            Complete-FileReplacement $pending $binary
        }
        finally {
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
        }
    }
    finally { $zip.Dispose() }
    Write-Info "Installed $tag at $binary"
    # MCP uses an absolute executable path; no PATH/profile changes are needed.
    if ($Codex) {
        $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        $config = Join-Path $codexRoot 'config.toml'
        if (Test-Path -LiteralPath $config) {
            Copy-Item -LiteralPath $config -Destination "$config.bak.$([guid]::NewGuid().ToString('N'))"
        }
        & codex mcp add xerj -- $binary mcp --url $Url
        if ($LASTEXITCODE -ne 0) { throw 'Codex MCP registration failed.' }
    }
    $configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    if ($Crush) {
        $config = Join-Path $configRoot 'crush/crushrc'
        $old = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { '' }
        $begin = '# BEGIN xerj managed'
        $end = '# END xerj managed'
        $starts = [regex]::Matches($old, [regex]::Escape($begin)).Count
        $ends = [regex]::Matches($old, [regex]::Escape($end)).Count
        if ($starts -ne $ends -or $starts -gt 1) { throw 'Malformed xerj managed block.' }
        $text = [regex]::Replace($old, '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?', '')
        $command = ConvertTo-BashLiteral ($binary.Replace('\', '/'))
        $endpoint = ConvertTo-BashLiteral $Url
        $text = $text.TrimEnd() + "`n$begin`nmcp add xerj --type stdio --command $command --args mcp --args --url --args $endpoint`n$end`n"
        Save-Config $config $text
    }
    if ($OpenCode) {
        $config = Join-Path $configRoot 'opencode/opencode.json'
        if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($config, '.jsonc'))) {
            throw 'Merge xerj into existing opencode.jsonc manually; refusing ambiguous configuration.'
        }
        $data = if (Test-Path -LiteralPath $config) {
            [IO.File]::ReadAllText($config) | ConvertFrom-Json
        }
        else { [pscustomobject]@{} }
        if (-not ($data -is [pscustomobject])) { throw 'OpenCode config must be a JSON object.' }
        if (-not $data.PSObject.Properties['mcp']) {
            $data | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{})
        }
        if (-not ($data.mcp -is [pscustomobject])) { throw 'OpenCode mcp must be a JSON object.' }
        $entry = [pscustomobject]@{ type = 'local'; command = @($binary, 'mcp', '--url', $Url); enabled = $true }
        $data.mcp | Add-Member -NotePropertyName xerj -NotePropertyValue $entry -Force
        Save-Config $config (($data | ConvertTo-Json -Depth 100) + "`n")
    }
    Write-Info 'MCP requires a running xerj node. See windows/README.md for startup and authentication.'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        # Only remove our GUID-named direct child of the system temp directory.
        $resolved = [IO.Path]::GetFullPath($stage)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        if ((Split-Path $resolved) -eq $parent -and (Split-Path $resolved -Leaf) -match '^update-xerj-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
exit 0
