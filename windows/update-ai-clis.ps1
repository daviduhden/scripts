#!/usr/bin/env pwsh

# Per-user AI CLI release updater for Windows.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Agent,

    [string[]]$Target,

    [string]$OpenCodeVersion,

    [string]$CodexVersion,

    [string]$CrushVersion,

    [switch]$Force,

    [switch]$Check,

    [switch]$RemoveWinget,

    [switch]$Wrappers,

    [switch]$UpdateCodexDaemon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Force = $Force
$script:RemoveWinget = $RemoveWinget
$script:Wrappers = $Wrappers
$script:StableAgents = @('opencode', 'codex', 'crush', 'copilot-cli', 'claude', 'swival')
$script:SemVerCore = '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
$script:SemVerPre = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
$script:SemVer = "$script:SemVerCore(?:-$script:SemVerPre(?:\.$script:SemVerPre)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"

try {
    # Best effort: the HTTPS endpoints need TLS 1.2, and a failure to change the
    # process-wide setting is ignored.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { Write-Verbose "Could not select TLS 1.2: $($_.Exception.Message)" }

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
$script:CrushRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'Crush'
$script:CrushBin = Join-Path $script:CrushRoot 'bin'
$script:CrushVersions = Join-Path $script:CrushRoot 'versions'
$script:CrushExe = Join-Path $script:CrushBin 'crush.exe'
$script:CopilotBin = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'GitHub Copilot') 'bin'
$script:CopilotExe = Join-Path $script:CopilotBin 'copilot.exe'
$script:ClaudeBin = Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'Claude Code') 'bin'
$script:ClaudeExe = Join-Path $script:ClaudeBin 'claude.exe'
$script:ClaudeSource = 'https://downloads.claude.ai/claude-code-releases'
$script:SwivalRoot = Join-Path $env:LOCALAPPDATA 'Programs/Swival'
$script:SwivalBin = Join-Path $script:SwivalRoot 'bin'
$script:SwivalExe = Join-Path $script:SwivalBin 'swival.exe'
$script:OpenCodeReleasesApi = 'https://api.github.com/repos/anomalyco/opencode/releases?per_page=100'
$script:CodexLatestApi = 'https://api.github.com/repos/openai/codex/releases/latest'
$script:CrushLatestApi = 'https://api.github.com/repos/charmbracelet/crush/releases/latest'
$script:PathChanged = $false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Information "[INFO] $Message" -InformationAction Continue
}

function Write-Warn {
    param([string]$Message)
    Write-Information "[WARN] $Message" -InformationAction Continue
}

function Write-Fail {
    param([string]$Message)
    Write-Information "[ERROR] $Message" -InformationAction Continue
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
    param([switch]$AllowX86)

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
        '^X86$' {
            if ($AllowX86) { return 'x86' }
            throw 'This distribution has no native Windows x86 package.'
        }
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
function ConvertTo-NormalizedVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    $v = $v -replace '(?i)^rust-', ''
    $v = $v -replace '(?i)^v', ''
    if ($v -cnotmatch "^$script:SemVer$") { return $null }
    return $v
}

function ConvertFrom-VersionOutput {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        # Match a complete token in output such as "codex-cli 1.2.3",
        # "1.2.3 (Claude Code)", or the version on a later Copilot line.
        $match = [regex]::Match($line, "(?:^|\s)(?:rust-)?[vV]?($script:SemVer)(?=\.?(?:\s|$))")
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return $null
}

<#
.SYNOPSIS
    Reads the version reported by an installed CLI.
.PARAMETER ExePath
    Executable to run with --version.
.OUTPUTS
    A semantic version from --version, or $null on failure.
.NOTES
    This executes the target binary, so only pass executables that the script
    installed or located.
#>
function Invoke-CliVersionProbe {
    param([string]$FilePath, [string]$Arguments = '--version')

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $extension = [IO.Path]::GetExtension($FilePath)
    if ($extension -ieq '.ps1') {
        $engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } elseif ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $start.FileName = Join-Path $PSHOME $engine
        $start.Arguments = "-NoProfile -NonInteractive -File `"$FilePath`" --version"
    }
    elseif ($extension -iin @('.cmd', '.bat')) {
        if ($FilePath -match '[%!`"]' -or $Arguments -cne '--version') { return $null }
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        $start.Arguments = "/d /s /v:off /c `"`"$FilePath`" --version`""
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return $null }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdout = [char[]]::new(32768)
        $stderr = [char[]]::new(32768)
        $readOut = $process.StandardOutput.ReadBlockAsync($stdout, 0, $stdout.Length)
        $readErr = $process.StandardError.ReadBlockAsync($stderr, 0, $stderr.Length)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($readOut, $readErr), 15000) -or
            $readOut.Result -ge $stdout.Length -or $readErr.Result -ge $stderr.Length -or
            -not $process.WaitForExit([Math]::Max(0, 15000 - [int]$timer.ElapsedMilliseconds)) -or $process.ExitCode -ne 0) {
            return $null
        }
        return (([string]::new($stdout, 0, $readOut.Result) + "`n" +
                [string]::new($stderr, 0, $readErr.Result)) -split '\r?\n')
    }
    catch {
        return $null
    }
    finally {
        try {
            if (-not $process.HasExited) {
                if ($PSVersionTable.PSEdition -eq 'Desktop') { $process.Kill() }
                else { $process.Kill($true) }
            }
        }
        catch { Write-Verbose 'The version probe process has already exited or could not be stopped.' }
        $process.Dispose()
    }
}

function Get-ExeVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return $null }
    return (ConvertFrom-VersionOutput (Invoke-CliVersionProbe $ExePath))
}

function Test-VersionEqual {
    param([string]$A, [string]$B)
    $aVersion = ConvertTo-NormalizedVersion $A
    $bVersion = ConvertTo-NormalizedVersion $B
    return ($aVersion -and $bVersion -and ($aVersion -split '\+')[0] -ceq ($bVersion -split '\+')[0])
}

function Test-StableVersionAtLeast {
    param([string]$Installed, [string]$Minimum)

    $installedVersion = ConvertTo-NormalizedVersion $Installed
    $minimumVersion = ConvertTo-NormalizedVersion $Minimum
    if (-not $installedVersion -or -not $minimumVersion) { return $false }
    $installedCore = ($installedVersion -split '\+')[0]
    $minimumCore = ($minimumVersion -split '\+')[0]
    if ($minimumCore -match '-') { return $false }
    $isPrerelease = $installedCore -match '-'
    $installedCore = ($installedCore -split '-')[0]

    $installedParts = $installedCore.Split('.')
    $minimumParts = $minimumCore.Split('.')
    for ($part = 0; $part -lt 3; $part++) {
        $left = $installedParts[$part]
        $right = $minimumParts[$part]
        if ($left.Length -ne $right.Length) { return ($left.Length -gt $right.Length) }
        $order = [string]::CompareOrdinal($left, $right)
        if ($order -ne 0) { return ($order -gt 0) }
    }
    return (-not $isPrerelease)
}

function Test-PrivateCliPath {
    param([string]$Path, [switch]$Directory)

    if ($env:OS -ne 'Windows_NT') { return $true }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains(';')) { return $false }

    # Compare well-known SIDs so localized account names behave identically.
    $broad = @('S-1-1-0', 'S-1-5-4', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-32-546')
    $replaceRights = [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
    $writeRights = $replaceRights -bor [Security.AccessControl.FileSystemRights]::Write
    if (-not $Directory) {
        $file = Get-Acl -LiteralPath $Path
        if (@($file.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                    $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -in $broad -and ($_.FileSystemRights -band $writeRights)
                }).Count) { return $false }
        $Path = Split-Path -Parent $Path
    }

    $rights = $writeRights
    $item = [IO.DirectoryInfo]::new($Path)
    while ($item) {
        if ($item.Exists) {
            $acl = Get-Acl -LiteralPath $item.FullName
            $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
            if (@($rules | Where-Object {
                        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -in $broad -and
                        ($_.FileSystemRights -band $rights) -and -not ($_.PropagationFlags -band 'InheritOnly')
                    }).Count) { return $false }
            $rights = $replaceRights
        }
        $item = $item.Parent
    }
    return $true
}

function Add-CliPathValue {
    param([string]$PathValue, [string]$Directory)

    $target = $Directory.TrimEnd('\')
    $found = $false
    $entries = foreach ($entry in $PathValue.Split(';')) {
        $comparison = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if ($comparison -ieq $target) {
            if ($found) { continue }
            $found = $true
        }
        $entry
    }
    if (-not $found) { $entries = @($Directory) + @($entries | Where-Object { $_ }) }
    return ($entries -join ';')
}

<#
.SYNOPSIS
    Adds a directory to the user PATH and the current process PATH.
.PARAMETER Directory
    Existing per-user directory to add.
.NOTES
    Writes HKCU\Environment\Path directly so the stored value kind (for example
    REG_EXPAND_SZ) and unexpanded %VAR% entries are preserved. Managed
    directories retain their existing positions so repeated runs do not
    rewrite PATH. Sets $script:PathChanged only when the value changes.
#>
function Add-PathEntry {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container) -or -not (Test-PrivateCliPath $Directory -Directory)) {
        throw "Refusing to add a missing or shared directory to user PATH: $Directory"
    }

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
        $newUserPath = Add-CliPathValue $userPath $Directory
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
    $env:Path = Add-CliPathValue $env:Path $Directory
}

