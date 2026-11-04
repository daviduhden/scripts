#!/usr/bin/env pwsh

# Codex CLI, OpenCode CLI/TUI and Bun installer and updater for Windows.
# - Installs and updates Codex and OpenCode for the current user (no admin).
# - Bun: installs or updates the Oven-sh.Bun package through winget.
# - OpenCode: GitHub release binary verified against the published SHA-256 digest.
# - Codex: GitHub release zip with the three binaries plus codex-code-mode-host.
# - Keeps versioned copies and prepends the local folders to the user PATH.
# - Repairs PATH. PowerShell wrappers (codex --yolo, opencode --auto) are
#   opt-in with -Wrappers.
# - Leaves winget installations untouched unless -RemoveWinget is given.
#
# Parameters:
# -Target All|Codex|OpenCode|Bun Tool selection (default: All).
# -OpenCodeVersion <version>    Specific OpenCode version (default: latest).
# -CodexVersion <version>       Specific Codex version (default: latest).
# -Force                        Reinstall even if already up to date.
# -Check                        Show installed and available versions, change nothing.
# -RemoveWinget                 Uninstall the winget copies of Codex and OpenCode;
#                               Bun is installed through winget and is left in place.
# -Wrappers                     Install profile functions that add --yolo/--auto.
#                               Off by default.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param(
    [ValidateSet('All', 'Codex', 'OpenCode', 'Bun')]
    [string]$Target = 'All',

    [string]$OpenCodeVersion,

    [string]$CodexVersion,

    [switch]$Force,

    [switch]$Check,

    [switch]$RemoveWinget,

    [switch]$Wrappers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    # Best effort: the HTTPS endpoints need TLS 1.2, and a failure to change the
    # process-wide setting is ignored.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
$script:OpenCodeRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenCode'
$script:OpenCodeBin = Join-Path $script:OpenCodeRoot 'bin'
$script:OpenCodeExe = Join-Path $script:OpenCodeBin 'opencode.exe'
$script:CodexRoot = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenAI') 'Codex'
$script:CodexBin = Join-Path $script:CodexRoot 'bin'
$script:CodexVersions = Join-Path $script:CodexRoot 'versions'
$script:CodexExe = Join-Path $script:CodexBin 'codex.exe'
$script:OpenCodeMetaUrl = 'https://api.github.com/repos/anomalyco/opencode/releases/latest'
$script:CodexLatestApi = 'https://api.github.com/repos/openai/codex/releases/latest'
$script:PathChanged = $false
$script:HadError = $false
$script:ManagedDirs = @()

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

<#
.SYNOPSIS
    Maps the running OS architecture to a release asset tag.
.OUTPUTS
    'x64' or 'arm64'.
.NOTES
    Reads RuntimeInformation.OSArchitecture and falls back to
    PROCESSOR_ARCHITECTURE when that API is unavailable. Other values throw.
#>
function Get-PlatformTag {
    $arch = $null
    try {
        $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    }
    catch {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }
    switch -Regex ($arch) {
        '^(X64|AMD64)$' { return 'x64' }
        '^Arm64$' { return 'arm64' }
        default { throw "Unsupported architecture: $arch" }
    }
}

<#
.SYNOPSIS
    Normalizes a version string for comparison and directory names.
.OUTPUTS
    The trimmed value without a leading 'rust-' or 'v' prefix; $null for null
    or whitespace input.
#>
function Normalize-Version {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    $v = $v -replace '(?i)^rust-', ''
    $v = $v -replace '(?i)^v', ''
    return $v
}

<#
.SYNOPSIS
    Reads the version reported by an installed CLI.
.PARAMETER ExePath
    Executable to run with --version.
.OUTPUTS
    The last whitespace-separated token of the first output line, normalized;
    $null when the file is missing, prints nothing, or fails.
.NOTES
    This executes the target binary, so only pass executables that the script
    installed or located.
#>
function Get-ExeVersion {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = & $ExePath --version 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        $token = ($out -split '\s+')[-1]
        return (Normalize-Version $token)
    }
    catch {
        return $null
    }
}

function Test-VersionEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    return ($A.Trim() -eq $B.Trim())
}

<#
.SYNOPSIS
    Prepends a directory to the user PATH and the current process PATH.
.PARAMETER Directory
    Directory to add. It is created when missing.
