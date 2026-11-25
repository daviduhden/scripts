#requires -Version 7.0
# See the LICENSE file at the top of the project tree for copyright
# and license details.
# Offline updater regressions; fixture executables are text and never executed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture variables are read by functions loaded from the updater AST.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test doubles and fixture creation operate only on temporary paths.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../update-ai-clis.ps1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Updater syntax errors' }
# Extract definitions without evaluating the script entry point. The tests
# supply temporary destinations and substitute download and version probes.
foreach ($line in $source.Split("`n")) {
    if ($line -match '^\$script:(SemVer|StableAgents)') { . ([scriptblock]::Create($line)) }
}
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('aiclis-tests-' + [guid]::NewGuid().ToString('N'))
$Check = $false
$Force = $false
$RemoveWinget = $false
$Wrappers = $false
$script:Downloads = 0
$script:FailCleanup = $false
$script:FailCodexProbe = $false
$script:RealCodexActivation = (Get-Item Function:Set-CodexVisibleBin).ScriptBlock
$script:CodexVersions = Join-Path $testRoot 'codex/versions'
$script:CodexBin = Join-Path $testRoot 'codex/bin'
$script:CodexExe = Join-Path $script:CodexBin 'codex.exe'
$script:OpenCodeRoot = Join-Path $testRoot 'opencode'
$script:OpenCodeBin = Join-Path $script:OpenCodeRoot 'bin'
$script:OpenCodeExe = Join-Path $script:OpenCodeBin 'opencode.exe'
$script:CrushVersions = Join-Path $testRoot 'crush/versions'
$script:CrushBin = Join-Path $testRoot 'crush/bin'
$script:CrushExe = Join-Path $script:CrushBin 'crush.exe'
$script:CopilotBin = Join-Path $testRoot 'copilot/bin'
$script:CopilotExe = Join-Path $script:CopilotBin 'copilot.exe'
$script:ClaudeBin = Join-Path $testRoot 'claude/bin'
$script:ClaudeExe = Join-Path $script:ClaudeBin 'claude.exe'
$script:ClaudeSource = 'https://downloads.claude.ai/claude-code-releases'
$script:SwivalRoot = Join-Path $testRoot 'swival'
$script:SwivalBin = Join-Path $script:SwivalRoot 'bin'
$script:SwivalExe = Join-Path $script:SwivalBin 'swival.exe'
$script:ClaudePublisherValid = $true
$script:FixtureAssets = @()
$script:CodexFixtureActive = $null

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
        browser_download_url = "https://github.com/$Repository/releases/download/v1.2.3/$Name"
    }
}

function Get-CodexTar {
    if ($IsWindows) { return (Join-Path $env:SystemRoot 'System32/tar.exe') }
    return (Get-Command tar -CommandType Application | Select-Object -First 1).Path
}