function Get-PersistentCliPath {
    return (([Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';')
}

function Get-CliSnapshot {
    param([string]$Name, [string]$ManagedPath, [switch]$Persistent)

    $savedPath = $env:Path
    try {
        if ($Persistent) { $env:Path = Get-PersistentCliPath }
        $types = 'Application', 'ExternalScript'
        $active = Get-Command $Name -CommandType $types -ErrorAction SilentlyContinue | Select-Object -First 1
        $candidates = @(Get-Command $Name, "$Name.exe", "$Name.cmd", "$Name.ps1" -All -CommandType $types -ErrorAction SilentlyContinue)
        $paths = [Collections.Generic.List[string]]::new()
        if ($active) { $paths.Add($active.Path) }
        foreach ($candidate in $candidates) { $paths.Add($candidate.Path) }
        if ($ManagedPath -and (Test-Path -LiteralPath $ManagedPath -PathType Leaf)) { $paths.Add($ManagedPath) }

        $paths = @($paths | Sort-Object -Unique)
        $directories = @($paths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique)
        $activePath = if ($active) { $active.Path }
        $activeUnsafe = $activePath -and -not (Test-PrivateCliPath $activePath)
        $activeVersion = if ($activePath -and -not $activeUnsafe) { Get-ExeVersion $activePath }
        $bestPath = $null
        $bestVersion = $null
        if ($activeVersion) {
            $bestPath = $activePath
            $bestVersion = $activeVersion
        }
        elseif (-not $activeUnsafe) {
            # A blocked .ps1 wrapper may have a sibling .cmd wrapper. Report
            # that version separately, without running shadowed installations.
            $activeDir = if ($activePath) { Split-Path -Parent $activePath }
            foreach ($path in $paths) {
                if ($path -eq $activePath) { continue }
                if ($path -ne $ManagedPath -and (Split-Path -Parent $path) -ne $activeDir) { continue }
                if (-not (Test-PrivateCliPath $path)) { continue }
                $bestVersion = Get-ExeVersion $path
                if (-not $bestVersion) { continue }
                $bestPath = $path
                break
            }
        }
    }
    finally { $env:Path = $savedPath }
    if ($directories.Count -gt 1) {
        Write-Warn "${Name}: multiple installation directories: $($paths -join ', ')"
    }
    if ($activePath -and -not $activeVersion) {
        Write-Warn "${Name}: $activePath did not provide a usable version."
    }
    return [pscustomobject]@{
        Path          = $bestPath
        Version       = $bestVersion
        Found         = $paths.Count -gt 0
        ActivePath    = $activePath
        ActiveVersion = $activeVersion
        Unsafe        = $activeUnsafe
        Conflict      = $directories.Count -gt 1
    }
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
    $root = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $env:USERPROFILE '.bun' }
    $managed = Join-Path $root 'bin\bun.exe'
    if (Test-Path -LiteralPath $managed -PathType Leaf) { return $managed }
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
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$DefaultArgument)

    # PowerShell aliases cannot include arguments; use a function instead.
    $start = "# BEGIN update-aiclis $Name"
    $end = "# END update-aiclis $Name"
    $body = "& $Name.exe $DefaultArgument @args"
    $block = "$start`r`nfunction global:$Name { $body }`r`n$end"
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not $PSCmdlet.ShouldProcess($profilePath, "Configure the $Name PowerShell wrapper")) { return }
    $directory = Split-Path -Parent $profilePath
    Assert-CliPackageDirectory $directory
    $encoding = [Text.UTF8Encoding]::new($false)
    $content = ''
    $bytes = $null
    $acl = $null
    if (Test-Path -LiteralPath $profilePath) {
        if (-not (Test-PrivateCliPath $profilePath)) { throw 'PowerShell profile is not in a private writable path.' }
        $profileItem = Get-Item -LiteralPath $profilePath -Force
        if ($profileItem.PSIsContainer -or ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to rewrite a nonregular PowerShell profile.'
        }
        $acl = Get-Acl -LiteralPath $profilePath
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
        $updated = [regex]::Replace($content, $pattern, $block.Replace('$', '$$'))
    }
    else {
        $updated = $content + "`r`n$block`r`n"
    }
    if ($updated -cne $content) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Assert-CliPackageDirectory $directory
        $temporary = "$profilePath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try {
                $private = [Security.AccessControl.FileSecurity]::new()
                $private.SetAccessRuleProtection($true, $false)
                $private.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User, 'FullControl', 'Allow'))
                $stream = if ($PSVersionTable.PSEdition -eq 'Desktop') {
                    [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write,
                        [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $private)
                }
                else {
                    [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($temporary), 'CreateNew', 'Write', 'None', 4096, 'None', $private)
                }
            }
            finally { $identity.Dispose() }
            try {
                $replacement = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($updated))
                $stream.Write($replacement, 0, $replacement.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            if ($null -ne $bytes) {
                if (-not (Test-PrivateCliPath $profilePath) -or
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath)) -cne [Convert]::ToBase64String($bytes)) {
                    throw 'PowerShell profile changed before replacement.'
                }
                $currentAcl = Get-Acl -LiteralPath $profilePath
                $access = [Security.AccessControl.AccessControlSections]::Access
                if ($currentAcl.GetSecurityDescriptorSddlForm($access) -cne $acl.GetSecurityDescriptorSddlForm($access)) {
                    throw 'PowerShell profile ACL changed before replacement.'
                }
                Set-Acl -LiteralPath $temporary -AclObject $acl
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

function Get-GitHubStableVersion {
    param([string]$Uri)

    $headers = @{ 'User-Agent' = 'update-ai-clis'; 'Accept' = 'application/vnd.github+json' }
    $release = Get-RemoteText -Uri $Uri -Headers $headers | ConvertFrom-Json
    $version = ConvertTo-NormalizedVersion $release.tag_name
    if ($release.draft -or $release.prerelease -or -not (Test-StableVersionAtLeast $version $version)) {
        throw "The release source did not return a valid stable version: $Uri"
    }
    return $version
}

function Assert-CliPackageDirectory {
    param([string]$Directory)

    if (-not (Test-PrivateCliPath $Directory -Directory)) { throw 'Package directory is not private.' }
    $cursor = [IO.Path]::GetFullPath($Directory)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw 'Package directories cannot contain reparse points.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-CliPackageHash {
    param([string]$Directory)

    Assert-CliPackageDirectory $Directory
    $root = [IO.Path]::GetFullPath($Directory)
    $hashes = @{}
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    $total = 0L
    $count = 0
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath ($pending.Pop()) -Force) {
            if (++$count -gt 4096 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Unexpected entries in the cached package.'
            }
            $name = $item.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                $hashes[$name + '/'] = 'directory'
                $pending.Push($item.FullName)
                continue
            }
            if ($name -ceq '.release-proof.json') { continue }
            $total += $item.Length
            if ($total -gt 2147483648) { throw 'Cached package exceeds its size limit.' }
            $hashes[$name] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
    return $hashes
}

