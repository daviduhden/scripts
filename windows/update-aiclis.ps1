#!/usr/bin/env pwsh

# Codex CLI and OpenCode CLI/TUI installer and updater for Windows.
# - Installs and updates both tools for the current user (no winget, no admin).
# - OpenCode: standalone binary downloaded from opencode.ai.
# - Codex: GitHub release zip with the three binaries plus codex-code-mode-host.
# - Keeps versioned copies and prepends the local folders to the user PATH.
# - Leaves winget installations untouched unless -RemoveWinget is given.
#
# Parameters:
# -Target All|Codex|OpenCode    Tool selection (default: All).
# -OpenCodeVersion <version>    Specific OpenCode version (default: latest).
# -CodexVersion <version>       Specific Codex version (default: latest).
# -Force                        Reinstall even if already up to date.
# -Check                        Show installed and available versions, change nothing.
# -RemoveWinget                 Uninstall the winget CLI packages after installing.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param(
    [ValidateSet('All', 'Codex', 'OpenCode')]
    [string]$Target = 'All',

    [string]$OpenCodeVersion,

    [string]$CodexVersion,

    [switch]$Force,

    [switch]$Check,

    [switch]$RemoveWinget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
$script:OpenCodeRoot    = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenCode'
$script:OpenCodeBin     = Join-Path $script:OpenCodeRoot 'bin'
$script:OpenCodeExe     = Join-Path $script:OpenCodeBin 'opencode.exe'
$script:CodexRoot       = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenAI') 'Codex'
$script:CodexBin        = Join-Path $script:CodexRoot 'bin'
$script:CodexVersions   = Join-Path $script:CodexRoot 'versions'
$script:CodexExe        = Join-Path $script:CodexBin 'codex.exe'
$script:OpenCodeMetaUrl = 'https://opencode.ai/update/api/latest/cli/npm'
$script:CodexLatestApi  = 'https://api.github.com/repos/openai/codex/releases/latest'
$script:PathChanged     = $false
$script:ManagedDirs     = @()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-PlatformTag {
    $arch = $null
    try {
        $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    } catch {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }
    switch -Regex ($arch) {
        '^(X64|AMD64)$' { return 'x64' }
        '^Arm64$'       { return 'arm64' }
        default         { throw "Unsupported architecture: $arch" }
    }
}

function Normalize-Version {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    $v = $v -replace '(?i)^rust-', ''
    $v = $v -replace '(?i)^v', ''
    return $v
}

function Get-ExeVersion {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = & $ExePath --version 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        $token = ($out -split '\s+')[-1]
        return (Normalize-Version $token)
    } catch {
        return $null
    }
}

function Test-VersionEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    return ($A.Trim() -eq $B.Trim())
}