.NOTES
    Writes HKCU\Environment\Path directly so the stored value kind (for example
    REG_EXPAND_SZ) and unexpanded %VAR% entries are preserved. Managed
    directories are deduplicated and kept in insertion order, so repeated runs
    do not rewrite PATH. Sets $script:PathChanged only when the stored value
    actually changes.
#>
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

    # Persistent user PATH (prepend so we win over winget). Use the registry
    # directly: Environment.SetEnvironmentVariable rewrites the value as
    # REG_SZ and expands %VAR% entries, while install-windows.bat preserves
    # the original REG_EXPAND_SZ kind and unexpanded value.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    }
    try {
        $userPath = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $userPath) { $userPath = '' }
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }
        $entries = @($userPath -split ';' | Where-Object {
                $value = $_.TrimEnd('\')
                if ([string]::IsNullOrWhiteSpace($value)) { return $false }
                return -not (@($script:ManagedDirs | Where-Object { $_.TrimEnd('\') -ieq $value }).Count)
            })
        $newUserPath = (@($script:ManagedDirs) + $entries) -join ';'
        if ($newUserPath -ne $userPath) {
            $key.SetValue('Path', $newUserPath, $kind)
            Write-Info "User PATH updated: $Directory"
            $script:PathChanged = $true
        }
    }
    finally {
        $key.Close()
    }

    # Current process PATH so we can verify immediately.
    $procEntries = @($env:Path -split ';' | Where-Object {
            $value = $_.TrimEnd('\')
            if ([string]::IsNullOrWhiteSpace($value)) { return $false }
            return -not (@($script:ManagedDirs | Where-Object { $_.TrimEnd('\') -ieq $value }).Count)
        })
    $env:Path = (@($script:ManagedDirs) + $procEntries) -join ';'
}

<#
.SYNOPSIS
    Locates bun.exe without installing or changing PATH.
.DESCRIPTION
    Checks the current PATH, winget and Bun default directories, BUN_INSTALL,
    the persistent user and machine PATH, and finally the newest Oven-sh.Bun
    package directory.
.OUTPUTS
    The full path to bun.exe, or $null when none is found.
#>
function Find-BunExe {
    $command = Get-Command bun.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    # winget may have updated the persistent PATH without updating this process.
    $directories = @(
        Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
        Join-Path $env:USERPROFILE '.bun\bin'
    )
    if ($env:BUN_INSTALL) { $directories += Join-Path $env:BUN_INSTALL 'bin' }
    foreach ($scope in @('User', 'Machine')) {
        $directories += [Environment]::GetEnvironmentVariable('Path', $scope) -split ';'
    }
    foreach ($directory in $directories) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))
        $candidate = Join-Path $directory 'bun.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $packages) {
        $packageDirs = Get-ChildItem -LiteralPath $packages -Directory -Filter 'Oven-sh.Bun_*'
        $binary = $packageDirs | Get-ChildItem -Recurse -File -Filter 'bun.exe' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $binary) { return $binary.FullName }
    }
    return $null
}

<#
.SYNOPSIS
    Adds or replaces a marked function in the current-user PowerShell profile.
.PARAMETER Name
    Command name, such as codex or opencode.
.PARAMETER DefaultArgument
    Argument inserted before the caller's arguments, such as --yolo.
.NOTES
    The block is delimited by BEGIN/END comments, so unrelated profile content
    is preserved. The profile is written as UTF-8 with a BOM, creating its
    parent directory when needed. The function is also defined in the current
    session because profile changes apply only to new sessions.
#>
function Set-CliWrapper {
    param([string]$Name, [string]$DefaultArgument)

    # PowerShell aliases cannot include arguments; use a function instead.
    $start = "# BEGIN update-aiclis $Name"
    $end = "# END update-aiclis $Name"
    $body = "& $Name.exe $DefaultArgument @args"
    $block = "$start`r`nfunction global:$Name { $body }`r`n$end"
    $profilePath = $PROFILE.CurrentUserAllHosts
    $encoding = [Text.UTF8Encoding]::new($false)
    $content = ''
    if (Test-Path -LiteralPath $profilePath) {
        $bytes = [IO.File]::ReadAllBytes($profilePath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = [Text.UTF8Encoding]::new($true)
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = [Text.UnicodeEncoding]::new($false, $true)
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = [Text.UnicodeEncoding]::new($true, $true)
        }
        $content = $encoding.GetString($bytes)
        if ($encoding.GetPreamble().Length -gt 0) {
            $content = $content.TrimStart([char]0xFEFF)
        }
    }
    $pattern = '(?ms)^' + [regex]::Escape($start) + '\r?\n.*?^' + [regex]::Escape($end) + '(?=\r?$)'
    if ([regex]::IsMatch($content, $pattern)) {
        $updated = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($match) $block })
    }
    else {
        $updated = $content + "`r`n$block`r`n"
    }
    if ($updated -cne $content) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        $temporary = "$profilePath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary, $updated, $encoding)
            if (Test-Path -LiteralPath $profilePath) {
                [IO.File]::Replace($temporary, $profilePath,
                    "$profilePath.bak.$([guid]::NewGuid().ToString('N'))")
            }
            else { [IO.File]::Move($temporary, $profilePath) }
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        }
        Write-Info "PowerShell profile updated: $Name $DefaultArgument ($profilePath)"
    }
    Set-Item -Path "Function:global:$Name" -Value ([scriptblock]::Create($body))
}