function Write-CliPackageProof {
    param([string]$Directory, [string]$Version, [string]$Digest, [string]$Agent)

    # The release digest identifies the archive. The file map binds cache
    # reuse to the extracted tree, including executables and their resources.
    $files = Get-CliPackageHash $Directory
    if (-not $files.Count -or $Digest -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid verified release proof.' }
    $proof = [ordered]@{ agent = $Agent; release = $Version; archive = $Digest; files = $files }
    $path = Join-Path $Directory '.release-proof.json'
    $stream = [IO.FileStream]::new($path, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json -Depth 4 -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Test-CliPackageProof {
    param([string]$Directory, [string]$Agent, [string]$Version, [string]$Digest)

    try {
        Assert-CliPackageDirectory $Directory
        $file = Get-Item -LiteralPath (Join-Path $Directory '.release-proof.json') -Force
        if ($file.PSIsContainer -or $file.Length -gt 1048576 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        $proof = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($proof.agent -cne $Agent -or -not (ConvertTo-NormalizedVersion $proof.release) -or
            $proof.archive -cnotmatch '^[0-9a-f]{64}$' -or ($Version -and $proof.release -cne $Version) -or
            ($Digest -and $proof.archive -cne $Digest)) { return $false }
        if (-not $Version -and [IO.Path]::GetFileName($Directory) -cnotmatch ('^' + [regex]::Escape($proof.release) + '(?:-[0-9a-f]{32})?$')) { return $false }
        $files = Get-CliPackageHash $Directory
        if (-not $files.Count -or $files.Count -ne @($proof.files.PSObject.Properties).Count) { return $false }
        foreach ($property in $proof.files.PSObject.Properties) {
            if ($files[$property.Name] -cne $property.Value) { return $false }
        }
        return $true
    }
    catch { return $false }
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
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$SourceExe, [string]$TargetExe, [string]$ExpectedVersion)
    if (-not $PSCmdlet.ShouldProcess($TargetExe, 'Activate the staged executable')) { return }
    $pending = "$TargetExe.pending-$([guid]::NewGuid().ToString('N')).exe"
    $oldExe = "$TargetExe.old-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::Copy($SourceExe, $pending, $false)
        if ((Get-FileHash -LiteralPath $SourceExe -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash) {
            throw 'Executable staging verification failed.'
        }
        if ($ExpectedVersion -and -not (Test-VersionEqual (Get-ExeVersion -ExePath $pending) $ExpectedVersion)) {
            throw "Staged executable does not report the expected version: $ExpectedVersion"
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
        throw "Could not activate '$TargetExe'. Close the affected CLI and retry. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
    }
    if (Test-Path -LiteralPath $oldExe) {
        try { Remove-Item -LiteralPath $oldExe }
        catch { Write-Warn "Update activated; could not remove old executable. Recovery copy retained: $oldExe ($($_.Exception.Message))" }
    }
}

# ---------------------------------------------------------------------------
# OpenCode
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Resolves the latest stable OpenCode 2.x version from GitHub releases.
.OUTPUTS
    A normalized version string without the 'v' prefix.
.NOTES
    The repository's "latest" release alias still points at the 1.x line, so
    list recent releases and take the highest stable v2.* tag instead.
#>
function Get-OpenCodeLatestVersion {
    $headers = @{ 'User-Agent' = 'update-ai-clis'; 'Accept' = 'application/vnd.github+json' }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $raw = Get-RemoteText -Uri $script:OpenCodeReleasesApi -Headers $headers
            $releases = ConvertFrom-Json -InputObject ([string]$raw)
            $latest = $releases | Where-Object {
                (-not $_.draft) -and (-not $_.prerelease) -and
                ([string]$_.tag_name -cmatch '^v2\.[0-9]+\.[0-9]+$')
            } | Sort-Object -Property @{ Expression = {
                    [version]([string]$_.tag_name).Substring(1)
                } } -Descending | Select-Object -First 1
            if ($null -ne $latest) {
                return (ConvertTo-NormalizedVersion $latest.tag_name)
            }
            throw 'The release list contained no stable OpenCode 2.x tag.'
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    throw "Could not resolve the latest OpenCode 2.x release: $lastError"
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
function Remove-OldOpenCodeVersion {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$CurrentVersion, [int]$Keep = 3)

    $versionsDir = Join-Path $script:OpenCodeRoot 'versions'
    if (-not (Test-Path -LiteralPath $versionsDir)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $versionsDir -Directory |
            Where-Object { $_.Name -ne $CurrentVersion -and (Test-CliPackageProof $_.FullName 'opencode') } |
            Sort-Object -Property LastWriteTime -Descending)

    $dirs | Select-Object -Skip ([Math]::Max($Keep - 1, 0)) | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove the old OpenCode version')) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Installs or updates the OpenCode CLI for the current user.
.PARAMETER Version
    Version to install. Empty selects the latest stable 2.x release.
.NOTES
    -Check only reports installed and available versions. A normal run downloads
    and extracts a temporary zip, stores the binary under versions\<version>,
    points bin\opencode.exe at it, verifies the reported version, and prunes old
    version directories. Downloads and version strings come from the official
    GitHub release metadata for the v2 line.
#>
function Install-OpenCode {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:OpenCodeExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-OpenCodeLatestVersion }
            else { $latest = ConvertTo-NormalizedVersion $Version }
        }
        catch {
            Write-Warn "Could not check the latest version: $($_.Exception.Message)"
        }
        Write-Info "OpenCode: installed $(if ($installed) { $installed } else { 'none' }), available $(if ($latest) { $latest } else { 'unknown' })"
        Write-Info "OpenCode: path $script:OpenCodeExe"
        return
    }

    $platform = Get-PlatformTag
    $version = ConvertTo-NormalizedVersion $Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = Get-OpenCodeLatestVersion }

    $installed = Get-ExeVersion -ExePath $script:OpenCodeExe
    if ((Test-VersionEqual $installed $version) -and -not $Force) {
        Write-Info "OpenCode: already up to date ($installed). Nothing to do."
        return
    }

    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Invalid OpenCode release version.'
    }
    $asset = if ($platform -eq 'x64') { 'opencode-windows-x64-baseline.zip' } else { "opencode-windows-$platform.zip" }
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

    if ($Force -or -not (Test-CliPackageProof $versionDir 'opencode' $version $expectedDigest)) {
        if (Test-Path -LiteralPath $versionDir) {
            $versionDir += '-' + [guid]::NewGuid().ToString('N')
            $versionExe = Join-Path $versionDir 'opencode.exe'
        }
        Assert-CliPackageDirectory $versionDir
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
                    [IO.File]::Move($pending, $versionExe)
                    Write-CliPackageProof $versionDir $version $expectedDigest 'opencode'
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
    Set-CurrentExe -SourceExe $versionExe -TargetExe $script:OpenCodeExe -ExpectedVersion $version

    $verified = Get-ExeVersion -ExePath $script:OpenCodeExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "OpenCode verification failed: $script:OpenCodeExe reports '$verified' but '$version' was expected."
    }

    Write-Info "OpenCode: $verified installed to $script:OpenCodeBin"
    Remove-OldOpenCodeVersion -CurrentVersion (Split-Path -Leaf $versionDir)
}

# ---------------------------------------------------------------------------
# Crush
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Resolves the latest Crush release tag from the GitHub API.
.NOTES
    Sends a User-Agent and the GitHub JSON media type, then normalizes the 'v'
    tag prefix away.
#>
function Get-CrushLatestVersion {
    return (Get-GitHubStableVersion $script:CrushLatestApi)
}

<#
.SYNOPSIS
    Returns the Crush Windows release target for this machine.
.OUTPUTS
    x86_64 or arm64.
#>
function Get-CrushTarget {
    $platform = Get-PlatformTag -AllowX86
    switch ($platform) {
        'x64' { return 'x86_64' }
        'arm64' { return 'arm64' }
        'x86' { return 'i386' }
        default { throw "Unsupported architecture for Crush: $platform" }
    }
}

<#
.SYNOPSIS
    Prunes old Crush version directories.
.PARAMETER CurrentVersion
    Directory name of the active version, which is never removed.
.PARAMETER Keep
    Total number of versions to keep, including the current one.
.NOTES
    Non-current directories are ordered by LastWriteTime, newest first. Removal
    failures are ignored because stale versions are not fatal.
#>
function Remove-OldCrushVersion {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$CurrentVersion, [int]$Keep = 3)

    if (-not (Test-Path -LiteralPath $script:CrushVersions)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $script:CrushVersions -Directory |
            Where-Object { $_.Name -ne $CurrentVersion -and (Test-CliPackageProof $_.FullName 'crush') } |
            Sort-Object -Property LastWriteTime -Descending)

    $dirs | Select-Object -Skip ([Math]::Max($Keep - 1, 0)) | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove the old Crush version')) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Installs or updates the Crush CLI for the current user.
.PARAMETER Version
    Version to install. Empty selects the latest release.
.NOTES
    -Check only reports installed and available versions. A normal run downloads
    and extracts a temporary zip, stores the binary under versions\<version>,
    points bin\crush.exe at it, verifies the reported version, and prunes old
    version directories. Downloads come from the official GitHub release and
    require the published SHA-256 digest plus one expected crush.exe entry.
#>
function Install-Crush {
    param([string]$Version)

    if ($Check) {
        $installed = Get-ExeVersion -ExePath $script:CrushExe
        $latest = $null
        try {
            if ([string]::IsNullOrWhiteSpace($Version)) { $latest = Get-CrushLatestVersion }
            else { $latest = ConvertTo-NormalizedVersion $Version }
        }
        catch {
            Write-Warn "Could not check the latest version: $($_.Exception.Message)"
        }
        Write-Info "Crush: installed $(if ($installed) { $installed } else { 'none' }), available $(if ($latest) { $latest } else { 'unknown' })"
        Write-Info "Crush: path $script:CrushExe"
        return
    }

    $target = Get-CrushTarget
    $version = ConvertTo-NormalizedVersion $Version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = Get-CrushLatestVersion }

    $installed = Get-ExeVersion -ExePath $script:CrushExe
    if ((Test-VersionEqual $installed $version) -and -not $Force) {
        Write-Info "Crush: already up to date ($installed). Nothing to do."
        return
    }

    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Invalid Crush release version.'
    }
    $asset = "crush_${version}_Windows_$target.zip"
    $release = (Get-RemoteText -Uri "https://api.github.com/repos/charmbracelet/crush/releases/tags/v$version") | ConvertFrom-Json
    $assets = @($release.assets | Where-Object { $_.name -ceq $asset })
    if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Expected one Crush release asset with a published SHA-256 digest.'
    }
    $url = [string]$assets[0].browser_download_url
    if (-not $url.StartsWith('https://github.com/charmbracelet/crush/releases/download/', [StringComparison]::Ordinal)) {
        throw 'Unexpected Crush release URL.'
    }
    $expectedDigest = $assets[0].digest.Substring(7)
    $versionDir = Join-Path $script:CrushVersions $version
    $versionExe = Join-Path $versionDir 'crush.exe'

    if ($Force -or -not (Test-CliPackageProof $versionDir 'crush' $version $expectedDigest)) {
        if (Test-Path -LiteralPath $versionDir) {
            $versionDir += '-' + [guid]::NewGuid().ToString('N')
            $versionExe = Join-Path $versionDir 'crush.exe'
        }
        Assert-CliPackageDirectory $versionDir
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("crush-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $zip = Join-Path $tempRoot $asset
            Write-Info "Crush: downloading $version ($target)"
            Invoke-Download -Uri $url -OutFile $zip

            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedDigest) {
                throw 'Crush release SHA-256 mismatch.'
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entryName = "$($asset.Substring(0, $asset.Length - 4))/crush.exe"
                $entries = @($archive.Entries | Where-Object { $_.FullName -ceq $entryName })
                if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or
                    $entries[0].Length -gt 536870912 -or
                    (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw 'Expected exactly one regular crush.exe entry.'
                }
                New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
                $pending = Join-Path $versionDir ('.crush-' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $pending)
                    [IO.File]::Move($pending, $versionExe)
                    Write-CliPackageProof $versionDir $version $expectedDigest 'crush'
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

    New-Item -ItemType Directory -Force -Path $script:CrushBin | Out-Null
    Set-CurrentExe -SourceExe $versionExe -TargetExe $script:CrushExe -ExpectedVersion $version

    $verified = Get-ExeVersion -ExePath $script:CrushExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "Crush verification failed: $script:CrushExe reports '$verified' but '$version' was expected."
    }

    Write-Info "Crush: $verified installed to $script:CrushBin"
    Remove-OldCrushVersion -CurrentVersion (Split-Path -Leaf $versionDir)
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
    return (Get-GitHubStableVersion $script:CodexLatestApi)
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

function Get-CodexActivePackage {
    $item = Get-Item -LiteralPath $script:CodexBin -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'Junction' -or -not $item.Target) { return $null }
    $target = [IO.DirectoryInfo]::new(([string]$item.Target))
    if ($target.Name -ine 'bin' -or -not $target.Parent -or -not $target.Parent.Parent) { return $null }
    if ($target.Parent.Parent.FullName -ine $script:CodexVersions) { return $null }
    return $target.Parent.FullName
}

