# Publish the batch installer's verified staging tree.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'

function Get-ManagedPath {
    param([string]$Entry)
    if ($Entry -match '^(?:perl-path\.txt|installed-files\.txt|VERSION|bin\\[\w.-]+\.cmd|perl\\[\w.-]+\.pl|windows\\[\w.-]+\.ps1)$') {
        return $Entry
    }
    throw "Invalid install manifest entry: $Entry"
}

function Assert-RegularItem {
    param([string]$Path, [switch]$Directory)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            [bool]$item.PSIsContainer -ne [bool]$Directory)) {
        throw "Refusing to replace an unexpected file type: $Path"
    }
}

$lock = $null
$transaction = $null
$changes = [Collections.Generic.List[object]]::new()
$preserveRecovery = $false
try {
    $Destination = [IO.Path]::GetFullPath($Destination)
    Assert-RegularItem -Path $Destination -Directory
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $lockPath = Join-Path $Destination '.scripts-install.lock'
    $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None,
        4096, [IO.FileOptions]::DeleteOnClose)

    $manifest = 'installed-files.txt'
    $manifestPath = Join-Path $Destination $manifest
    Assert-RegularItem -Path $manifestPath
    $fresh = @([IO.File]::ReadAllLines((Join-Path $Stage $manifest)) | ForEach-Object { Get-ManagedPath $_ })
    $old = if ([IO.File]::Exists($manifestPath)) {
        @([IO.File]::ReadAllLines($manifestPath) | ForEach-Object { Get-ManagedPath $_ })
    }
    else { @() }

    foreach ($folder in @('bin', 'perl', 'windows')) {
        $path = Join-Path $Destination $folder
        Assert-RegularItem -Path $path -Directory
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }

    $transaction = Join-Path $Destination ('.scripts-install-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($transaction) | Out-Null
    foreach ($entry in @($fresh | Where-Object { $_ -ne $manifest }) + @($manifest)) {
        $target = Join-Path $Destination $entry
        Assert-RegularItem -Path $target
        $pending = Join-Path $transaction "new-$($changes.Count)"
        [IO.File]::Copy((Join-Path $Stage $entry), $pending)
        $backup = $null
        if ([IO.File]::Exists($target)) {
            if ($entry -notin $old) { throw "Refusing to overwrite an unmanaged file: $target" }
            $backup = Join-Path $transaction "old-$($changes.Count)"
            [IO.File]::Replace($pending, $target, $backup)
        }
        else { [IO.File]::Move($pending, $target) }
        $changes.Add(@{ Target = $target; Backup = $backup })
    }
    foreach ($entry in $old) {
        if ($entry -in $fresh) { continue }
        $target = Join-Path $Destination $entry
        Assert-RegularItem -Path $target
        if (-not [IO.File]::Exists($target)) { continue }
        if ($entry -like 'bin\*' -and
            -not (Select-String -LiteralPath $target -Pattern 'perl-path.txt', 'rem scripts-powershell-launcher' -SimpleMatch -Quiet)) {
            continue
        }
        $backup = Join-Path $transaction "old-$($changes.Count)"
        [IO.File]::Move($target, $backup)
        $changes.Add(@{ Target = $target; Backup = $backup })
    }
}
catch {
    for ($index = $changes.Count - 1; $index -ge 0; $index--) {
        $change = $changes[$index]
        try {
            if (-not $change.Backup) { [IO.File]::Delete($change.Target) }
            elseif ([IO.File]::Exists($change.Target)) {
                [IO.File]::Replace($change.Backup, $change.Target, [NullString]::Value)
            }
            else { [IO.File]::Move($change.Backup, $change.Target) }
        }
        catch {
            $preserveRecovery = $true
            Write-Warning "Could not restore $($change.Target). Recovery files: $transaction"
        }
    }
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}
finally {
    if ($transaction -and -not $preserveRecovery) {
        Remove-Item -LiteralPath $transaction -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lock) { $lock.Dispose() }
}