<#
.SYNOPSIS
    Makes an installed CLI reachable and optionally adds its default-argument wrapper.
.PARAMETER Name
    Command name to check.
.PARAMETER ExePath
    Installed executable; a missing or empty path produces a warning and no
    environment changes.
.PARAMETER DefaultArgument
    Argument for Set-CliWrapper, or empty to skip the wrapper.
.NOTES
    In -Check mode this only reports whether the command is missing from the
    current PATH. Normal runs add the executable's directory and let
    $ErrorActionPreference handle any registry failure.
#>
function Repair-CliEnvironment {
    param([string]$Name, [string]$ExePath, [string]$DefaultArgument)

    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        Write-Warn "${Name}: binary not found; PATH was not changed."
        return
    }
    $command = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { Write-Info "${Name}: binary missing from the current PATH." }
    if ($Check) { return }

    Add-PathEntry -Directory (Split-Path -Parent $ExePath)
    if ($DefaultArgument) { Set-CliWrapper -Name $Name -DefaultArgument $DefaultArgument }
}

<#
.SYNOPSIS
    Downloads a URI to a file, retrying transient failures.
.PARAMETER Uri
    Source URL.
.PARAMETER OutFile
    Destination path.
.NOTES
    Makes three attempts with a three-second pause and 900-second timeout per
    request, then rethrows the last error.
#>
function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
            return
        }
        catch {
            if ($i -eq $attempts) { throw }
            Write-Warn "Download failed (attempt $i/$attempts): $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
}

<#
.SYNOPSIS
    Fetches a URL and returns its response body as text.
.PARAMETER Uri
    Source URL.
.PARAMETER Headers
    Optional request headers; $null is treated as an empty table.
#>
function Get-RemoteText {
    param([string]$Uri, [hashtable]$Headers)
    if ($null -eq $Headers) { $Headers = @{} }
    return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -Headers $Headers).Content
}

<#
.SYNOPSIS
    Replaces a current executable with a copy of a versioned one.
.PARAMETER SourceExe
    Versioned executable to copy.
.PARAMETER TargetExe
    Active executable to replace.
.NOTES
    Copies to a unique same-directory file, verifies the copy, then activates
    with File.Replace (or File.Move for a new target). Locked targets fail
    without an in-place overwrite. Recovery copies survive failed activation.
#>
function Set-CurrentExe {
    param([string]$SourceExe, [string]$TargetExe)
    $pending = "$TargetExe.pending-$([guid]::NewGuid().ToString('N'))"
    $oldExe = "$TargetExe.old-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::Copy($SourceExe, $pending, $false)
        if ((Get-FileHash -LiteralPath $SourceExe -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash) {
            throw 'Executable staging verification failed.'
        }
        if (Test-Path -LiteralPath $TargetExe) {
            $item = Get-Item -LiteralPath $TargetExe -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing nonregular executable destination: $TargetExe"
            }
            [IO.File]::Replace($pending, $TargetExe, $oldExe)
        }
        else { [IO.File]::Move($pending, $TargetExe) }
    }
    catch {
        if (Test-Path -LiteralPath $oldExe) { Write-Warn "Recovery copy retained: $oldExe" }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
    }
    if (Test-Path -LiteralPath $oldExe) { Remove-Item -LiteralPath $oldExe }
}

# ---------------------------------------------------------------------------
# OpenCode
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Resolves the latest OpenCode version from the update metadata endpoint.
.OUTPUTS
    A normalized version string without the 'v' prefix.