<#
.SYNOPSIS
    Points the visible Codex bin directory at a version directory.
.PARAMETER VersionDir
    Version directory containing bin, codex-resources, and codex-package.json.
.NOTES
    Stages a replacement junction before moving the previous bin aside.
#>
function Set-CodexVisibleBin {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VersionDir, [string]$ExpectedVersion)
    if (-not $PSCmdlet.ShouldProcess($script:CodexBin, 'Activate the Codex version')) { return }

    $guid = [guid]::NewGuid().ToString('N')
    $pending = "$($script:CodexBin).pending-$guid"
    $backup = "$($script:CodexBin).previous-$guid"
    # Capture the old path type before moving it. Cleanup can remove a
    # retired junction without traversing its target but keeps a real folder.
    $previous = Get-Item -LiteralPath $script:CodexBin -Force -ErrorAction SilentlyContinue
    $previousWasJunction = $previous -and ($previous.Attributes -band [IO.FileAttributes]::ReparsePoint)
    New-Item -ItemType Junction -Path $pending -Target (Join-Path $VersionDir 'bin') | Out-Null

    $activated = $false
    try {
        if ($previous) { [IO.Directory]::Move($script:CodexBin, $backup) }
        [IO.Directory]::Move($pending, $script:CodexBin)
        $activated = $true
        if (-not (Test-VersionEqual (Get-ExeVersion -ExePath $script:CodexExe) $ExpectedVersion)) {
            throw 'Codex failed verification after activation.'
        }
    }
    catch {
        if ($activated) {
            try { [IO.Directory]::Move($script:CodexBin, $pending) }
            catch { Write-Warn "Codex could not move the failed activation aside: $($script:CodexBin)" }
        }
        if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $script:CodexBin)) {
            try { [IO.Directory]::Move($backup, $script:CodexBin) }
            catch { Write-Warn "Codex recovery directory: $backup" }
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $pending) {
            try { [IO.Directory]::Delete($pending, $false) }
            catch { Write-Warn "Codex: unused junction retained at $pending" }
        }
    }

    if ($previousWasJunction) {
        try { [IO.Directory]::Delete($backup, $false) }
        catch { Write-Warn "Codex: previous junction retained at $backup" }
    }
    elseif ($previous) { Write-Info "Codex: previous directory retained at $backup" }
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
function Remove-OldCodexVersion {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$CurrentVersion, [int]$Keep = 3)

    if (-not (Test-Path -LiteralPath $script:CodexVersions)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $script:CodexVersions -Directory |
            Where-Object { $_.Name -ne $CurrentVersion -and (Test-CliPackageProof $_.FullName 'codex') } |
            Sort-Object -Property LastWriteTime -Descending)

    $dirs | Select-Object -Skip ([Math]::Max($Keep - 1, 0)) | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove the old Codex version')) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CodexTar {
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $tar = Join-Path (Join-Path $env:SystemRoot $systemDirectory) 'tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
        throw 'Codex needs the tar.exe supplied by supported Windows versions.'
    }
    return $tar
}

function Expand-CodexPackage {
    param([string]$Archive, [string]$Destination)

    $tar = Get-CodexTar
    $PSNativeCommandUseErrorActionPreference = $false
    $entries = @(& $tar -tvzf $Archive)
    if ($LASTEXITCODE -ne 0 -or -not $entries.Count -or $entries.Count -gt 4096) {
        throw 'Could not read the Codex archive catalog.'
    }

    $seen = @{}
    $total = 0L
    foreach ($entry in $entries) {
        # Windows bsdtar prints mode, link count, user, group, byte count,
        # three date fields and name. Also accept GNU tar's fixture format.
        if ($entry -cnotmatch '^(?<type>[d-])[rwxstST-]{9}\s+(?:\d+\s+)?\S+(?:\s+\S+)?\s+(?<size>\d+)\s+(?:\d{4}-\d{2}-\d{2}\s+\S+|\S+\s+\S+\s+\S+)\s+(?<name>\S+)$') {
            throw 'Codex archive contains a special file or unrecognized catalog entry.'
        }
        $member = ($Matches.name -replace '^\./', '').TrimEnd('/')
        $total += [long]$Matches.size
        if ($member -eq '' -and $Matches.type -eq 'd') { continue }
        if ($total -gt 2147483648 -or $seen.ContainsKey($member) -or
            $member -cnotmatch '^(?:codex-package\.json|(?:bin|codex-path|codex-resources)(?:/[A-Za-z0-9][A-Za-z0-9._+-]*)*)$' -or
            $member -match '(?:^|/)(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:[./]|$)|\.(?:/|$)') {
            throw "Unsafe or duplicate Codex archive member: $member"
        }
        $seen[$member] = $true
    }

    & $tar -xzf $Archive -C $Destination --no-same-owner --no-same-permissions
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Codex package.' }
}

function Test-CodexPackage {
    param([string]$Directory, [string]$Version, [string]$Target)

    $manifest = Join-Path $Directory 'codex-package.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    try {
        $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        if ($data.layoutVersion -ne 1 -or -not (Test-VersionEqual $data.version $Version) -or
            $data.target -cne $Target -or $data.variant -cne 'codex' -or $data.entrypoint -cne 'bin/codex.exe' -or
            $data.resourcesDir -cne 'codex-resources' -or $data.pathDir -cne 'codex-path') { return $false }
        $required = @('bin/codex.exe', 'bin/codex-code-mode-host.exe', 'codex-path/rg.exe',
            'codex-resources/codex-command-runner.exe', 'codex-resources/codex-windows-sandbox-setup.exe')
        if ($data.PSObject.Properties['execServer']) {
            if ($data.execServer -cne 'bin/codex-exec-server.exe') { return $false }
            $required += $data.execServer
        }
        foreach ($name in $required) {
            $file = Get-Item -LiteralPath (Join-Path $Directory $name) -Force
            if ($file.PSIsContainer -or $file.Length -le 0 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        }
        return (Test-VersionEqual (Get-ExeVersion (Join-Path $Directory 'bin/codex.exe')) $Version)
    }
    catch { return $false }
}