function Add-PathEntry {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }

    # Deterministic order: managed directories go first, always in the same
    # order, so repeated runs do not rewrite PATH.
    $normalized = $Directory.TrimEnd('\')
    $known = @($script:ManagedDirs | Where-Object { $_.TrimEnd('\') -ieq $normalized }).Count -gt 0
    if (-not $known) { $script:ManagedDirs += $Directory }

    # Persistent user PATH (prepend so we win over winget).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $entries = @($userPath -split ';' | Where-Object {
        $value = $_.TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($value)) { return $false }
        return -not (@($script:ManagedDirs | Where-Object { $_.TrimEnd('\') -ieq $value }).Count)
    })
    $newUserPath = (@($script:ManagedDirs) + $entries) -join ';'
    if ($newUserPath -ne $userPath) {
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-Info "User PATH updated: $Directory"
        $script:PathChanged = $true
    }

    # Current process PATH so we can verify immediately.
    $procEntries = @($env:Path -split ';' | Where-Object {
        $value = $_.TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($value)) { return $false }
        return -not (@($script:ManagedDirs | Where-Object { $_.TrimEnd('\') -ieq $value }).Count)
    })
    $env:Path = (@($script:ManagedDirs) + $procEntries) -join ';'
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
            return
        } catch {
            if ($i -eq $attempts) { throw }
            Write-Warn "Download failed (attempt $i/$attempts): $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
}

function Get-RemoteText {
    param([string]$Uri, [hashtable]$Headers)
    if ($null -eq $Headers) { $Headers = @{} }
    return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -Headers $Headers).Content
}

function Set-CurrentExe {
    param([string]$SourceExe, [string]$TargetExe)

    $stamp = [DateTime]::Now.ToString('yyyyMMddHHmmss')
    $oldExe = "$TargetExe.old-$stamp"
    $moved = $false

    if (Test-Path -LiteralPath $TargetExe) {
        try {
            Move-Item -LiteralPath $TargetExe -Destination $oldExe -Force
            $moved = $true
        } catch {
            # If it cannot be moved (for example, because it is locked), we try to overwrite it.
        }
    }

    try {
        Copy-Item -LiteralPath $SourceExe -Destination $TargetExe -Force
    } catch {
        if ($moved -and -not (Test-Path -LiteralPath $TargetExe)) {
            Move-Item -LiteralPath $oldExe -Destination $TargetExe -Force
        }
        throw
    }

    if ($moved) {
        Remove-Item -LiteralPath $oldExe -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# OpenCode
# ---------------------------------------------------------------------------
function Get-OpenCodeLatestVersion {
    $raw = Get-RemoteText -Uri $script:OpenCodeMetaUrl
    $meta = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($meta.version)) {
        throw 'Could not resolve the latest OpenCode version.'
    }
    return (Normalize-Version $meta.version)
}

function Remove-OldOpenCodeVersions {
    param([string]$CurrentVersion, [int]$Keep = 3)

    $versionsDir = Join-Path $script:OpenCodeRoot 'versions'
    if (-not (Test-Path -LiteralPath $versionsDir)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $versionsDir -Directory |
        Where-Object { $_.Name -ne $CurrentVersion } |
        Sort-Object -Property LastWriteTime -Descending)

    $dirs | Select-Object -Skip ([Math]::Max($Keep - 1, 0)) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "OpenCode: removed old version $($_.Name)"
    }
}

function Install-OpenCode {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:OpenCodeExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-OpenCodeLatestVersion }
            else { $latest = Normalize-Version $Version }
        } catch {
            Write-Warn "Could not check the latest version: $($_.Exception.Message)"
        }
        Write-Info "OpenCode: installed $(if ($installed) { $installed } else { 'none' }), available $(if ($latest) { $latest } else { 'unknown' })"
        Write-Info "OpenCode: path $script:OpenCodeExe"
        return
    }

    $platform = Get-PlatformTag
    $version = Normalize-Version $Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = Get-OpenCodeLatestVersion }

    $installed = Get-ExeVersion -ExePath $script:OpenCodeExe
    if ((Test-VersionEqual $installed $version) -and -not $Force) {
        Write-Info "OpenCode: already up to date ($installed). Nothing to do."
        Add-PathEntry -Directory $script:OpenCodeBin
        return
    }

    $asset = "opencode-windows-$platform.zip"
    $url = "https://opencode.ai/files/bin/$version/$asset"
    $versionsDir = Join-Path $script:OpenCodeRoot 'versions'
    $versionDir = Join-Path $versionsDir $version
    $versionExe = Join-Path $versionDir 'opencode.exe'

    if (-not (Test-Path -LiteralPath $versionExe) -or $Force) {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("opencode-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $zip = Join-Path $tempRoot $asset
            Write-Info "OpenCode: downloading $version ($platform)"
            Invoke-Download -Uri $url -OutFile $zip

            $extractDir = Join-Path $tempRoot 'extract'
            Write-Info 'OpenCode: extracting'
            Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force

            $found = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'opencode.exe' |
                Select-Object -First 1
            if ($null -eq $found) {
                throw 'The downloaded package does not contain opencode.exe.'
            }

            New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
            Copy-Item -LiteralPath $found.FullName -Destination $versionExe -Force
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    New-Item -ItemType Directory -Force -Path $script:OpenCodeBin | Out-Null
    Set-CurrentExe -SourceExe $versionExe -TargetExe $script:OpenCodeExe

    $verified = Get-ExeVersion -ExePath $script:OpenCodeExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "OpenCode verification failed: $script:OpenCodeExe reports '$verified' but '$version' was expected."
    }

    Write-Info "OpenCode: $verified installed to $script:OpenCodeBin"
    Add-PathEntry -Directory $script:OpenCodeBin
    Remove-OldOpenCodeVersions -CurrentVersion $version
}

# ---------------------------------------------------------------------------
# Codex
# ---------------------------------------------------------------------------
function Get-CodexLatestVersion {
    $headers = @{ 'User-Agent' = 'update-aiclis'; 'Accept' = 'application/vnd.github+json' }
    $raw = Get-RemoteText -Uri $script:CodexLatestApi -Headers $headers
    $meta = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($meta.tag_name)) {
        throw 'Could not resolve the latest Codex version.'
    }
    return (Normalize-Version $meta.tag_name)
}

function Get-CodexTarget {
    $platform = Get-PlatformTag
    switch ($platform) {
        'x64'   { return 'x86_64-pc-windows-msvc' }
        'arm64' { return 'aarch64-pc-windows-msvc' }
        default { throw "Unsupported architecture for Codex: $platform" }
    }
}

function Test-CodexManagedLayout {
    # The visible directory must be a junction to versions\<version>\bin.
    $item = Get-Item -LiteralPath $script:CodexBin -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = "$($item.Target)"
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    return ($target -like "$($script:CodexVersions)*")
}

function Set-CodexVisibleBin {
    param([string]$VersionDir)

    if (Test-Path -LiteralPath $script:CodexBin) {
        $item = Get-Item -LiteralPath $script:CodexBin -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # rmdir removes the junction without touching the target directory.
            & cmd.exe /c rmdir "$script:CodexBin" | Out-Null
        } else {
            Remove-Item -LiteralPath $script:CodexBin -Recurse -Force
        }
    }

    try {
        New-Item -ItemType Junction -Path $script:CodexBin -Target (Join-Path $VersionDir 'bin') -Force | Out-Null
    } catch {
        # No junction: copy the binaries and resources directly to the managed root.
        Write-Warn 'Codex: could not create the junction; using a direct copy instead.'
        New-Item -ItemType Directory -Force -Path $script:CodexBin | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $VersionDir 'bin') -Filter '*.exe' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:CodexBin $_.Name) -Force
        }
        $resourcesTarget = Join-Path $script:CodexRoot 'codex-resources'
        if (Test-Path -LiteralPath $resourcesTarget) { Remove-Item -LiteralPath $resourcesTarget -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $VersionDir 'codex-resources') -Destination $resourcesTarget -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $VersionDir 'codex-package.json') -Destination (Join-Path $script:CodexRoot 'codex-package.json') -Force
    }
}