#>
function Get-OpenCodeLatestVersion {
    $raw = Get-RemoteText -Uri $script:OpenCodeMetaUrl
    $meta = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($meta.tag_name)) {
        throw 'Could not resolve the latest OpenCode version.'
    }
    return (Normalize-Version $meta.tag_name)
}

<#
.SYNOPSIS
    Prunes old OpenCode version directories.
.PARAMETER CurrentVersion
    Directory name of the active version, which is never removed.
.PARAMETER Keep
    Total number of versions to keep, including the current one.
.NOTES
    Non-current directories are ordered by LastWriteTime, newest first. Removal
    failures are ignored because stale versions are not fatal.
#>
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

<#
.SYNOPSIS
    Installs or updates the OpenCode CLI for the current user.
.PARAMETER Version
    Version to install. Empty selects the latest release.
.NOTES
    -Check only reports installed and available versions. A normal run downloads
    and extracts a temporary zip, stores the binary under versions\<version>,
    points bin\opencode.exe at it, verifies the reported version, and prunes old
    version directories. Downloads and version strings come from the official GitHub release metadata.
#>
function Install-OpenCode {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:OpenCodeExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-OpenCodeLatestVersion }
            else { $latest = Normalize-Version $Version }
        }
        catch {
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
        return
    }

    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Invalid OpenCode release version.'
    }
    $asset = "opencode-windows-$platform.zip"
    $release = (Get-RemoteText -Uri "https://api.github.com/repos/anomalyco/opencode/releases/tags/v$version") | ConvertFrom-Json
    $assets = @($release.assets | Where-Object { $_.name -ceq $asset })
    if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Expected one OpenCode release asset with a published SHA-256 digest.'
    }
    $url = [string]$assets[0].browser_download_url
    if (-not $url.StartsWith('https://github.com/anomalyco/opencode/releases/download/', [StringComparison]::Ordinal)) {
        throw 'Unexpected OpenCode release URL.'
    }
    $expectedDigest = $assets[0].digest.Substring(7)
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

            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedDigest) {
                throw 'OpenCode release SHA-256 mismatch.'
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'opencode.exe' })
                if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or
                    $entries[0].Length -gt 1073741824 -or
                    (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw 'Expected exactly one regular opencode.exe entry.'
                }
                New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
                $pending = Join-Path $versionDir ('.opencode-' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $pending)
                    if (Test-Path -LiteralPath $versionExe) {
                        [IO.File]::Replace($pending, $versionExe, "$versionExe.bak.$([guid]::NewGuid().ToString('N'))")
                    }
                    else { [IO.File]::Move($pending, $versionExe) }
                }
                finally {
                    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
                }
            }
            finally { $archive.Dispose() }
        }
        finally {
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
    Remove-OldOpenCodeVersions -CurrentVersion $version
}

# ---------------------------------------------------------------------------
# Codex
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Resolves the latest Codex release tag from the GitHub API.
.NOTES
    Sends a User-Agent and the GitHub JSON media type, then normalizes the rust-v
    tag prefix away.
#>
function Get-CodexLatestVersion {
    $headers = @{ 'User-Agent' = 'update-aiclis'; 'Accept' = 'application/vnd.github+json' }
    $raw = Get-RemoteText -Uri $script:CodexLatestApi -Headers $headers
    $meta = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($meta.tag_name)) {
        throw 'Could not resolve the latest Codex version.'
    }
    return (Normalize-Version $meta.tag_name)
}

<#
.SYNOPSIS
    Returns the Codex release target triple for this machine.
.OUTPUTS
    x86_64-pc-windows-msvc or aarch64-pc-windows-msvc.
#>
function Get-CodexTarget {
    $platform = Get-PlatformTag
    switch ($platform) {
        'x64' { return 'x86_64-pc-windows-msvc' }
        'arm64' { return 'aarch64-pc-windows-msvc' }
        default { throw "Unsupported architecture for Codex: $platform" }
    }
}

<#
.SYNOPSIS
    Tests whether the visible Codex bin directory is a junction into the versions tree.
.OUTPUTS
    $true when bin is a reparse point whose target starts with the versions
    directory; otherwise $false.
#>
function Test-CodexManagedLayout {
    # The visible directory must be a junction to versions\<version>\bin.
    $item = Get-Item -LiteralPath $script:CodexBin -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = "$($item.Target)"
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    return ($target -like "$($script:CodexVersions)*")
}