function Install-Codex {
    param([string]$Version)

    if (-not $Version) { $Version = Get-CodexLatestVersion }
    if (-not (ConvertTo-NormalizedVersion $Version)) { throw 'Invalid Codex version.' }
    if ($Check) { return }
    $target = Get-CodexTarget
    $tag = "rust-v$Version"
    $name = "codex-package-$target.tar.gz"
    $release = Get-RemoteText -Uri "https://api.github.com/repos/openai/codex/releases/tags/$tag" | ConvertFrom-Json
    $asset = @($release.assets | Where-Object { $_.name -ceq $name })
    $url = "https://github.com/openai/codex/releases/download/$tag/$name"
    if ($asset.Count -ne 1 -or $asset[0].browser_download_url -cne $url -or $asset[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'No canonical Codex package with a published SHA-256 digest is available for this version.'
    }
    $digest = $asset[0].digest.Substring(7)
    $active = Get-CodexActivePackage
    if (-not $Force -and $active -and (Test-CliPackageProof $active 'codex' $Version $digest) -and
        (Test-CodexPackage $active $Version $target)) { return }

    $versionDir = Join-Path $script:CodexVersions $Version
    if ($Force -or -not (Test-CliPackageProof $versionDir 'codex' $Version $digest) -or
        -not (Test-CodexPackage $versionDir $Version $target)) {
        $id = [guid]::NewGuid().ToString('N')
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-install-$id"
        $stage = Join-Path $script:CodexVersions ".staging-$id"
        Assert-CliPackageDirectory $stage
        $null = New-Item -ItemType Directory -Path $tempRoot
        try {
            $archive = Join-Path $tempRoot $name
            Write-Info "Codex: downloading $Version ($target)"
            Invoke-Download -Uri $url -OutFile $archive
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $digest) {
                throw 'Codex package SHA-256 mismatch.'
            }

            $null = New-Item -ItemType Directory -Path $stage -Force
            Expand-CodexPackage -Archive $archive -Destination $stage
            Write-CliPackageProof $stage $Version $digest 'codex'
            if (-not (Test-CodexPackage $stage $Version $target)) { throw 'The downloaded Codex package is incomplete or reports the wrong version.' }
            if (Test-Path -LiteralPath $versionDir) { $versionDir = "$versionDir-$id" }
            [IO.Directory]::Move($stage, $versionDir)
        }
        finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Set-CodexVisibleBin -VersionDir $versionDir -ExpectedVersion $Version
    Remove-OldCodexVersion -CurrentVersion (Split-Path -Leaf $versionDir)
}

# ---------------------------------------------------------------------------
# Codex daemon (independent managed package)
# ---------------------------------------------------------------------------
function Invoke-CodexDaemonUpdate {
    if ($Check) {
        Write-Info 'Codex daemon: update skipped in check mode.'
        return
    }
    # The official lifecycle command respects CODEX_HOME, updates the separate
    # daemon package and restarts only a daemon that was already running.
    $PSNativeCommandUseErrorActionPreference = $false
    Write-Info 'Codex daemon: checking for a stable update (a running daemon may restart).'
    $output = & $script:CodexExe app-server daemon update
    if ($LASTEXITCODE -ne 0) { throw "Codex daemon update failed (exit code $LASTEXITCODE)." }
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.status -notin @('updated', 'noUpdate')) {
        throw "Codex daemon update was not completed: $($result | ConvertTo-Json -Compress)"
    }
    Write-Info "Codex daemon: $($result.status) (installed $($result.installedVersion), running $($result.runningVersion))."
}

# GitHub Copilot's standalone archive contains the executable and bundled
# runtime. PowerShell is already present because it is running this script.
function Get-CopilotLatestVersion {
    return (Get-GitHubStableVersion 'https://api.github.com/repos/github/copilot-cli/releases/latest')
}

function Install-CopilotCli {
    param([string]$Version)

    $assetName = "copilot-win32-$(Get-PlatformTag).zip"
    $release = Get-RemoteText -Uri "https://api.github.com/repos/github/copilot-cli/releases/tags/v$Version" | ConvertFrom-Json
    $assets = @($release.assets | Where-Object { $_.name -ceq $assetName })
    $url = "https://github.com/github/copilot-cli/releases/download/v$Version/$assetName"
    if ($assets.Count -ne 1 -or $assets[0].browser_download_url -cne $url -or
        $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Expected one official Copilot CLI release archive with a SHA-256 digest.'
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('copilot-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    try {
        $zip = Join-Path $tempRoot $assetName
        Invoke-Download -Uri $url -OutFile $zip
        $digest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($digest -ine $assets[0].digest.Substring(7)) { throw 'Copilot CLI release SHA-256 mismatch.' }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        $staged = Join-Path $tempRoot 'copilot.exe'
        try {
            $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'copilot.exe' })
            if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or $entries[0].Length -gt 1073741824 -or
                (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Expected exactly one regular copilot.exe entry.'
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $staged)
        }
        finally { $archive.Dispose() }

        $null = New-Item -ItemType Directory -Path $script:CopilotBin -Force
        Set-CurrentExe -SourceExe $staged -TargetExe $script:CopilotExe -ExpectedVersion $Version
    }
    finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-ClaudeLatestVersion {
    $version = ConvertTo-NormalizedVersion (Get-RemoteText -Uri "$script:ClaudeSource/stable")
    if (-not (Test-StableVersionAtLeast $version $version)) {
        throw 'Anthropic did not return a valid stable Claude Code release.'
    }
    return $version
}

function Test-ClaudeSignature {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) { return $false }
    $publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    return ($publisher -ceq 'Anthropic, PBC')
}