function New-CodexFixture {
    param([string]$Target, [switch]$Duplicate)

    $root = Join-Path $testRoot ('package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'bin'), (Join-Path $root 'codex-path'),
    (Join-Path $root 'codex-resources') | Out-Null
    foreach ($relative in @('bin/codex.exe', 'bin/codex-code-mode-host.exe', 'bin/codex-exec-server.exe', 'codex-path/rg.exe',
            'codex-resources/codex-command-runner.exe', 'codex-resources/codex-windows-sandbox-setup.exe')) {
        Set-Content -LiteralPath (Join-Path $root $relative) -Value "fixture: $relative" -NoNewline
    }
    @{
        layoutVersion = 1
        version       = '1.2.3'
        target        = $Target
        variant       = 'codex'
        entrypoint    = 'bin/codex.exe'
        execServer    = 'bin/codex-exec-server.exe'
        resourcesDir  = 'codex-resources'
        pathDir       = 'codex-path'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'codex-package.json')
    $name = "codex-package-$Target.tar.gz"
    $path = Join-Path $testRoot $name
    $members = @('codex-package.json', 'bin', 'codex-path', 'codex-resources')
    if ($Duplicate) { $members += 'bin' }
    & (Get-CodexTar) -czf $path -C $root @members
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the Codex fixture.' }
    $script:FixtureAssets = @($script:FixtureAssets | Where-Object name -NE $name) + @{
        name                 = $name
        digest               = 'sha256:' + (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        browser_download_url = "https://github.com/openai/codex/releases/download/rust-v1.2.3/$name"
    }
}

function Get-RemoteText {
    param([string]$Uri, [hashtable]$Headers)
    if ($Uri -eq "$script:ClaudeSource/stable") { return '1.2.3' }
    if ($Uri -eq "$script:ClaudeSource/1.2.3/manifest.json") { return $script:ClaudeManifest }
    if ($Uri -eq 'https://pypi.org/pypi/swival/json') { return $script:SwivalIndex }
    if ($Uri -eq 'https://pypi.org/pypi/swival/1.2.3/json') { return $script:SwivalManifest }
    if ($Uri -eq 'https://api.github.com/repos/astral-sh/uv/releases/latest') {
        return (@{ tag_name = '1.2.3'; draft = $false; prerelease = $false; assets = @($script:UvFixtureAsset) } | ConvertTo-Json -Depth 5)
    }
    return (@{ tag_name = 'bun-v1.2.3'; draft = $false; prerelease = $false; assets = $script:FixtureAssets } | ConvertTo-Json -Depth 5)
}

function Test-ClaudeSignature {
    param([string]$Path)
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and $script:ClaudePublisherValid)
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    $script:Downloads++
    Copy-Item -LiteralPath (Join-Path $testRoot ($Uri.Split('/')[-1])) -Destination $OutFile
}

$script:RealExeVersion = (Get-Item Function:Get-ExeVersion).ScriptBlock
function Get-ExeVersion {
    param([string]$ExePath)
    if ($script:FailCodexProbe -and $ExePath -eq $script:CodexExe) { return '0.0.0' }
    if (Test-Path -LiteralPath $ExePath) { return '1.2.3' }
    return $null
}

function Set-CodexVisibleBin {
    param([string]$VersionDir, [string]$ExpectedVersion)
    # Activation is isolated from junction handling; no fixture is executable.
    $script:CodexExe = Join-Path $VersionDir 'bin/codex.exe'
    $script:CodexFixtureActive = $VersionDir
    Assert-True ($ExpectedVersion -eq '1.2.3') 'Activation was not given the expected version'
}

function Get-CodexActivePackage { return $script:CodexFixtureActive }

function Remove-Item {
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, [string]$ErrorAction)
    if ($script:FailCleanup -and $LiteralPath -like '*.old-*') { throw 'Simulated running executable' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    Assert-True ((ConvertFrom-VersionOutput @('informational banner', '1.2.3 (Claude Code)')) -eq '1.2.3') 'Multiline version parsing failed'
    Assert-True ((ConvertFrom-VersionOutput @('GitHub Copilot CLI 1.2.3.')) -eq '1.2.3') 'Copilot version with trailing punctuation was not parsed'
    Assert-True (-not (ConvertFrom-VersionOutput @('release 1.2.3.4', 'release 01.2.3'))) 'Invalid versions were parsed'
    Assert-True (Test-VersionEqual 'rust-v1.2.3+abc' '1.2.3+def') 'Build metadata changed precedence'
    Assert-True (-not (Test-VersionEqual '1.2.3-rc.1' '1.2.3')) 'Prerelease compared equal to stable'
    Assert-True (-not (Test-StableVersionAtLeast '1.2.3-rc.10' '1.2.3')) 'Same-core prerelease satisfied stable requirement'
    Assert-True (Test-StableVersionAtLeast '2.0.0-rc.10' '1.2.3') 'Higher-version prerelease would be downgraded'
    Assert-True (Test-StableVersionAtLeast '1.10.0' '1.9.0') 'Numeric version ordering failed'

    $wrapper = Join-Path $testRoot 'probe script.ps1'
    Set-Content -LiteralPath $wrapper -Value "'wrapper banner'; '1.2.3 (Claude Code)'"
    $global:LASTEXITCODE = 9
    Assert-True ((& $script:RealExeVersion $wrapper) -eq '1.2.3') 'PowerShell wrapper inherited stale native exit code'
    Set-Content -LiteralPath $wrapper -Value "'1.2.3 (Claude Code)'; exit 7"
    Assert-True (-not (& $script:RealExeVersion $wrapper)) 'Failed wrapper accepted by version probe'
    Set-Content -LiteralPath $wrapper -Value "'1.2.3'; 'x' * 33000"
    Assert-True (-not (& $script:RealExeVersion $wrapper)) 'Oversized version output was accepted'

    $triple = Get-CodexTarget
    New-CodexFixture $triple
    $openAsset = if ((Get-PlatformTag) -eq 'x64') { 'opencode-windows-x64-baseline.zip' } else { 'opencode-windows-arm64.zip' }
    New-ArchiveFixture $openAsset @('opencode.exe') 'anomalyco/opencode'
    $crushAsset = "crush_1.2.3_Windows_$(Get-CrushTarget).zip"
    New-ArchiveFixture $crushAsset @("$($crushAsset.Replace('.zip', ''))/crush.exe") 'charmbracelet/crush'
    $copilotAsset = "copilot-win32-$(Get-PlatformTag).zip"
    New-ArchiveFixture $copilotAsset @('copilot.exe') 'github/copilot-cli'
    $claudeFixture = Join-Path $testRoot 'claude.exe'
    Set-Content -LiteralPath $claudeFixture -Value 'Claude fixture'
    $script:ClaudeManifest = @{
        version   = '1.2.3'
        platforms = @{
            "win32-$(Get-PlatformTag)" = @{
                binary   = 'claude.exe'
                size     = (Get-Item -LiteralPath $claudeFixture).Length
                checksum = (Get-FileHash -LiteralPath $claudeFixture).Hash.ToLowerInvariant()
            }
        }
    } | ConvertTo-Json -Depth 4

    Install-OpenCode '1.2.3'
    Install-Codex '1.2.3'
    Install-Crush '1.2.3'
    Install-CopilotCli '1.2.3'
    Assert-True (Test-Path $script:CopilotExe) 'Copilot did not install from its standalone archive'
    Install-ClaudeCode (Get-ClaudeLatestVersion)
    Assert-True (Test-Path $script:ClaudeExe) 'Claude did not install from the signed binary'
    $script:ClaudePublisherValid = $false
    $failed = $false
    try { Install-ClaudeCode '1.2.3' } catch { $failed = $_.Exception.Message -like '*Authenticode signature*' }
    Assert-True $failed 'Claude installer accepted the wrong signature'
    $script:ClaudePublisherValid = $true
    Add-Content -LiteralPath $claudeFixture -Value 'corruption'
    $failed = $false
    try { Install-ClaudeCode '1.2.3' } catch { $failed = $_.Exception.Message -like '*SHA-256 mismatch*' }
    Assert-True $failed 'Claude installer accepted a corrupt executable'
    New-ArchiveFixture $copilotAsset @('nested/copilot.exe') 'github/copilot-cli'
    $failed = $false
    try { Install-CopilotCli '1.2.3' } catch { $failed = $_.Exception.Message -like '*exactly one regular copilot.exe*' }
    Assert-True $failed 'Non-root Copilot archive entry was accepted'
    Assert-True (Test-Path $script:CrushExe) 'Crush did not install after OpenCode and Codex'
    $resourceName = 'codex-resources/codex-command-runner.exe'
    $resource = Join-Path $script:CodexFixtureActive $resourceName
    Assert-True ((Get-Content -Raw $resource) -eq "fixture: $resourceName") 'Canonical package resources were not installed'
    Assert-True (Test-Path (Join-Path $script:CodexFixtureActive 'codex-path/rg.exe')) 'Bundled Codex ripgrep was not installed'
    $beforeDownloads = $script:Downloads
    Install-Codex '1.2.3'
    Assert-True ($script:Downloads -eq $beforeDownloads) 'Complete package downloaded again'
    $receipt = Join-Path $script:CodexFixtureActive '.release-proof.json'
    Assert-True (Test-Path -LiteralPath $receipt) 'Verified package did not record a release receipt'
    Add-Content -LiteralPath $resource -Value 'changed'
    Assert-True (-not (Test-CliPackageProof $script:CodexFixtureActive 'codex')) 'Modified cached artifact passed verification'
    Remove-Item -LiteralPath $resource
    Install-Codex '1.2.3'
    $resource = Join-Path $script:CodexFixtureActive $resourceName
    Assert-True ($script:Downloads -gt $beforeDownloads -and (Test-Path $resource)) 'Partial package not repaired'

    $Force = $true
    $beforeCodex = $script:CodexFixtureActive
    New-CodexFixture $triple -Duplicate
    $failed = $false
    try { Install-Codex '1.2.3' } catch { $failed = $_.Exception.Message -like '*duplicate Codex archive member*' }
    Assert-True ($failed -and $script:CodexFixtureActive -eq $beforeCodex) 'Duplicate archive path was accepted'

    if ($IsWindows) {
        & {
            $first = Join-Path $testRoot 'first PATH entry'
            $second = Join-Path $testRoot 'second PATH entry'
            New-Item -ItemType Directory -Path $first, $second | Out-Null
            $expected = Join-Path $first 'aicli-probe.cmd'
            [IO.File]::WriteAllText($expected, "@echo off`r`necho GitHub Copilot CLI 1.2.3`r`n")
            [IO.File]::WriteAllText((Join-Path $second 'aicli-probe.cmd'), "@echo off`r`necho 1.0.0`r`n")
            Set-Item Function:local:Get-ExeVersion $script:RealExeVersion
            $savedPath = $env:Path
            try {
                $env:Path = "$first;$second;$savedPath"
                $snapshotOutput = @(Get-CliSnapshot -Name 'aicli-probe' 6>&1)
                $snapshot = $snapshotOutput[-1]
                Assert-True ($snapshot.ActiveVersion -eq '1.2.3' -and $snapshot.ActivePath -eq $expected) 'The effective cmd wrapper was not resolved'
                Assert-True ([bool]($snapshotOutput -like '*multiple installation directories*')) 'Duplicate PATH directories were not reported'
            }
            finally { $env:Path = $savedPath }
        }

        $sourceDir = Join-Path $testRoot 'junction-candidate'
        $destination = Join-Path $testRoot 'junction-existing'
        New-Item -ItemType Directory -Path (Join-Path $sourceDir 'bin'), $destination | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceDir 'bin/codex.exe') -Value 'candidate'
        Set-Content -LiteralPath (Join-Path $destination 'codex.exe') -Value 'previous'
        $savedBin = $script:CodexBin
        $savedExe = $script:CodexExe
        try {
            $script:CodexBin = $destination
            $script:CodexExe = Join-Path $destination 'codex.exe'
            $script:FailCodexProbe = $true
            $failed = $false
            try { & $script:RealCodexActivation -VersionDir $sourceDir -ExpectedVersion '1.2.3' } catch { $failed = $true }
            Assert-True ($failed -and (Get-Content -Raw $script:CodexExe).Trim() -eq 'previous') 'Codex activation did not restore the preceding directory'
            $script:FailCodexProbe = $false
            & $script:RealCodexActivation -VersionDir $sourceDir -ExpectedVersion '1.2.3'
            Assert-True ((Get-Content -Raw $script:CodexExe).Trim() -eq 'candidate') 'Codex junction activation failed'
        }
        finally {
            $script:FailCodexProbe = $false
            $script:CodexBin = $savedBin
            $script:CodexExe = $savedExe
        }
    }

    $script:FailCleanup = $true
    Set-CurrentExe -SourceExe (Join-Path $script:OpenCodeRoot 'versions/1.2.3/opencode.exe') -TargetExe $script:CrushExe
    Assert-True ((Get-Content -Raw $script:CrushExe) -eq 'fixture: opencode.exe') 'Activation failed on old-copy cleanup'
    $script:FailCleanup = $false
    if ($IsWindows) {
        $lock = [IO.File]::Open($script:CrushExe, 'Open', 'Read', 'None')
        try {
            $failed = $false
            try { Set-CurrentExe -SourceExe $resource -TargetExe $script:CrushExe } catch { $failed = $true }
            Assert-True $failed 'Locked executable was overwritten'
        }
        finally { $lock.Dispose() }
        Assert-True ((Get-Content -Raw $script:CrushExe) -eq 'fixture: opencode.exe') 'Locked target changed'
    }

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
    & {
        $Agent = @()
        $Target = @()
        Assert-True (((Get-SelectedCli) -join ',') -eq 'opencode,codex,crush,copilot-cli,claude,swival') 'Wrong default agents'
        $Agent = @('all')
        Assert-True (@(Get-SelectedCli).Count -eq 6) 'Explicit all differs from default'
        $Agent = @('codex', 'Claude', 'codex')
        Assert-True (((Get-SelectedCli) -join ',') -eq 'codex,claude') 'Multi-agent selection was not deduplicated'
        $Agent = @('all', 'claude')
        $failed = $false
        try { Get-SelectedCli } catch { $failed = $true }
        Assert-True $failed 'Mixed all/agent was accepted'
        $Agent = @('crush', '--unknown-flag')
        $failed = $false
        try { Get-SelectedCli } catch { $failed = $true }
        Assert-True $failed 'Invalid argument was accepted'
    }

    # Exercise the shared dispatch with temporary state and isolated commands.
    & {
        $Force = $false
        $script:DispatchVersion = $null
        $script:DispatchInstallCalls = 0
        $script:DispatchRepairCalls = 0
        $script:DispatchFailure = ''
        $script:DispatchPath = $null
        $managed = Join-Path $testRoot 'dispatch/copilot.exe'
        $cli = @{ Command = 'copilot'; Executable = $managed; DefaultArgument = ''; WingetId = '' }
        function Get-CliSnapshot {
            param([string]$Name, [string]$ManagedPath, [switch]$Persistent)
            $effective = if ($script:DispatchFailure -eq 'shadowed') { '1.1.0' } else { $script:DispatchVersion }
            return [pscustomobject]@{
                Found         = [bool]$effective
                Path          = if ($effective) { $ManagedPath }
                Version       = $effective
                ActivePath    = $script:DispatchPath
                ActiveVersion = if ($script:DispatchPath) { $effective }
                Unsafe        = $false
                Conflict      = $script:DispatchFailure -eq 'duplicate'
            }
        }
        function Get-SelectedRelease {
            param([string]$Name)
            if ($script:DispatchFailure -eq 'offline') { throw 'Fixture network failure' }
            Assert-True ($Name -eq 'copilot-cli') 'Looked up an unrelated agent'
            return '1.2.3'
        }
        function Invoke-SelectedInstall {
            param([string]$Name, [string]$Version)
            Assert-True ($Name -eq 'copilot-cli') 'Changed an unrelated agent'
            $script:DispatchInstallCalls++
            if ($script:DispatchFailure -eq 'permissions') { throw 'Fixture permission failure' }
            $script:DispatchVersion = $Version
        }
        function Repair-CliEnvironment {
            param([string]$Name, [string]$ExePath, [string]$DefaultArgument)
            Assert-True ($Name -eq 'copilot') 'Repaired unrelated PATH'
            $script:DispatchRepairCalls++
            $script:DispatchPath = $ExePath
        }
        function Get-FreshCliVersion {
            if ($script:DispatchFailure -eq 'persistent') { return '1.0.0' }
            return $script:DispatchVersion
        }
        function Get-PersistentCliPath { return $env:Path }

        $row = Invoke-CliUpdate 'copilot-cli' $cli
        Assert-True ($row.Result -eq 'installed' -and $row.Before -eq 'none' -and $row.After -eq '1.2.3') 'Fresh install status is incorrect'
        $script:DispatchPath = $null
        $row = Invoke-CliUpdate 'copilot-cli' $cli
        Assert-True ($row.Result -eq 'current' -and $script:DispatchInstallCalls -eq 1 -and
            $script:DispatchRepairCalls -eq 2) 'Current installation was reinstalled instead of restoring PATH'
        $script:DispatchVersion = '1.1.0'
        $row = Invoke-CliUpdate 'copilot-cli' $cli
        Assert-True ($row.Result -eq 'updated' -and $row.Before -eq '1.1.0' -and $row.Latest -eq '1.2.3') 'Upgrade versions were not distinguished'
        $script:DispatchVersion = '1.2.3-rc.1'
        $row = Invoke-CliUpdate 'copilot-cli' $cli
        Assert-True ($row.Result -eq 'updated' -and $row.After -eq '1.2.3') 'Prerelease was not replaced by stable'

        $Check = $true
        $script:DispatchVersion = '1.1.0'
        $before = $script:DispatchInstallCalls
        $row = Invoke-CliUpdate 'copilot-cli' $cli
        Assert-True ($row.Result -eq 'available' -and $row.Before -eq $row.After -and
            $script:DispatchInstallCalls -eq $before) 'Check mode installed an update'
        $Check = $false

        foreach ($scenario in 'offline', 'permissions', 'shadowed', 'persistent', 'duplicate') {
            $script:DispatchFailure = $scenario
            $script:DispatchVersion = '1.1.0'
            $row = Invoke-CliUpdate 'copilot-cli' $cli
            Assert-True ($row.Result -eq 'failed') "Failure was hidden: $scenario"
        }
    }

    & {
        $asset = 'uv-x86_64-pc-windows-msvc.zip'
        New-ArchiveFixture $asset @('uv.exe', 'uvx.exe') 'astral-sh/uv'
        $script:UvFixtureAsset = $script:FixtureAssets | Where-Object name -EQ $asset | Select-Object -First 1
        $script:UvFixtureAsset.browser_download_url = "https://github.com/astral-sh/uv/releases/download/1.2.3/$asset"
        $wheel = @{
            filename    = 'swival-1.2.3-py3-none-any.whl'
            packagetype = 'bdist_wheel'
            yanked      = $false
            url         = 'https://files.pythonhosted.org/packages/aa/bb/swival-1.2.3-py3-none-any.whl'
            digests     = @{ sha256 = 'a' * 64 }
        }
        $other = $wheel.Clone()
        $other.yanked = $true
        $other.filename = 'swival-2.0.0-py3-none-any.whl'
        $other.url = $wheel.url.Replace('1.2.3', '2.0.0')
        $script:SwivalIndex = @{
            info     = @{ name = 'swival' }
            releases = @{ '1.2.3' = @($wheel); '2.0.0' = @($other); '3.0.0rc1' = @($wheel) }
        } | ConvertTo-Json -Depth 7
        $script:SwivalManifest = @{ info = @{ name = 'swival'; version = '1.2.3' }; urls = @($wheel) } | ConvertTo-Json -Depth 7
        Assert-True ((Get-SwivalLatestVersion) -eq '1.2.3') 'Swival selected a yanked or preview release'
        $invalid = $wheel.Clone()
        $invalid.url = $wheel.url.Replace('files.pythonhosted.org', 'example.invalid')
        Assert-True (-not (Find-SwivalWheel @($invalid) '1.2.3')) 'Swival accepted an unrelated wheel source'

        $oldIndex = $env:UV_INDEX
        $oldMirror = $env:UV_PYTHON_INSTALL_MIRROR
        try {
            $env:UV_INDEX = 'https://example.invalid'
            $env:UV_PYTHON_INSTALL_MIRROR = 'https://example.invalid'
            $probe = Get-SwivalUvStartInfo 'uv.exe' $testRoot @('python', 'list')
            Assert-True ($probe.Arguments -match '--no-config' -and -not $probe.EnvironmentVariables.ContainsKey('UV_INDEX') -and
                -not $probe.EnvironmentVariables.ContainsKey('UV_PYTHON_INSTALL_MIRROR') -and $probe.EnvironmentVariables['UV_PYTHON_NO_REGISTRY'] -eq '1') 'Ambient uv options escaped isolation'
        }
        finally {
            $env:UV_INDEX = $oldIndex
            $env:UV_PYTHON_INSTALL_MIRROR = $oldMirror
        }

        $script:SwivalUvCalls = @()
        $script:SwivalFixtureFail = $false
        $fixturePython = Join-Path $script:SwivalRoot 'python/python.exe'
        $ordinaryProbe = (Get-Item Function:Get-ExeVersion).ScriptBlock
        function Get-ExeVersion {
            param([string]$ExePath)
            if ($ExePath -eq $fixturePython -and (Test-Path -LiteralPath $ExePath)) { return '3.14.3' }
            return (& $ordinaryProbe $ExePath)
        }
        function Invoke-SwivalUv {
            param([string]$Uv, [string]$Directory, [string[]]$UvArgs, [switch]$Output)
            Assert-True ((Get-Content -Raw -LiteralPath $Uv) -eq 'fixture: uv.exe') 'Installer did not select verified uv fixture'
            $script:SwivalUvCalls += "$($UvArgs[0]) $($UvArgs[1])"
            if ($UvArgs[0] -eq 'python') {
                if ($Output) {
                    Assert-True (($UvArgs -join ' ') -eq 'python find 3.14 --managed-python') 'Wrong managed Python probe'
                    return $fixturePython
                }
                Assert-True (($UvArgs -join ' ') -eq 'python install 3.14 --upgrade --no-bin --no-registry') 'Wrong Swival Python policy'
                [IO.File]::WriteAllText($fixturePython, 'fixture Python')
                return
            }
            Assert-True (($UvArgs -join ' ') -match '--managed-python --python 3\.14 --default-index https://pypi\.org/simple --only-binary :all:' -and
                $UvArgs[-1] -eq "swival @ $($wheel.url)#sha256=$($wheel.digests.sha256)") 'Wrong Swival distribution constraints'
            if ($script:SwivalFixtureFail) { throw 'fixture uv failure' }
            $bin = Join-Path $Directory 'bin'
            $null = New-Item -ItemType Directory -Path $bin
            [IO.File]::WriteAllText((Join-Path $bin 'swival.exe'), 'fixture swival')
        }

        $uv = Install-Swival '1.2.3'
        Assert-True ((Get-Content -Raw -LiteralPath $script:SwivalExe) -eq 'fixture swival' -and
            ($script:SwivalUvCalls -join ',') -eq 'python install,python find,tool install') 'Swival install did not activate the isolated tool'
        $downloads = $script:Downloads
        Assert-True ((Get-SwivalUv) -eq $uv -and $script:Downloads -eq $downloads) 'Verified uv was downloaded again'
        $script:SwivalFixtureFail = $true
        $failed = $false
        try { $null = Install-Swival '1.2.3' } catch { $failed = $_.Exception.Message -eq 'fixture uv failure' }
        Assert-True ($failed -and (Get-Content -Raw -LiteralPath $script:SwivalExe) -eq 'fixture swival') 'Swival runtime failure replaced the working launcher'
        function Get-FreshCliVersion {
            param([string]$Name, [string]$ExpectedPath)
            Assert-True ($Name -eq 'uv') 'Verified an unrelated dependency on PATH'
            return (Get-ExeVersion $ExpectedPath)
        }
        Enable-SwivalUv $uv
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $script:SwivalBin 'uv.exe')) -eq 'fixture: uv.exe') 'The verified uv launcher was not published'
        function Get-CliSnapshot { return [pscustomobject]@{ Unsafe = $false; Conflict = $true; ActivePath = $null } }
        $failed = $false
        try { $null = Get-SwivalUvLocation } catch { $failed = $_.Exception.Message -like '*conflicting or unsafe uv*' }
        Assert-True $failed 'Conflicting uv installations were not reported'
        function Test-SwivalPlatform { return $false }
        $cli = @{ Command = 'swival'; Executable = $script:SwivalExe }
        Assert-True ((Invoke-CliUpdate 'swival' $cli).Result -eq 'unsupported') 'Automatic run failed on unsupported Swival architecture'
        Assert-True ((Invoke-CliUpdate 'swival' $cli -Explicit).Result -eq 'failed') 'Explicit unsupported Swival request succeeded'
    }

    $cleanupDefinition = (Get-Item Function:Uninstall-BunWinget).ScriptBlock
    function Uninstall-BunWinget { $script:BunCleanupCalls++ }
    $script:BunCleanupCalls = 0
    $savedBunInstall = $env:BUN_INSTALL
    try {
        $env:BUN_INSTALL = Join-Path $testRoot 'bun'
        $Force = $true
        $RemoveWinget = $true
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
    finally { $env:BUN_INSTALL = $savedBunInstall; $RemoveWinget = $false }
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
    Write-Output 'PASS: offline AI CLI package, activation, daemon, version and dispatch regressions'
}
finally {
    $script:FailCleanup = $false
    # This absolute GUID directory is created by this test, under GetTempPath.
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
