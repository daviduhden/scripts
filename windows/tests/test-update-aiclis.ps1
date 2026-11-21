#requires -Version 7.0
# See the LICENSE file at the top of the project tree for copyright
# and license details.
# Offline updater regressions; fixture executables are text and never executed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../update-aiclis.ps1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Updater syntax errors' }
# Load definitions only: never run the updater against real user directories.
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('aiclis-tests-' + [guid]::NewGuid().ToString('N'))
$Check = $false
$Force = $false
$script:Downloads = 0
$script:FailCleanup = $false
$script:CodexVersions = Join-Path $testRoot 'codex/versions'
$script:CodexBin = Join-Path $testRoot 'codex/bin'
$script:CodexExe = Join-Path $script:CodexBin 'codex.exe'
$script:OpenCodeRoot = Join-Path $testRoot 'opencode'
$script:OpenCodeBin = Join-Path $script:OpenCodeRoot 'bin'
$script:OpenCodeExe = Join-Path $script:OpenCodeBin 'opencode.exe'
$script:CrushVersions = Join-Path $testRoot 'crush/versions'
$script:CrushBin = Join-Path $testRoot 'crush/bin'
$script:CrushExe = Join-Path $script:CrushBin 'crush.exe'
$script:FixtureAssets = @()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-ArchiveFixture {
    param([string]$Name, [string[]]$Entries, [string]$Repository)
    $path = Join-Path $testRoot $Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $Entries) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($entry).Open())
            try { $writer.Write("fixture: $entry") } finally { $writer.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    $script:FixtureAssets = @($script:FixtureAssets | Where-Object name -NE $Name) + @{
        name                 = $Name
        digest               = 'sha256:' + (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        browser_download_url = "https://github.com/$Repository/releases/download/v1/$Name"
    }
}

function Get-RemoteText {
    param([string]$Uri, [hashtable]$Headers)
    return (@{ tag_name = 'bun-v1.2.3'; assets = $script:FixtureAssets } | ConvertTo-Json -Depth 5)
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    $script:Downloads++
    Copy-Item -LiteralPath (Join-Path $testRoot ($Uri.Split('/')[-1])) -Destination $OutFile
}

function Get-ExeVersion {
    param([string]$ExePath)
    if (Test-Path -LiteralPath $ExePath) { return '1.2.3' }
    return $null
}

function Set-CodexVisibleBin {
    param([string]$VersionDir, [string]$ExpectedVersion)
    # Activation is isolated from junction handling; no fixture is executable.
    $script:CodexExe = Join-Path $VersionDir 'bin/codex.exe'
    Assert-True ($ExpectedVersion -eq '1.2.3') 'Activation was not given the expected version'
}

function Test-CodexManagedLayout { return $true }

function Remove-Item {
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, [string]$ErrorAction)
    if ($script:FailCleanup -and $LiteralPath -like '*.old-*') { throw 'Simulated running executable' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $triple = Get-CodexTarget
    $codexAsset = "codex-$triple.exe.zip"
    $legacy = @("codex-$triple.exe", 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe')
    $resources = @('codex-resources/codex-command-runner.exe', 'codex-resources/codex-windows-sandbox-setup.exe')
    New-ArchiveFixture $codexAsset ($legacy + $resources) 'openai/codex'
    New-ArchiveFixture "codex-code-mode-host-$triple.exe.zip" @("codex-code-mode-host-$triple.exe") 'openai/codex'
    $openAsset = "opencode-windows-$(Get-PlatformTag).zip"
    New-ArchiveFixture $openAsset @('opencode.exe') 'anomalyco/opencode'
    $crushAsset = "crush_1.2.3_Windows_$(Get-CrushTarget).zip"
    New-ArchiveFixture $crushAsset @("$($crushAsset.Replace('.zip', ''))/crush.exe") 'charmbracelet/crush'

    Install-OpenCode '1.2.3'
    Install-Codex '1.2.3'
    Install-Crush '1.2.3'
    Assert-True (Test-Path $script:CrushExe) 'Crush did not install after OpenCode and Codex'
    $resource = Join-Path $script:CodexVersions '1.2.3/codex-resources/codex-command-runner.exe'
    Assert-True ((Get-Content -Raw $resource) -eq "fixture: $($resources[0])") 'Resource path was not preferred'
    $beforeDownloads = $script:Downloads
    Install-Codex '1.2.3'
    Assert-True ($script:Downloads -eq $beforeDownloads) 'Complete package downloaded again'
    Remove-Item -LiteralPath $resource
    Install-Codex '1.2.3'
    Assert-True ($script:Downloads -gt $beforeDownloads -and (Test-Path $resource)) 'Partial package not repaired'

    $Force = $true
    New-ArchiveFixture $codexAsset $legacy 'openai/codex'
    Install-Codex '1.2.3'
    Assert-True ((Get-Content -Raw $resource) -eq 'fixture: codex-command-runner.exe') 'Legacy package refused'
    New-ArchiveFixture $codexAsset ($legacy + $resources + $resources[0]) 'openai/codex'
    $failed = $false
    try { Install-Codex '1.2.3' } catch { $failed = $_.Exception.Message -like '*exactly one regular*' }
    Assert-True $failed 'Duplicate exact resource path accepted'

    $script:FailCleanup = $true
    Set-CurrentExe -SourceExe (Join-Path $script:OpenCodeRoot 'versions/1.2.3/opencode.exe') -TargetExe $script:CrushExe
    Assert-True ((Get-Content -Raw $script:CrushExe) -eq 'fixture: opencode.exe') 'Activation failed on old-copy cleanup'
    $script:FailCleanup = $false
    $lock = [IO.File]::Open($script:CrushExe, 'Open', 'Read', 'None')
    try {
        $failed = $false
        try { Set-CurrentExe -SourceExe $resource -TargetExe $script:CrushExe } catch { $failed = $true }
        Assert-True $failed 'Locked executable was overwritten'
    }
    finally { $lock.Dispose() }
    Assert-True ((Get-Content -Raw $script:CrushExe) -eq 'fixture: opencode.exe') 'Locked target changed'

    $Check = $true
    $beforeDownloads = $script:Downloads
    Install-OpenCode '1.2.3'
    Install-Codex '1.2.3'
    Install-Crush '1.2.3'
    Assert-True ($script:Downloads -eq $beforeDownloads) 'Check mode downloaded a CLI'
    $Check = $false

    function Invoke-TestDaemon {
        Assert-True (($args -join ' ') -eq 'app-server daemon update') 'Wrong daemon command'
        $script:DaemonCalls++
        $global:LASTEXITCODE = $script:DaemonExit
        return (@{ status = $script:DaemonStatus; installedVersion = '1.2.3'; runningVersion = $null } | ConvertTo-Json)
    }
    $script:CodexExe = 'Invoke-TestDaemon'
    $script:DaemonCalls = 0
    $script:DaemonExit = 0
    $script:DaemonStatus = 'updated'
    Invoke-CodexDaemonUpdate
    $script:DaemonStatus = 'noUpdate'
    Invoke-CodexDaemonUpdate
    $Check = $true
    Invoke-CodexDaemonUpdate
    Assert-True ($script:DaemonCalls -eq 2) 'Check mode invoked daemon update'
    $Check = $false
    foreach ($case in @(@{ Exit = 7; Status = 'updated' }, @{ Exit = 0; Status = 'unsupported' })) {
        $script:DaemonExit = $case.Exit
        $script:DaemonStatus = $case.Status
        $failed = $false
        try { Invoke-CodexDaemonUpdate } catch { $failed = $true }
        Assert-True $failed 'Daemon failure was not propagated'
    }
    # Exercise the real main dispatch with isolated installers. In particular,
    # OpenCode or daemon failures must not prevent the later Crush attempt.
    $mainOffset = $source.IndexOf('Write-Info "update-aiclis: local target')
    Assert-True ($mainOffset -gt 0) 'Main entry point not found'
    $main = $source.Substring($mainOffset).Replace('if ($script:HadError) { exit 1 }', @'
$script:Calls -join ','
if ($script:HadError) { exit 1 }
exit 0
'@)
    $harness = Join-Path $testRoot 'dispatch.ps1'
    $prefix = @'
param([string]$Fixture, [switch]$Fail, [string]$Target = 'All', [switch]$RemoveWinget, [switch]$Check)
$Wrappers = $false
$OpenCodeVersion = $CodexVersion = $CrushVersion = ''
$script:Calls = @()
$script:PathChanged = $false
$script:HadError = $false
$script:OpenCodeExe = $script:CrushExe = $script:CodexExe = $Fixture
function Install-Bun { $script:Calls += 'Bun' }
function Install-OpenCode { $script:Calls += 'OpenCode'; if ($Fail) { throw 'OpenCode fixture failure' } }
function Install-Codex { $script:Calls += 'Codex' }
function Install-Crush { $script:Calls += 'Crush' }
function Invoke-CodexDaemonUpdate { $script:Calls += 'Daemon'; if ($Fail) { throw 'Daemon fixture failure' } }
function Repair-CliEnvironment { }
function Find-BunExe { return $null }
function Remove-WingetPackages { param([string[]]$Ids) $script:Calls += $Ids }
'@
    [IO.File]::WriteAllText($harness, $prefix + "`n" + $main)
    $dispatch = & $harness -Fixture $resource -Fail
    Assert-True ($LASTEXITCODE -eq 1) 'Dispatch did not return failure'
    Assert-True ($dispatch -eq 'Bun,OpenCode,Codex,Daemon,Crush') 'Failure prevented a later tool update'
    $dispatch = & $harness -Fixture $resource
    Assert-True ($LASTEXITCODE -eq 0) 'Successful dispatch returned failure'
    Assert-True ($dispatch -eq 'Bun,OpenCode,Codex,Daemon,Crush') 'Daemon was skipped after current CLI'
    $dispatch = & $harness -Fixture $resource -Fail -RemoveWinget
    Assert-True ($dispatch -eq 'Bun,OpenCode,Codex,Daemon,Crush,OpenAI.Codex,charmbracelet.crush') 'Winget removal included a failed install'
    $dispatch = & $harness -Fixture $resource -Target Crush -RemoveWinget
    Assert-True ($dispatch -eq 'Crush,charmbracelet.crush') 'Winget removal included unselected targets'
    $dispatch = & $harness -Fixture $resource -Target Crush -RemoveWinget -Check
    Assert-True ($dispatch -eq 'Crush') 'Check mode removed a winget package'
    $cleanupDefinition = (Get-Item Function:Uninstall-BunWinget).ScriptBlock
    function Uninstall-BunWinget { $script:BunCleanupCalls++ }
    $script:BunCleanupCalls = 0
    $savedBunInstall = $env:BUN_INSTALL
    try {
        $env:BUN_INSTALL = Join-Path $testRoot 'bun'
        $Force = $true
        $bunAsset = "bun-windows-$(Get-PlatformTag).zip"
        $bunEntry = "bun-windows-$(Get-PlatformTag)/bun.exe"
        New-ArchiveFixture $bunAsset @($bunEntry) 'oven-sh/bun'
        Install-Bun
        Assert-True ((Find-BunExe) -eq (Join-Path $env:BUN_INSTALL 'bin/bun.exe')) 'Managed Bun not preferred'
        $beforeDownloads = $script:Downloads
        $Force = $false
        Install-Bun
        Assert-True ($script:Downloads -eq $beforeDownloads) 'Current Bun downloaded again'
        $Check = $true
        $Force = $true
        Install-Bun
        Assert-True ($script:Downloads -eq $beforeDownloads) 'Bun check downloaded an archive'
        Assert-True ($script:BunCleanupCalls -eq 2) 'Bun cleanup skipped or invoked in check mode'
        $Check = $false
        New-ArchiveFixture $bunAsset @($bunEntry, $bunEntry) 'oven-sh/bun'
        $failed = $false
        try { Install-Bun } catch { $failed = $_.Exception.Message -like '*exactly one regular*' }
        Assert-True $failed 'Duplicate Bun binary accepted'
        New-ArchiveFixture $bunAsset @($bunEntry) 'oven-sh/bun'
        Add-Content -LiteralPath (Join-Path $testRoot $bunAsset) -Value 'corruption'
        $failed = $false
        try { Install-Bun } catch { $failed = $_.Exception.Message -like '*SHA-256 mismatch*' }
        Assert-True $failed 'Corrupt Bun archive accepted'
    }
    finally { $env:BUN_INSTALL = $savedBunInstall }
    Set-Item Function:Uninstall-BunWinget $cleanupDefinition
    $script:WingetCalls = @()
    $script:WingetListExit = 0
    $script:WingetUninstallExit = 0
    function Invoke-FakeWinget {
        $script:WingetCalls += $args[0]
        $global:LASTEXITCODE = if ($args[0] -eq 'list') { $script:WingetListExit } else { $script:WingetUninstallExit }
    }
    function Get-Command { return [pscustomobject]@{ Source = 'Invoke-FakeWinget' } }
    $Check = $false
    Uninstall-BunWinget
    Assert-True (($script:WingetCalls -join ',') -eq 'list,uninstall') 'Winget Bun was not removed'
    $script:WingetCalls = @()
    $script:WingetListExit = -1978335212
    Uninstall-BunWinget
    Assert-True (($script:WingetCalls -join ',') -eq 'list') 'Absent winget Bun was uninstalled'
    $Check = $true
    Uninstall-BunWinget
    Assert-True ($script:WingetCalls.Count -eq 1) 'Check mode invoked winget'
    $Check = $false
    $script:WingetListExit = 0
    $script:WingetUninstallExit = 9
    $failed = $false
    try { Uninstall-BunWinget } catch { $failed = $true }
    Assert-True $failed 'Winget uninstall failure was hidden'
    Write-Host 'PASS: offline AI CLI package, activation, daemon and dispatch regressions'
}
finally {
    $script:FailCleanup = $false
    # This absolute GUID directory is created by this test, under GetTempPath.
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