function Install-ClaudeCode {
    param([string]$Version)

    # The native package works with Windows PowerShell. Git for Windows adds
    # optional Bash tooling. Verify the binary with Windows' trusted roots
    # directly, avoiding a GPG installation just to check the manifest.
    $platform = "win32-$(Get-PlatformTag)"
    $base = "$script:ClaudeSource/$Version"
    $manifest = Get-RemoteText -Uri "$base/manifest.json" | ConvertFrom-Json
    $metadata = $manifest.platforms.PSObject.Properties[$platform]
    if ($manifest.version -cne $Version -or -not $metadata -or $metadata.Value.binary -cne 'claude.exe' -or
        $metadata.Value.checksum -cnotmatch '^[0-9a-f]{64}$' -or $metadata.Value.size -le 0) {
        throw 'Unexpected Claude Code release manifest.'
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    try {
        $staged = Join-Path $tempRoot 'claude.exe'
        Invoke-Download -Uri "$base/$platform/claude.exe" -OutFile $staged
        if ((Get-Item -LiteralPath $staged).Length -ne $metadata.Value.size -or
            (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ine $metadata.Value.checksum) {
            throw 'Claude Code release size or SHA-256 mismatch.'
        }
        if (-not (Test-ClaudeSignature $staged)) { throw 'Claude Code must have a valid Anthropic, PBC Authenticode signature.' }
        $null = New-Item -ItemType Directory -Path $script:ClaudeBin -Force
        Set-CurrentExe -SourceExe $staged -TargetExe $script:ClaudeExe -ExpectedVersion $Version
    }
    finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-SwivalPlatform {
    try { return ((Get-PlatformTag) -eq 'x64') }
    catch { return $false }
}

function Find-SwivalWheel {
    param($Files, [string]$Version)

    $name = "swival-$Version-py3-none-any.whl"
    $pattern = '^https://files\.pythonhosted\.org/packages/[0-9a-f/]+/' + [regex]::Escape($name) + '$'
    $wheels = @($Files | Where-Object {
            $_.filename -ceq $name -and $_.packagetype -ceq 'bdist_wheel' -and
            $_.yanked -is [bool] -and -not $_.yanked -and $_.url -cmatch $pattern -and
            $_.digests.sha256 -cmatch '^[0-9a-f]{64}$'
        })
    if ($wheels.Count -eq 1) { return $wheels[0] }
    return $null
}

function Get-SwivalLatestVersion {
    $data = Get-RemoteText -Uri 'https://pypi.org/pypi/swival/json' | ConvertFrom-Json
    if ($data.info.name -cne 'swival') { throw 'PyPI did not return Swival package metadata.' }
    $stable = @($data.releases.PSObject.Properties | Where-Object {
            $_.Name -cmatch "^$script:SemVerCore$" -and (Find-SwivalWheel $_.Value $_.Name)
        } | Sort-Object -Property @{ Expression = { [version]$_.Name } } -Descending)
    if (-not $stable.Count) { throw 'PyPI did not return a stable, non-yanked Swival wheel.' }
    return $stable[0].Name
}

function Get-SwivalUv {
    $release = Get-RemoteText -Uri 'https://api.github.com/repos/astral-sh/uv/releases/latest' | ConvertFrom-Json
    $version = ConvertTo-NormalizedVersion $release.tag_name
    if ($release.draft -or $release.prerelease -or -not (Test-StableVersionAtLeast $version $version)) {
        throw 'Astral did not return a valid stable uv release.'
    }
    $asset = 'uv-x86_64-pc-windows-msvc.zip'
    $url = "https://github.com/astral-sh/uv/releases/download/$version/$asset"
    $assets = @($release.assets | Where-Object { $_.name -ceq $asset })
    if ($assets.Count -ne 1 -or $assets[0].browser_download_url -cne $url -or
        $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Expected one official Astral uv asset with a published SHA-256 digest.'
    }
    $digest = $assets[0].digest.Substring(7)
    $root = Join-Path $script:SwivalRoot 'uv'
    $directory = Join-Path $root $version
    $exe = Join-Path $directory 'uv.exe'
    if ((Test-CliPackageProof $directory 'swival-uv' $version $digest) -and
        (Test-VersionEqual (Get-ExeVersion $exe) $version)) { return $exe }
    if (Test-Path -LiteralPath $root -PathType Container) {
        Assert-CliPackageDirectory $root
        foreach ($cache in Get-ChildItem -LiteralPath $root -Directory -Filter "$version-*") {
            if ($cache.Name -cnotmatch ('^' + [regex]::Escape($version) + '-[0-9a-f]{32}$')) { continue }
            $exe = Join-Path $cache.FullName 'uv.exe'
            if ((Test-CliPackageProof $cache.FullName 'swival-uv' $version $digest) -and
                (Test-VersionEqual (Get-ExeVersion $exe) $version)) { return $exe }
        }
    }

    $stage = Join-Path $root ('.staging-' + [guid]::NewGuid().ToString('N'))
    Assert-CliPackageDirectory $stage
    $null = New-Item -ItemType Directory -Path $stage -Force
    try {
        Assert-CliPackageDirectory $stage
        $archive = Join-Path $stage $asset
        Invoke-Download -Uri $url -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $digest) {
            throw 'Astral uv release SHA-256 mismatch.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        $staged = Join-Path $stage 'uv.exe'
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -ceq 'uv.exe' })
            if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or $entries[0].Length -gt 268435456 -or
                (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -notin @(0, 0x8000) -or
                ($entries[0].ExternalAttributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) {
                throw 'Expected one regular uv.exe in the Astral archive.'
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $staged)
        }
        finally { $zip.Dispose() }
        Remove-Item -LiteralPath $archive
        if (-not (Test-VersionEqual (Get-ExeVersion $staged) $version)) { throw 'Staged uv reports an unexpected version.' }
        Write-CliPackageProof $stage $version $digest 'swival-uv'
        if (Test-Path -LiteralPath $directory) {
            $directory += '-' + [guid]::NewGuid().ToString('N')
        }
        [IO.Directory]::Move($stage, $directory)
        return (Join-Path $directory 'uv.exe')
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Get-SwivalUvStartInfo {
    param([string]$Uv, [string]$Directory, [string[]]$UvArgs)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Uv
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # The arguments are fixed switches and a validated HTTPS requirement.
    if (@($UvArgs | Where-Object { $_ -match '[\x00-\x1f"\\]' }).Count) { throw 'Invalid uv argument.' }
    $start.Arguments = (@('--no-config', '--no-progress') + $UvArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(UV_|PIP_|PYTHON|VIRTUAL_ENV$|CONDA_|RUST_LOG$)') { $start.EnvironmentVariables.Remove($key) }
    }
    $start.EnvironmentVariables['UV_CACHE_DIR'] = Join-Path $script:SwivalRoot 'cache'
    $start.EnvironmentVariables['UV_PYTHON_INSTALL_DIR'] = Join-Path $script:SwivalRoot 'python'
    $start.EnvironmentVariables['UV_PYTHON_NO_REGISTRY'] = '1'
    $start.EnvironmentVariables['UV_PYTHON_INSTALL_BIN'] = '0'
    $start.EnvironmentVariables['UV_TOOL_DIR'] = Join-Path $Directory 'tools'
    $start.EnvironmentVariables['UV_TOOL_BIN_DIR'] = Join-Path $Directory 'bin'
    return $start
}

function Invoke-SwivalUv {
    param([string]$Uv, [string]$Directory, [string[]]$UvArgs, [switch]$Output)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = Get-SwivalUvStartInfo $Uv $Directory $UvArgs
    try {
        if (-not $process.Start()) { throw 'Could not start uv.' }
        if ($Output) {
            $buffer = [char[]]::new(8192)
            $read = $process.StandardOutput.ReadBlockAsync($buffer, 0, $buffer.Length)
        }
        else { $read = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null) }
        $errors = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $timeout = if ($Output) { 15000 } else { 600000 }
        if (-not $process.WaitForExit($timeout)) { throw 'uv exceeded the operation time limit.' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($read, $errors), 5000)) {
            throw 'uv left its output streams open.'
        }
        if ($process.ExitCode -ne 0) { throw "uv $($UvArgs[0]) operation failed with exit code $($process.ExitCode)." }
        if ($Output) {
            if ($read.Result -ge $buffer.Length) { throw 'uv returned too much output.' }
            return ([string]::new($buffer, 0, $read.Result)).Trim()
        }
    }
    finally {
        try {
            if (-not $process.HasExited) {
                if ($PSVersionTable.PSEdition -eq 'Desktop') { $process.Kill() }
                else { $process.Kill($true) }
            }
        }
        catch { Write-Verbose 'The uv process has already exited or could not be stopped.' }
        $process.Dispose()
    }
}

function Initialize-SwivalPython {
    foreach ($folder in @('cache', 'python')) {
        $path = Join-Path $script:SwivalRoot $folder
        Assert-CliPackageDirectory $path
        $null = New-Item -ItemType Directory -Path $path -Force
        Assert-CliPackageDirectory $path
    }
    $uv = Get-SwivalUv
    Invoke-SwivalUv $uv $script:SwivalRoot @('python', 'install', '3.14', '--upgrade', '--no-bin', '--no-registry')
    $python = Invoke-SwivalUv $uv $script:SwivalRoot @('python', 'find', '3.14', '--managed-python') -Output
    $pythonRoot = (Join-Path $script:SwivalRoot 'python') + [IO.Path]::DirectorySeparatorChar
    if (-not $python -or -not [IO.Path]::IsPathRooted($python) -or
        -not [IO.Path]::GetFullPath($python).StartsWith($pythonRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PrivateCliPath $python) -or (Get-ExeVersion $python) -cnotmatch '^3\.14\.[0-9]+$') {
        throw 'Could not verify the private, uv-managed Python 3.14 interpreter.'
    }
    return $uv
}

function Install-Swival {
    param([string]$Version)

    $data = Get-RemoteText -Uri "https://pypi.org/pypi/swival/$Version/json" | ConvertFrom-Json
    if ($data.info.name -cne 'swival' -or $data.info.version -cne $Version) { throw 'Unexpected Swival release metadata.' }
    $wheel = Find-SwivalWheel $data.urls $Version
    if (-not $wheel) { throw 'The selected release has no trusted Swival wheel.' }
    $uv = Initialize-SwivalPython
    $privateRelease = Join-Path $script:SwivalRoot ('releases/' + $Version + '-' + [guid]::NewGuid().ToString('N'))
    Assert-CliPackageDirectory $privateRelease
    $null = New-Item -ItemType Directory -Path $privateRelease -Force
    $activated = $false
    try {
        Assert-CliPackageDirectory $privateRelease
        $requirement = "swival @ $($wheel.url)#sha256=$($wheel.digests.sha256)"
        Invoke-SwivalUv $uv $privateRelease @('tool', 'install', '--managed-python', '--python', '3.14',
            '--default-index', 'https://pypi.org/simple', '--only-binary', ':all:', '--', $requirement)
        # uv's launcher targets the environment at its original location.
        # Keep that directory intact and publish only its verified launcher.
        $staged = Join-Path $privateRelease 'bin/swival.exe'
        Assert-CliPackageDirectory (Split-Path -Parent $staged)
        if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) { throw 'uv did not install a Swival executable.' }
        $item = Get-Item -LiteralPath $staged -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Swival launcher is a reparse point.' }
        Assert-CliPackageDirectory $script:SwivalBin
        $null = New-Item -ItemType Directory -Path $script:SwivalBin -Force
        Set-CurrentExe -SourceExe $staged -TargetExe $script:SwivalExe -ExpectedVersion $Version
        $activated = $true
    }
    finally {
        if (-not $activated) { Remove-Item -LiteralPath $privateRelease -Recurse -Force }
    }
    return $uv
}

function Get-SwivalUvLocation {
    $visible = Join-Path $script:SwivalBin 'uv.exe'
    $active = Get-CliSnapshot -Name 'uv' -ManagedPath $visible
    $persistent = Get-CliSnapshot -Name 'uv' -ManagedPath $visible -Persistent
    if ($active.Unsafe -or $persistent.Unsafe -or $active.Conflict -or $persistent.Conflict -or
        ($active.ActivePath -and $persistent.ActivePath -and $active.ActivePath -ine $persistent.ActivePath)) {
        throw 'Resolve conflicting or unsafe uv installations.'
    }
    $path = if ($active.ActivePath) { $active.ActivePath } else { $persistent.ActivePath }
    if ($path -and $path -ine $visible -and (-not $persistent.ActivePath -or -not $persistent.ActiveVersion)) {
        throw 'The existing uv must be usable through its original installer on persistent PATH.'
    }
    return $path
}

function Enable-SwivalUv {
    param([string]$Uv, [string]$ExistingPath)

    $visible = Join-Path $script:SwivalBin 'uv.exe'
    if ($ExistingPath -and $ExistingPath -ine $visible) {
        # Keep an existing usable installation in its own package manager.
        $expectedPath = $ExistingPath
        $expected = Get-ExeVersion $ExistingPath
    }
    else {
        $expectedPath = $visible
        $expected = Get-ExeVersion $Uv
        if (-not $expected) { throw 'The verified uv binary no longer reports its version.' }
        if (-not (Test-VersionEqual (Get-ExeVersion $visible) $expected)) {
            Set-CurrentExe -SourceExe $Uv -TargetExe $visible -ExpectedVersion $expected
        }
    }
    if (-not $expected -or -not (Test-VersionEqual (Get-FreshCliVersion 'uv' $expectedPath) $expected)) {
        throw 'Could not verify uv in the persistent PATH.'
    }
}

# ---------------------------------------------------------------------------
# Bun (official upstream downloads)
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Installs or checks Bun using official direct downloads with SHA-256 verification.
.NOTES
    Uses BUN_INSTALL or ~/.bun; -Check does not install or change PATH.
#>
<#
.SYNOPSIS
    Removes the winget Bun package after verifying the official installation.