function Remove-OldCodexVersions {
    param([string]$CurrentVersion, [int]$Keep = 3)

    if (-not (Test-Path -LiteralPath $script:CodexVersions)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $script:CodexVersions -Directory |
        Where-Object { $_.Name -ne $CurrentVersion } |
        Sort-Object -Property LastWriteTime -Descending)

    $dirs | Select-Object -Skip ([Math]::Max($Keep - 1, 0)) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Codex: removed old version $($_.Name)"
    }
}

function Install-Codex {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:CodexExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-CodexLatestVersion }
            else { $latest = Normalize-Version $Version }
        } catch {
            Write-Warn "Could not check the latest version: $($_.Exception.Message)"
        }
        Write-Info "Codex: installed $(if ($installed) { $installed } else { 'none' }), available $(if ($latest) { $latest } else { 'unknown' })"
        Write-Info "Codex: path $script:CodexExe"
        return
    }

    $target = Get-CodexTarget
    $version = Normalize-Version $Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = Get-CodexLatestVersion }

    $installed = Get-ExeVersion -ExePath $script:CodexExe
    $versionDir = Join-Path $script:CodexVersions $version
    $binDir = Join-Path $versionDir 'bin'
    $resourcesDir = Join-Path $versionDir 'codex-resources'
    $versionExe = Join-Path $binDir 'codex.exe'
    $codeModeHostExe = Join-Path $binDir 'codex-code-mode-host.exe'

    if ((Test-VersionEqual $installed $version) -and (Test-CodexManagedLayout) -and
        (Test-Path -LiteralPath $versionExe) -and (Test-Path -LiteralPath $codeModeHostExe) -and -not $Force) {
        Write-Info "Codex: already up to date ($installed). Nothing to do."
        Add-PathEntry -Directory $script:CodexBin
        return
    }

    if ((Test-VersionEqual $installed $version) -and -not (Test-CodexManagedLayout)) {
        Write-Info 'Codex: migrating to the managed layout (junction + GitHub package)'
    }

    if (-not (Test-Path -LiteralPath $versionExe) -or $Force) {
        $asset = "codex-$target.exe.zip"
        $url = "https://github.com/openai/codex/releases/download/rust-v$version/$asset"

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $zip = Join-Path $tempRoot $asset
            Write-Info "Codex: downloading $version ($target)"
            Invoke-Download -Uri $url -OutFile $zip

            $extractDir = Join-Path $tempRoot 'extract'
            Write-Info 'Codex: extracting'
            Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force

            $files = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File)
            $main = $files | Where-Object { $_.Name -ieq "codex-$target.exe" } | Select-Object -First 1
            $runner = $files | Where-Object { $_.Name -ieq 'codex-command-runner.exe' } | Select-Object -First 1
            $sandbox = $files | Where-Object { $_.Name -ieq 'codex-windows-sandbox-setup.exe' } | Select-Object -First 1

            if ($null -eq $main -or $null -eq $runner -or $null -eq $sandbox) {
                throw 'The zip does not contain the expected three binaries (codex, codex-command-runner, and codex-windows-sandbox-setup).'
            }

            New-Item -ItemType Directory -Force -Path $binDir | Out-Null
            New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null

            Copy-Item -LiteralPath $main.FullName -Destination (Join-Path $binDir 'codex.exe') -Force
            Copy-Item -LiteralPath $runner.FullName -Destination (Join-Path $resourcesDir 'codex-command-runner.exe') -Force
            Copy-Item -LiteralPath $sandbox.FullName -Destination (Join-Path $resourcesDir 'codex-windows-sandbox-setup.exe') -Force

            # Manifest using the same format as the official package.
            [ordered]@{
                layoutVersion = 1
                version       = $version
                target        = $target
                variant       = 'codex'
                entrypoint    = 'bin/codex.exe'
                resourcesDir  = 'codex-resources'
                pathDir       = 'codex-path'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $versionDir 'codex-package.json') -Encoding ASCII

            # System ripgrep (if present) for codex-path, same as the official package.
            $rg = Get-Command rg -ErrorAction SilentlyContinue
            if ($null -ne $rg) {
                $pathDir = Join-Path $versionDir 'codex-path'
                New-Item -ItemType Directory -Force -Path $pathDir | Out-Null
                Copy-Item -LiteralPath $rg.Source -Destination (Join-Path $pathDir 'rg.exe') -Force
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # codex-code-mode-host.exe ships in a separate GitHub zip (optional component).
    if (-not (Test-Path -LiteralPath $codeModeHostExe) -or $Force) {
        try {
            $hostAsset = "codex-code-mode-host-$target.exe.zip"
            $hostUrl = "https://github.com/openai/codex/releases/download/rust-v$version/$hostAsset"

            $hostTemp = Join-Path ([IO.Path]::GetTempPath()) ("codex-code-mode-host-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $hostTemp | Out-Null
            try {
                $hostZip = Join-Path $hostTemp $hostAsset
                Write-Info "Codex: downloading $hostAsset"
                Invoke-Download -Uri $hostUrl -OutFile $hostZip

                $hostExtract = Join-Path $hostTemp 'extract'
                Write-Info 'Codex: extracting'
                Expand-Archive -LiteralPath $hostZip -DestinationPath $hostExtract -Force

                $hostExe = Get-ChildItem -LiteralPath $hostExtract -Recurse -File |
                    Where-Object { $_.Name -ieq "codex-code-mode-host-$target.exe" } |
                    Select-Object -First 1
                if ($null -eq $hostExe) {
                    throw "$hostAsset does not contain codex-code-mode-host-$target.exe."
                }

                New-Item -ItemType Directory -Force -Path $binDir | Out-Null
                Copy-Item -LiteralPath $hostExe.FullName -Destination $codeModeHostExe -Force
            } finally {
                Remove-Item -LiteralPath $hostTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warn "Codex: could not install codex-code-mode-host.exe: $($_.Exception.Message)"
        }
    }

    Set-CodexVisibleBin -VersionDir $versionDir

    $verified = Get-ExeVersion -ExePath $script:CodexExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "Codex verification failed: $script:CodexExe reports '$verified' but '$version' was expected."
    }

    Write-Info "Codex: $verified installed to $script:CodexBin"
    Add-PathEntry -Directory $script:CodexBin
    Remove-OldCodexVersions -CurrentVersion $version
}

# ---------------------------------------------------------------------------
# winget (optional)
# ---------------------------------------------------------------------------
function Remove-WingetPackages {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        Write-Warn 'winget is not available; nothing will be uninstalled.'
        return
    }

    foreach ($id in @('SST.opencode', 'OpenAI.Codex')) {
        Write-Info "winget: uninstalling $id"
        try {
            & winget uninstall --id $id --silent --disable-interactivity --accept-source-agreements | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "winget: $id uninstalled"
            } else {
                Write-Warn "winget: could not uninstall $id (exit code $LASTEXITCODE); it may be in use."
            }
        } catch {
            Write-Warn "winget: error uninstalling ${id}: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Info "update-aiclis: local target $(Join-Path $env:LOCALAPPDATA 'Programs')"
if ($Check) {
    Write-Info 'update-aiclis: check mode, nothing will be downloaded or changed'
}

$doOpenCode = $Target -in @('All', 'OpenCode')
$doCodex = $Target -in @('All', 'Codex')

if ($doOpenCode) {
    try { Install-OpenCode -Version $OpenCodeVersion }
    catch { Write-Fail "OpenCode: $($_.Exception.Message)" }
}

if ($doCodex) {
    try { Install-Codex -Version $CodexVersion }
    catch { Write-Fail "Codex: $($_.Exception.Message)" }
}

if ($RemoveWinget -and -not $Check) {
    Remove-WingetPackages
}

if ($doOpenCode) {
    $v = Get-ExeVersion -ExePath $script:OpenCodeExe
    Write-Info "OpenCode : $(if ($v) { $v } else { 'not installed' })  ->  $script:OpenCodeExe"
}
if ($doCodex) {
    $v = Get-ExeVersion -ExePath $script:CodexExe
    Write-Info "Codex    : $(if ($v) { $v } else { 'not installed' })  ->  $script:CodexExe"
}
if ($script:PathChanged) {
    Write-Warn 'The user PATH changed. Open a new PowerShell window to use it.'
}