<#
.SYNOPSIS
    Points the visible Codex bin directory at a version directory.
.PARAMETER VersionDir
    Version directory containing bin, codex-resources, and codex-package.json.
.NOTES
    Recreates bin as a junction. An existing junction is removed with rmdir so
    its target is untouched; a real directory is deleted recursively. When a
    junction cannot be created, copies the executables, resources, and package
    manifest instead and warns. The fallback does not copy codex-path.
#>
function Set-CodexVisibleBin {
    param([string]$VersionDir)

    if (Test-Path -LiteralPath $script:CodexBin) {
        $item = Get-Item -LiteralPath $script:CodexBin -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # rmdir removes the junction without touching the target directory.
            & cmd.exe /c rmdir "$script:CodexBin" | Out-Null
        }
        else {
            Remove-Item -LiteralPath $script:CodexBin -Recurse -Force
        }
    }

    try {
        New-Item -ItemType Junction -Path $script:CodexBin -Target (Join-Path $VersionDir 'bin') -Force | Out-Null
    }
    catch {
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

<#
.SYNOPSIS
    Prunes old Codex version directories.
.PARAMETER CurrentVersion
    Directory name of the active version, which is never removed.
.PARAMETER Keep
    Total number of versions to keep, including the current one.
.NOTES
    Non-current directories are ordered by LastWriteTime, newest first. Removal
    failures are ignored because stale versions are not fatal.
#>
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

<#
.SYNOPSIS
    Installs or updates the Codex CLI for the current user.
.PARAMETER Version
    Version to install. Empty selects the latest release.
.NOTES
    -Check only reports installed and available versions. A normal run may migrate
    an unmanaged layout to a junction, download the GitHub release zip with the
    three binaries, install the optional code-mode host, write a
    codex-package.json manifest, verify the version, and prune old versions. A
    code-mode host failure is reported as a warning because it is optional.
#>
function Install-Codex {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:CodexExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-CodexLatestVersion }
            else { $latest = Normalize-Version $Version }
        }
        catch {
            Write-Warn "Could not check the latest version: $($_.Exception.Message)"
        }
        Write-Info "Codex: installed $(if ($installed) { $installed } else { 'none' }), available $(if ($latest) { $latest } else { 'unknown' })"
        Write-Info "Codex: path $script:CodexExe"
        return
    }

    $target = Get-CodexTarget
    $version = Normalize-Version $Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = Get-CodexLatestVersion }
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Invalid Codex release version.'
    }

    $installed = Get-ExeVersion -ExePath $script:CodexExe
    $versionDir = Join-Path $script:CodexVersions $version
    $binDir = Join-Path $versionDir 'bin'
    $resourcesDir = Join-Path $versionDir 'codex-resources'
    $versionExe = Join-Path $binDir 'codex.exe'
    $codeModeHostExe = Join-Path $binDir 'codex-code-mode-host.exe'

    if ((Test-VersionEqual $installed $version) -and (Test-CodexManagedLayout) -and
        (Test-Path -LiteralPath $versionExe) -and (Test-Path -LiteralPath $codeModeHostExe) -and -not $Force) {
        Write-Info "Codex: already up to date ($installed). Nothing to do."
        return
    }

    if ((Test-VersionEqual $installed $version) -and -not (Test-CodexManagedLayout)) {
        Write-Info 'Codex: migrating to the managed layout (junction + GitHub package)'
    }

    if (-not (Test-Path -LiteralPath $versionExe) -or $Force) {
        $asset = "codex-$target.exe.zip"
        $api = "https://api.github.com/repos/openai/codex/releases/tags/rust-v$version"
        $release = (Get-RemoteText -Uri $api) | ConvertFrom-Json
        $assets = @($release.assets | Where-Object { $_.name -ceq $asset })
        if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'Expected one Codex release asset with a published SHA-256 digest.'
        }
        $url = [string]$assets[0].browser_download_url
        if (-not $url.StartsWith('https://github.com/openai/codex/releases/download/', [StringComparison]::Ordinal)) {
            throw 'Unexpected Codex release URL.'
        }
        $expectedDigest = $assets[0].digest.Substring(7)

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $zip = Join-Path $tempRoot $asset
            Write-Info "Codex: downloading $version ($target)"
            Invoke-Download -Uri $url -OutFile $zip
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedDigest) {
                throw 'Codex release SHA-256 mismatch.'
            }

            New-Item -ItemType Directory -Force -Path $binDir | Out-Null
            New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
            $entries = @(
                @{ Name = "codex-$target.exe"; Destination = (Join-Path $binDir 'codex.exe') },
                @{ Name = 'codex-command-runner.exe'; Destination = (Join-Path $resourcesDir 'codex-command-runner.exe') },
                @{ Name = 'codex-windows-sandbox-setup.exe'; Destination = (Join-Path $resourcesDir 'codex-windows-sandbox-setup.exe') }
            )
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($wanted in $entries) {
                    $entryMatches = @($archive.Entries | Where-Object { $_.Name -ceq $wanted.Name })
                    if ($entryMatches.Count -ne 1 -or $entryMatches[0].Length -le 0 -or
                        $entryMatches[0].Length -gt 536870912 -or
                        (($entryMatches[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                        throw "Expected exactly one regular $($wanted.Name) entry."
                    }
                    $pending = Join-Path (Split-Path -Parent $wanted.Destination) ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entryMatches[0], $pending)
                        if (Test-Path -LiteralPath $wanted.Destination) {
                            [IO.File]::Replace($pending, $wanted.Destination,
                                "$($wanted.Destination).bak.$([guid]::NewGuid().ToString('N'))")
                        }
                        else { [IO.File]::Move($pending, $wanted.Destination) }
                    }
                    finally {
                        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
                    }
                }
            }
            finally { $archive.Dispose() }

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
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # codex-code-mode-host.exe ships in a separate GitHub zip (optional component).
    if (-not (Test-Path -LiteralPath $codeModeHostExe) -or $Force) {
        try {
            $hostAsset = "codex-code-mode-host-$target.exe.zip"
            $hostApi = "https://api.github.com/repos/openai/codex/releases/tags/rust-v$version"
            $hostRelease = (Get-RemoteText -Uri $hostApi) | ConvertFrom-Json
            $hostAssets = @($hostRelease.assets | Where-Object { $_.name -ceq $hostAsset })
            if ($hostAssets.Count -ne 1 -or $hostAssets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw 'Expected one code-mode host asset with a published SHA-256 digest.'
            }
            $hostUrl = [string]$hostAssets[0].browser_download_url
            if (-not $hostUrl.StartsWith('https://github.com/openai/codex/releases/download/', [StringComparison]::Ordinal)) {
                throw 'Unexpected code-mode host URL.'
            }

            $hostTemp = Join-Path ([IO.Path]::GetTempPath()) ("codex-code-mode-host-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $hostTemp | Out-Null
            try {
                $hostZip = Join-Path $hostTemp $hostAsset
                Write-Info "Codex: downloading $hostAsset"
                Invoke-Download -Uri $hostUrl -OutFile $hostZip
                if ((Get-FileHash -LiteralPath $hostZip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hostAssets[0].digest.Substring(7)) {
                    throw 'Code-mode host SHA-256 mismatch.'
                }

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $hostArchive = [IO.Compression.ZipFile]::OpenRead($hostZip)
                try {
                    $hostEntries = @($hostArchive.Entries | Where-Object { $_.Name -ceq "codex-code-mode-host-$target.exe" })
                    if ($hostEntries.Count -ne 1 -or $hostEntries[0].Length -le 0 -or
                        $hostEntries[0].Length -gt 536870912 -or
                        (($hostEntries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                        throw "$hostAsset does not contain exactly one regular code-mode host."
                    }
                    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
                    $hostPending = Join-Path $binDir ('.codex-host-' + [guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($hostEntries[0], $hostPending)
                        if (Test-Path -LiteralPath $codeModeHostExe) {
                            [IO.File]::Replace($hostPending, $codeModeHostExe,
                                "$codeModeHostExe.bak.$([guid]::NewGuid().ToString('N'))")
                        }
                        else { [IO.File]::Move($hostPending, $codeModeHostExe) }
                    }
                    finally {
                        if (Test-Path -LiteralPath $hostPending) { Remove-Item -LiteralPath $hostPending }
                    }
                }
                finally { $hostArchive.Dispose() }
            }
            finally {
                Remove-Item -LiteralPath $hostTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warn "Codex: could not install codex-code-mode-host.exe: $($_.Exception.Message)"
        }
    }

    Set-CodexVisibleBin -VersionDir $versionDir

    $verified = Get-ExeVersion -ExePath $script:CodexExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "Codex verification failed: $script:CodexExe reports '$verified' but '$version' was expected."
    }

    Write-Info "Codex: $verified installed to $script:CodexBin"
    Remove-OldCodexVersions -CurrentVersion $version
}

# ---------------------------------------------------------------------------
# Bun (winget)
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Installs, updates, or checks Bun through winget.
.NOTES
    Requires winget. -Check only lists the installed and available packages.
    Normal runs use --silent and accept source and package agreements; -Force
    adds --force. The "not installed" and "already up to date" winget exit codes
    are treated as expected outcomes.
#>
function Install-Bun {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw 'winget is required to install, update or check Bun. Install App Installer and try again.'
    }

    # Handle native exit codes explicitly, including when the caller enables this preference.
    $PSNativeCommandUseErrorActionPreference = $false
    $packageArgs = @('--id', 'Oven-sh.Bun', '--exact', '--source', 'winget', '--disable-interactivity')
    if ($Check) {
        Write-Info 'Bun: installed version (winget)'
        & $winget.Source list @packageArgs
        if ($LASTEXITCODE -eq -1978335212) {
            # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
            Write-Info 'Bun: not installed through winget.'
        }
        elseif ($LASTEXITCODE -ne 0) {
            throw "winget list failed (exit code $LASTEXITCODE)."
        }
        Write-Info 'Bun: available version (winget)'
        & $winget.Source show @packageArgs
        if ($LASTEXITCODE -ne 0) { throw "winget show failed (exit code $LASTEXITCODE)." }
        return
    }

    # winget install automatically upgrades an existing installation.
    $installArgs = $packageArgs + @('--silent', '--accept-source-agreements', '--accept-package-agreements')
    if ($Force) { $installArgs += '--force' }
    Write-Info 'Bun: installing or updating through winget'
    & $winget.Source install @installArgs
    if ($LASTEXITCODE -eq -1978335189) {
        # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
        Write-Info 'Bun: already up to date. Nothing to do.'
    }
    elseif ($LASTEXITCODE -ne 0) {
        throw "winget install failed (exit code $LASTEXITCODE)."
    }
    else {
        Write-Info 'Bun: installed or updated successfully.'
    }
}

# ---------------------------------------------------------------------------
# winget (optional CLI cleanup)
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Uninstalls the winget copies of OpenCode and Codex.
.NOTES
    Best effort: a missing winget or an uninstall failure produces a warning.
    Bun is never removed because winget manages that installation.
#>
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
            }
            else {
                Write-Warn "winget: could not uninstall $id (exit code $LASTEXITCODE); it may be in use."
            }
        }
        catch {
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
$doBun = $Target -in @('All', 'Bun')

if ($doBun) {
    try { Install-Bun }
    catch { Write-Fail "Bun: $($_.Exception.Message)"; $script:HadError = $true }
}

if ($doOpenCode) {
    try { Install-OpenCode -Version $OpenCodeVersion }
    catch { Write-Fail "OpenCode: $($_.Exception.Message)"; $script:HadError = $true }
}

if ($doCodex) {
    try { Install-Codex -Version $CodexVersion }
    catch { Write-Fail "Codex: $($_.Exception.Message)"; $script:HadError = $true }
}

if ($RemoveWinget -and -not $Check) {
    Remove-WingetPackages
}

# Repair existing installations even when an update failed (for example, offline).
# OpenCode and Codex come first so their directories are prepended before Bun's
# winget Links directory (which may contain shims for the same commands).
foreach ($cli in @(
        @{ Enabled = $doOpenCode; Name = 'opencode'; ExePath = $script:OpenCodeExe; DefaultArgument = '--auto' }
        @{ Enabled = $doCodex; Name = 'codex'; ExePath = $script:CodexExe; DefaultArgument = '--yolo' }
        @{ Enabled = $doBun; Name = 'bun'; ExePath = $null; DefaultArgument = '' }
    )) {
    if (-not $cli.Enabled) { continue }
    try {
        if ($cli.Name -eq 'bun') { $cli.ExePath = Find-BunExe }
        $defaultArgument = if ($Wrappers) { $cli.DefaultArgument } else { '' }
        Repair-CliEnvironment -Name $cli.Name -ExePath $cli.ExePath -DefaultArgument $defaultArgument
    }
    catch { Write-Fail "$($cli.Name): environment setup failed: $($_.Exception.Message)"; $script:HadError = $true }
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

if ($script:HadError) { exit 1 }