#>
function Uninstall-BunWinget {
    if ($Check) { return }
    $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $winget) { return }
    $PSNativeCommandUseErrorActionPreference = $false
    & $winget.Source list --id Oven-sh.Bun --exact --source winget --scope user --disable-interactivity --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq -1978335212) { return }
    if ($LASTEXITCODE -ne 0) { throw "winget Bun detection failed (exit code $LASTEXITCODE)." }
    & $winget.Source uninstall --id Oven-sh.Bun --exact --source winget --scope user --silent --disable-interactivity --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335212) {
        throw "winget Bun uninstall failed (exit code $LASTEXITCODE). The official installation was retained."
    }
    Write-Info 'Bun: old winget package removed.'
}
function Install-Bun {
    param([string]$Version)

    $bunRoot = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $env:USERPROFILE '.bun' }
    $bunBin = Join-Path $bunRoot 'bin'
    $bunExe = Join-Path $bunBin 'bun.exe'
    if (-not $Version) { $Version = Get-BunLatestVersion }
    $installed = Get-ExeVersion -ExePath $bunExe
    if ($Check) {
        Write-Info "Bun: installed $(if ($installed) { $installed } else { 'none' }), available $version"
        return
    }
    if ((Test-VersionEqual $installed $version) -and -not $Force) {
        Write-Info "Bun: already up to date ($installed). Nothing to do."
        if ($RemoveWinget) { Uninstall-BunWinget }
        return
    }
    $platform = Get-PlatformTag
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Invalid Bun release version.'
    }
    $asset = "bun-windows-$platform.zip"

    $release = Get-RemoteText -Uri "https://api.github.com/repos/oven-sh/bun/releases/tags/bun-v$version" | ConvertFrom-Json
    $assets = @($release.assets | Where-Object { $_.name -ceq $asset })
    if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Expected one Bun release asset with a published SHA-256 digest.'
    }
    $url = [string]$assets[0].browser_download_url
    if (-not $url.StartsWith('https://github.com/oven-sh/bun/releases/download/', [StringComparison]::Ordinal)) {
        throw 'Unexpected Bun release URL.'
    }
    $expectedDigest = $assets[0].digest.Substring(7)
    $versionsDir = Join-Path $bunRoot 'versions'
    $versionDir = Join-Path $versionsDir $version
    $versionExe = Join-Path $versionDir 'bun.exe'

    if ($Force -or -not (Test-CliPackageProof $versionDir 'bun' $version $expectedDigest)) {
        if (Test-Path -LiteralPath $versionDir) {
            $versionDir += '-' + [guid]::NewGuid().ToString('N')
            $versionExe = Join-Path $versionDir 'bun.exe'
        }
        Assert-CliPackageDirectory $versionDir
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("bun-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $zip = Join-Path $tempRoot $asset
            Write-Info "Bun: downloading $version ($platform)"
            Invoke-Download -Uri $url -OutFile $zip

            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedDigest) {
                throw 'Bun release SHA-256 mismatch.'
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entries = @($archive.Entries | Where-Object { $_.FullName -ceq "bun-windows-$platform/bun.exe" })
                if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or
                    $entries[0].Length -gt 1073741824 -or
                    (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw 'Expected exactly one regular bun.exe entry.'
                }
                New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
                $pending = Join-Path $versionDir ('.bun-' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $pending)
                    [IO.File]::Move($pending, $versionExe)
                    Write-CliPackageProof $versionDir $version $expectedDigest 'bun'
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

    New-Item -ItemType Directory -Force -Path $bunBin | Out-Null
    Set-CurrentExe -SourceExe $versionExe -TargetExe $bunExe -ExpectedVersion $version

    $verified = Get-ExeVersion -ExePath $bunExe
    if (-not (Test-VersionEqual $verified $version)) {
        throw "Bun verification failed: $bunExe reports '$verified' but '$version' was expected."
    }

    Write-Info "Bun: $verified installed to $bunBin"
    if ($RemoveWinget) { Uninstall-BunWinget }

}

function Get-BunLatestVersion {
    $release = Get-RemoteText -Uri 'https://api.github.com/repos/oven-sh/bun/releases/latest' | ConvertFrom-Json
    $version = ConvertTo-NormalizedVersion ($release.tag_name -replace '^bun-', '')
    if ($release.draft -or $release.prerelease -or -not (Test-StableVersionAtLeast $version $version)) {
        throw 'Bun did not return a valid stable release.'
    }
    return $version
}
# ---------------------------------------------------------------------------
# winget (optional CLI cleanup)
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Uninstalls selected user-scope WinGet copies of OpenCode, Codex and Crush.
#>
function Remove-WingetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Ids)

    if (-not $Ids) { return }
    $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        Write-Warn 'winget is not available; nothing will be uninstalled.'
        return
    }

    foreach ($id in $Ids) {
        if (-not $PSCmdlet.ShouldProcess($id, 'Uninstall the winget copy')) { continue }
        $PSNativeCommandUseErrorActionPreference = $false
        & $winget.Source uninstall --id $id --exact --source winget --scope user --silent --disable-interactivity --accept-source-agreements | Out-Null
        if ($LASTEXITCODE -eq -1978335212) { continue }
        if ($LASTEXITCODE -ne 0) { throw "WinGet could not uninstall the user package $id (exit code $LASTEXITCODE)." }
        Write-Info "WinGet: $id uninstalled"
    }
}

# ---------------------------------------------------------------------------
function Get-SelectedCli {
    if ($Target -and $Agent) { throw 'Use either positional agents or -Target.' }
    $names = @(if ($Target) { $Target } else { $Agent })
    if (-not $names -or ($names.Count -eq 1 -and $names[0] -eq 'all')) { return $script:StableAgents }

    $selected = foreach ($name in $names) {
        if ($name -notin ($script:StableAgents + 'bun')) { throw "Unknown agent or invalid selection: $name" }
        $name.ToLowerInvariant()
    }
    return ($selected | Select-Object -Unique)
}

