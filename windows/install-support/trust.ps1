# Windows installer path and interpreter trust checks.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param(
    [ValidateSet('Library', 'Version', 'FindPerl', 'Winget', 'ValidatePath', 'Stage', 'AddPath')]
    [string]$Action = 'Library',
    [string]$Path
)
$ErrorActionPreference = 'Stop'

function Get-InstallPathAcl {
    param([string]$ItemPath, [bool]$Directory)

    # The batch installer may start Windows PowerShell from pwsh, whose
    # inherited module search path differs. Use the engine's filesystem API.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if ($Directory) { return [IO.Directory]::GetAccessControl($ItemPath) }
        return [IO.File]::GetAccessControl($ItemPath)
    }
    if ($Directory) { return [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($ItemPath)) }
    return [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($ItemPath))
}

function Assert-InstallPath {
    param([string]$Candidate, [switch]$Directory)
    if ($Candidate -notmatch '^[A-Za-z]:[\\/]' -or $Candidate.Substring(2) -match '[:;%!^"'']') {
        throw 'Install paths must be absolute local filesystem paths representable by CMD.'
    }
    $full = [IO.Path]::GetFullPath($Candidate)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $trusted = @(
            $identity.User.Value
            'S-1-5-18'
            'S-1-5-32-544'
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        )
    }
    finally { $identity.Dispose() }
    $replace = [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
    $write = $replace -bor [Security.AccessControl.FileSystemRights]::Write
    $required = $write
    $current = $full
    $expectDirectory = [bool]$Directory
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            if ([bool]$item.PSIsContainer -ne $expectDirectory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unexpected file type or reparse point: $current"
            }
            $acl = Get-InstallPathAcl $current $expectDirectory
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
                throw "Untrusted filesystem owner: $current"
            }
            $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
            foreach ($rule in $rules) {
                if ($rule.AccessControlType -ne 'Allow' -or -not ($rule.FileSystemRights -band $required) -or
                    ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
                # Creator Owner inheritance is resolved to the actual owner.
                if ($rule.IdentityReference.Value -notin $trusted -and $rule.IdentityReference.Value -ne 'S-1-3-0') {
                    throw "Filesystem path can be changed by another identity: $current"
                }
            }
            # For ancestors, replacement rights matter. Permission to create a
            # new sibling does not itself let another identity change the target.
            $required = $replace
        }
        $expectDirectory = $true
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Get-TrustedPerl {
    $processDirectories = @($env:Path -split ';')
    $registryDirectories = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') +
    @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
    $candidates = foreach ($directory in ($processDirectories + $registryDirectories)) {
        $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))
        if ($directory -match '^[A-Za-z]:[\\/]') { Join-Path $directory 'perl.exe' }
    }
    $candidates += "$env:SystemDrive\Strawberry\perl\bin\perl.exe"
    $candidates += Join-Path $env:ProgramFiles 'Strawberry\perl\bin\perl.exe'
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Strawberry\perl\bin\perl.exe'
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not [IO.File]::Exists($candidate)) { continue }
        try { Assert-InstallPath $candidate }
        catch { [Console]::Error.WriteLine("Ignoring Perl outside a trusted path: $candidate") }
    }
}

function Initialize-InstallStage {
    $root = Assert-InstallPath ([IO.Path]::GetTempPath().TrimEnd('\')) -Directory
    $name = Join-Path $root ('scripts-install-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $name) { throw 'Staging name is already in use.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User, 'FullControl',
                'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        $directory = [IO.DirectoryInfo]::new($name)
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $directory.Create($acl) }
        else { [IO.FileSystemAclExtensions]::Create($directory, $acl) }
    }
    finally { $identity.Dispose() }
    return (Assert-InstallPath $name -Directory)
}

switch ($Action) {
    'Version' { [Environment]::OSVersion.Version.ToString() }
    'FindPerl' { Get-TrustedPerl }
    'Winget' {
        # Resolve the executable through the Microsoft package registration.
        # An arbitrary App Execution Alias is not a trusted executable path.
        Import-Module (Join-Path $PSHOME 'Modules\Appx\Appx.psd1')
        $registered = Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
            Where-Object { $_.PublisherId -ceq '8wekyb3d8bbwe' } | Select-Object -First 1
        if ($registered -and $registered.InstallLocation) {
            $executable = Join-Path $registered.InstallLocation 'winget.exe'
            if ([IO.File]::Exists($executable)) { Assert-InstallPath $executable }
        }
    }
    'ValidatePath' { $null = Assert-InstallPath $Path -Directory }
    'Stage' { Initialize-InstallStage }
    'AddPath' {
        $bin = Assert-InstallPath $Path -Directory
        if (-not [IO.Directory]::Exists($bin)) { throw 'The installed bin directory is missing.' }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            $raw = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = if ($null -eq $raw) { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { $key.GetValueKind('Path') }
            if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                throw 'User PATH must be a registry string.'
            }
            $entries = @(([string]$raw).Split(';') | Where-Object { $_.Trim() })
            $matching = @($entries | Where-Object {
                    [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\') -ieq $bin.TrimEnd('\')
                })
            if ($matching.Count) { Write-Information 'User PATH already contains the installation.' -InformationAction Continue }
            else {
                $key.SetValue('Path', (($entries + $bin) -join ';'), $kind)
                Write-Information "Added to user PATH: $bin" -InformationAction Continue
            }
        }
        finally { $key.Dispose() }
    }
}