function Get-FreshCliVersion {
    param([string]$Name, [string]$ExpectedPath)

    # A usable binary can still be shadowed in a new session. Verify command
    # resolution against the registry-backed PATH with profiles disabled.
    # Construct the literal command only from the updater's fixed names.
    if ($Name -notin @('opencode', 'codex', 'crush', 'copilot', 'claude', 'swival', 'uv', 'bun')) { throw 'Invalid command name.' }
    $program = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' }
    $shell = Join-Path $PSHOME $program
    $code = @'
$ErrorActionPreference = 'Stop'
try {
    $command = Get-Command '__NAME__' -CommandType Application, ExternalScript
    if ($command.Path -ine '__PATH__') { exit 1 }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    & $command.Path --version
    if (-not $? -or $global:LASTEXITCODE -ne 0) { exit 1 }
    exit 0
}
catch { exit 1 }
'@
    $code = $code.Replace('__NAME__', $Name).Replace('__PATH__', $ExpectedPath.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $savedPath = $env:Path
    try {
        $env:Path = Get-PersistentCliPath
        $persistentCommand = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue
        if (-not $persistentCommand -or $persistentCommand.Path -ine $ExpectedPath -or
            -not (Test-PrivateCliPath $persistentCommand.Path)) {
            $persistentPath = if ($persistentCommand) { $persistentCommand.Path } else { 'missing' }
            throw "Persistent PATH resolves '$Name' to '$persistentPath'; expected '$ExpectedPath'."
        }
        $output = Invoke-CliVersionProbe $shell "-NoProfile -NonInteractive -EncodedCommand $encoded"
        return (ConvertFrom-VersionOutput $output)
    }
    finally { $env:Path = $savedPath }
}

function Get-ReportedVersion {
    param($Snapshot)
    if ($Snapshot.Version) { return $Snapshot.Version }
    if ($Snapshot.Found) { return 'unknown' }
    return 'none'
}

function Get-SelectedRelease {
    param([string]$Name)

    switch ($Name) {
        'opencode' { Get-OpenCodeLatestVersion }
        'codex' { Get-CodexLatestVersion }
        'crush' { Get-CrushLatestVersion }
        'copilot-cli' { Get-CopilotLatestVersion }
        'claude' { Get-ClaudeLatestVersion }
        'swival' { Get-SwivalLatestVersion }
        'bun' { Get-BunLatestVersion }
    }
}

function Invoke-SelectedInstall {
    param([string]$Name, [string]$Version)

    switch ($Name) {
        'opencode' { Install-OpenCode -Version $Version }
        'codex' { Install-Codex -Version $Version }
        'crush' { Install-Crush -Version $Version }
        'copilot-cli' { Install-CopilotCli -Version $Version }
        'claude' { Install-ClaudeCode -Version $Version }
        'swival' { Install-Swival -Version $Version }
        'bun' { Install-Bun -Version $Version }
    }
}

function Invoke-CliUpdate {
    param([string]$Name, [hashtable]$Cli, [string]$Pin, [switch]$Explicit)

    $command = $Cli.Command
    $managed = $Cli.Executable
    $row = [pscustomobject]@{ Agent = $Name; Before = 'unknown'; Latest = 'unknown'; After = 'unknown'; Result = 'failed' }
    if ($Name -eq 'swival' -and -not (Test-SwivalPlatform)) {
        Write-Warn 'Swival requires Windows x64 for its current dependency wheels. Native ARM64 and x86 installs are unavailable.'
        if (-not $Explicit) { $row.Result = 'unsupported' }
        return $row
    }
    try {
        $initial = Get-CliSnapshot -Name $command -ManagedPath $managed
        if (-not $initial.ActivePath) {
            $persistent = Get-CliSnapshot -Name $command -ManagedPath $managed -Persistent
            if ($persistent.ActivePath) { $initial = $persistent }
        }
        $row.Before = Get-ReportedVersion $initial
        $row.After = $row.Before
        $row.Latest = Get-SelectedRelease $Name
        if ($initial.Unsafe) { throw "Refusing to execute a CLI from a shared location: $($initial.ActivePath)" }
        $wanted = if ($Pin) { $Pin } else { $row.Latest }
        $current = if ($Pin) { Test-VersionEqual $initial.Version $wanted } else { Test-StableVersionAtLeast $initial.Version $wanted }
        if ($Check) {
            if ($initial.Found -and -not $initial.Version) { throw 'The existing installation did not report a usable version.' }
            $row.Result = if (-not $current) { 'available' }
            elseif (-not (Test-VersionEqual $initial.Version $wanted)) { 'newer' }
            else { 'current' }
            return $row
        }

        # A version probe alone cannot establish whether Codex's sandbox
        # resources are present. Retain its existing managed-cache checks.
        $checkCodexLayout = $Name -eq 'codex' -and $initial.Path -eq $managed -and (Test-VersionEqual $initial.Version $wanted)
        $refreshSwival = $Name -eq 'swival' -and $current -and $initial.Path -eq $managed
        $swivalUv = $null
        $swivalExistingUv = $null
        $installed = -not $current -or $Force
        $migrateWinget = $RemoveWinget -and ($Cli.WingetId -or $Name -eq 'bun')
        if ($initial.Conflict -and -not $migrateWinget) {
            throw 'Resolve the multiple installation paths before updating this agent.'
        }
        if ($installed -and $initial.ActivePath -and $initial.ActivePath -ine $managed -and -not $migrateWinget) {
            throw "Update the existing installation through its original installer: $($initial.ActivePath)"
        }
        if ($Name -eq 'swival' -and ($installed -or $refreshSwival)) { $swivalExistingUv = Get-SwivalUvLocation }
        if ($installed -or $checkCodexLayout) {
            if (-not (Test-PrivateCliPath (Split-Path -Parent $managed) -Directory)) {
                throw "Refusing to install under a shared or invalid destination: $managed"
            }
            if ($Name -eq 'swival') { $swivalUv = Invoke-SelectedInstall $Name $wanted }
            else { Invoke-SelectedInstall $Name $wanted }
        }
        elseif ($refreshSwival) { $swivalUv = Initialize-SwivalPython }

        if ($managed -and (($current -and $initial.Path -eq $managed) -or $installed -or $checkCodexLayout)) {
            $wrapper = if ($Wrappers) { $Cli.DefaultArgument } else { '' }
            Repair-CliEnvironment -Name $command -ExePath $managed -DefaultArgument $wrapper
            if ($RemoveWinget -and $Cli.WingetId -and (Get-ExeVersion $managed)) {
                Remove-WingetPackage -Ids @($Cli.WingetId)
            }
            if ($RemoveWinget -and $Name -eq 'bun' -and -not $installed) { Uninstall-BunWinget }
        }

        # Import entries available to a new session. Preserve process-specific
        # entries so a collision in the calling session is still detected.
        $env:Path = (@(($env:Path + ';' + (Get-PersistentCliPath)).Split(';')) |
                Where-Object { $_ } | Select-Object -Unique) -join ';'
        if ($swivalUv) { Enable-SwivalUv $swivalUv $swivalExistingUv }

        $after = Get-CliSnapshot -Name $command -ManagedPath $managed
        $row.After = Get-ReportedVersion $after
        $expected = if ($installed) { $wanted } else { $initial.Version }
        if (-not (Test-VersionEqual $after.ActiveVersion $expected) -or
            ($managed -and ($installed -or $checkCodexLayout) -and $after.ActivePath -ine $managed)) {
            throw "Current PATH resolves to '$($after.ActivePath)' with version '$($after.ActiveVersion)'; expected $expected."
        }
        $freshVersion = Get-FreshCliVersion $command $after.ActivePath
        if (-not (Test-VersionEqual $freshVersion $expected)) {
            throw "A fresh shell with persistent PATH resolves '$command' to '$freshVersion'; expected $expected."
        }

        if ($Name -eq 'codex' -and $UpdateCodexDaemon) {
            if ($after.ActivePath -ne $script:CodexExe) { throw 'Daemon updates require the managed Codex installation.' }
            Invoke-CodexDaemonUpdate
        }
        $row.Result = if ($installed -and -not $initial.Found) { 'installed' }
        elseif ($installed) { 'updated' }
        elseif (-not (Test-VersionEqual $expected $wanted)) { 'newer' }
        else { 'current' }
    }
    catch {
        Write-Fail "${Name}: $($_.Exception.Message)"
        if (-not $Check) {
            try {
                $actual = Get-CliSnapshot -Name $command -ManagedPath $managed
                $row.After = Get-ReportedVersion $actual
            }
            catch { Write-Warn "${Name}: could not read the final version: $($_.Exception.Message)" }
        }
    }
    return $row
}

# Validate arguments before acquiring locks or invoking installers.
if ($Agent -and $Agent.Count -eq 1 -and $Agent[0] -eq '--help' -and -not $Target) {
    Write-Output @'
Usage: update-ai-clis [all | AGENT ...] [--help]
Agents: opencode codex crush copilot-cli claude swival
Use no agents or all for all supported agents.
Windows: -Check reads versions only; -Target is the legacy selector.
Windows also accepts bun as an explicit target, pinned -OpenCodeVersion,
-CodexVersion and -CrushVersion, -Force, -RemoveWinget, -Wrappers, and
-UpdateCodexDaemon. Exit codes: 0 success, 1 operation failed, 2 invalid usage.
'@
    exit 0
}

try {
    $selected = @(Get-SelectedCli)
    $pins = @{ opencode = $OpenCodeVersion; codex = $CodexVersion; crush = $CrushVersion }
    foreach ($name in @($pins.Keys)) {
        $pin = $pins[$name]
        if (-not $pin) { continue }
        $normalized = ConvertTo-NormalizedVersion $pin
        if (-not $normalized -or $name -notin $selected -or ($name -eq 'opencode' -and $normalized -notmatch '^2\.')) {
            throw "Invalid pinned version or unselected agent: $name"
        }
        $pins[$name] = $normalized
    }
    if ($UpdateCodexDaemon -and 'codex' -notin $selected) { throw '-UpdateCodexDaemon requires selecting codex.' }
}
catch {
    Write-Fail $_.Exception.Message
    exit 2
}

$bunExe = $null
if ('bun' -in $selected) {
    $bunRoot = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $env:USERPROFILE '.bun' }
    $bunExe = Join-Path $bunRoot 'bin/bun.exe'
}
$commands = @{
    'opencode'    = @{ Command = 'opencode'; Executable = $script:OpenCodeExe; WingetId = 'SST.opencode'; DefaultArgument = '--auto' }
    'codex'       = @{ Command = 'codex'; Executable = $script:CodexExe; WingetId = 'OpenAI.Codex'; DefaultArgument = '--yolo' }
    'crush'       = @{ Command = 'crush'; Executable = $script:CrushExe; WingetId = 'charmbracelet.crush'; DefaultArgument = '' }
    'copilot-cli' = @{ Command = 'copilot'; Executable = $script:CopilotExe; WingetId = ''; DefaultArgument = '' }
    'claude'      = @{ Command = 'claude'; Executable = $script:ClaudeExe; WingetId = ''; DefaultArgument = '' }
    'swival'      = @{ Command = 'swival'; Executable = $script:SwivalExe; WingetId = ''; DefaultArgument = '' }
    'bun'         = @{ Command = 'bun'; Executable = $bunExe; WingetId = ''; DefaultArgument = '' }
}

$lock = $null
$ownsLock = $false
try {
    if (-not $Check) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try { $lockName = 'Global\Scripts.UpdateAiClis.' + $identity.User.Value }
        finally { $identity.Dispose() }
        $lock = [Threading.Mutex]::new($false, $lockName)
        try { $ownsLock = $lock.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsLock = $true }
        if (-not $ownsLock) { throw 'Another update-ai-clis process is running for this user.' }
    }

    $requested = if ($Target) { $Target } else { $Agent }
    $explicit = [bool]$requested -and $requested -notcontains 'all'
    $rows = foreach ($name in $selected) {
        Invoke-CliUpdate -Name $name -Cli $commands[$name] -Pin $pins[$name] -Explicit:$explicit
    }
    Write-Info 'AGENT | BEFORE | LATEST STABLE | AFTER | RESULT'
    foreach ($row in $rows) {
        Write-Info "$($row.Agent) | $($row.Before) | $($row.Latest) | $($row.After) | $($row.Result)"
    }
    if ($script:PathChanged) { Write-Info 'User PATH changes will be available in new sessions.' }
    if (@($rows | Where-Object Result -EQ 'failed').Count) { exit 1 }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    if ($ownsLock) { $lock.ReleaseMutex() }
    if ($lock) { $lock.Dispose() }
}
exit 0
