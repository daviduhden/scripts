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
$originalCopilot = $env:COPILOT_HOME
$originalClaude = $env:CLAUDE_CONFIG_DIR
$originalOs = $env:OS
$originalCrush = $env:CRUSH_GLOBAL_CONFIG
$originalUrl = $env:XERJ_URL
$updater = Join-Path $PSScriptRoot '../update-xerj.ps1'
$global:xerjTestBadDigest = $false
$global:xerjTestDuplicate = $false
$global:xerjTestCodexCalls = 0
$global:xerjTestLatestCalls = 0
$global:xerjTestLegacyResponse = $false
$global:xerjTestReleaseUri = 'https://github.com/xerj-org/xerj/releases/tag/v1.2.3'
$global:xerjTestBanner = 'xerj v1.2.3'
$global:xerjTestOpenCodeVersion = '1.2.3'
$global:xerjTestCrushVersion = '0.88.0'
$global:xerjTestMissing = @()
$global:xerjTestCodexEntry = $null
$global:xerjTestLegacyJson = $false

function Invoke-RestMethod {
    throw 'GitHub API must not be used (simulated API rate limit).'
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function codex {
    if ($args[1] -eq 'get') {
        if ($global:xerjTestCodexEntry) {
            $global:LASTEXITCODE = 0
            Write-Error 'Synthetic Codex stderr warning' -ErrorAction Continue
            return ($global:xerjTestCodexEntry | ConvertTo-Json -Depth 5)
        }
        $global:LASTEXITCODE = 1
        return "Error: No MCP server named 'xerj' found."
    }
    $global:xerjTestCodexCalls++
    Assert-True ($args[0] -eq 'mcp' -and $args[1] -eq 'add' -and $args[2] -eq 'xerj') 'Unexpected Codex invocation'
    $global:xerjTestCodexEntry = @{
        name      = 'xerj'
        enabled   = $true
        transport = @{ type = 'stdio'; command = $args[4]; args = $args[5..7]; env = $null; env_vars = @(); cwd = $null }
    }
    $global:LASTEXITCODE = 0
}

function opencode {
    Assert-True ($args[0] -eq '--version') 'Unexpected OpenCode invocation'
    $global:LASTEXITCODE = 0
    return $global:xerjTestOpenCodeVersion
}

function crush {
    Assert-True ($args[0] -eq '--version') 'Unexpected Crush invocation'
    $global:LASTEXITCODE = 0
    return @('fixture logo', "crush version v$global:xerjTestCrushVersion")
}

$swivalFixture = Join-Path $testRoot 'swival.ps1'
$swivalProbe = @'
if ($args[0] -ne '--list-profiles' -or $args[1] -ne '--base-dir' -or
    -not [IO.Directory]::Exists($args[2])) { exit 2 }
$text = [IO.File]::ReadAllText((Join-Path $env:XDG_CONFIG_HOME 'swival/config.toml'))
if ($text.Contains('INVALID_TOML') -or
    [regex]::Matches($text, '(?m)^\[mcp_servers\.xerj\]$').Count -gt 1) { exit 1 }
exit 0
'@

function Get-Command {
    param([string]$Name, $CommandType, $ErrorAction)
    if ($Name -in $global:xerjTestMissing) { return $null }
    if ($Name -in @('copilot', 'claude')) { return 'must-not-execute-fixture-client' }
    if ($Name -eq 'swival') { return [pscustomobject]@{ Source = $swivalFixture } }
    if ($Name -in @('codex', 'opencode', 'crush')) {
        return (Microsoft.PowerShell.Core\Get-Command $Name -CommandType Function)
    }
    if ($Name -eq 'ConvertFrom-Json' -and $global:xerjTestLegacyJson) {
        return [pscustomobject]@{ Parameters = @{} }
    }
    return (Microsoft.PowerShell.Core\Get-Command $Name)
}

function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [string]$Method, [int]$TimeoutSec)
    Assert-True ($TimeoutSec -gt 0) 'Release request must have a timeout'
    if ($Uri -eq 'https://github.com/xerj-org/xerj/releases/latest') {
        Assert-True ($Method -eq 'Head') 'Latest release lookup must use HEAD'
        $global:xerjTestLatestCalls++
        $baseResponse = if ($global:xerjTestLegacyResponse) {
            [pscustomobject]@{ ResponseUri = [uri]$global:xerjTestReleaseUri }
        }
        else { [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]$global:xerjTestReleaseUri } } }
        return [pscustomobject]@{ BaseResponse = $baseResponse }
    }
    Assert-True ($Uri.StartsWith('https://github.com/xerj-org/xerj/releases/download/v1.2.3/xerj-1.2.3-')) 'Unexpected download URL'
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
            if ($global:xerjTestDuplicate) { $null = $zip.CreateEntry("$directory/xerj.exe") }
        }
        finally { $zip.Dispose() }
    }
}

function Start-Process {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [switch]$PassThru,
        [switch]$NoNewWindow,
        [string]$WorkingDirectory,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    Assert-True ($ArgumentList -eq '--version' -and $PassThru -and $NoNewWindow) 'Unexpected staged executable probe'
    Assert-True ($WorkingDirectory -eq (Split-Path $RedirectStandardOutput)) 'Version probe must run from its temporary directory'
    Assert-True ([IO.Path]::GetFileName($FilePath) -cmatch '^\.xerj-[a-f0-9]{32}\.exe$') 'Version probe must target staged executable'
    Assert-True ([IO.File]::ReadAllText($FilePath) -eq 'fixture binary; never execute') 'Wrong staged binary content'
    if ($PSCmdlet.ShouldProcess($FilePath, 'Write the synthetic version output')) {
        [IO.File]::WriteAllText($RedirectStandardOutput, $global:xerjTestBanner)
        [IO.File]::WriteAllText($RedirectStandardError, '')
    }
    $process = [pscustomobject]@{ ExitCode = 0 }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        if ($args.Count -gt 0) { return $true }
    }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $process
}

try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'local'
    $env:XDG_CONFIG_HOME = Join-Path $testRoot "config with spaces and 'quote"
    $env:CODEX_HOME = Join-Path $testRoot 'codex'
    $env:COPILOT_HOME = Join-Path $testRoot 'copilot'
    $env:CLAUDE_CONFIG_DIR = Join-Path $testRoot 'claude'
    $env:OS = 'Windows_NT'
    $env:CRUSH_GLOBAL_CONFIG = $null
    $env:XERJ_URL = $null
    $null = New-Item -ItemType Directory -Force (Join-Path $env:XDG_CONFIG_HOME 'crush'), (Join-Path $env:XDG_CONFIG_HOME 'opencode'), $env:CODEX_HOME, $env:COPILOT_HOME, $env:CLAUDE_CONFIG_DIR
    [IO.File]::WriteAllText($swivalFixture, $swivalProbe)
    $crushConfig = Join-Path $env:XDG_CONFIG_HOME 'crush/crushrc'
    $openConfig = Join-Path $env:XDG_CONFIG_HOME 'opencode/opencode.json'
    $copilotConfig = Join-Path $env:COPILOT_HOME 'mcp-config.json'
    $claudeConfig = Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'
    Set-Content $crushConfig '# retained user configuration'
    Set-Content $openConfig '{"theme":"test","mcp":{"existing":{"type":"local","command":["example"]}}}'
    Set-Content (Join-Path $env:CODEX_HOME 'config.toml') '# retained Codex configuration'
    Set-Content $copilotConfig '{"mcpServers":{"other":{"type":"local","command":"keep","tools":["*"]}}}'
    Set-Content $claudeConfig '{"theme":"keep","mcpServers":{"other":{"type":"stdio","command":"keep","args":[]}}}'
    $oldBackup = "$openConfig.bak.previous"
    [IO.File]::WriteAllText($oldBackup, 'old backup data')
    & $updater -Version 'v1.2.3' -Codex -Crush -OpenCode
    Assert-True ($LASTEXITCODE -eq 0) 'First installation failed'
    $binary = Join-Path $env:LOCALAPPDATA 'Programs/xerj/xerj.exe'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Wrong binary content'
    & $updater -Version 'v1.2.3' -Crush -OpenCode -Url 'http://127.0.0.1:9300'
    Assert-True ($LASTEXITCODE -eq 0) 'Repeated update failed'
    & $updater -Version 'v1.2.3' -Codex
    Assert-True ($LASTEXITCODE -eq 0 -and $global:xerjTestCodexCalls -eq 1) 'Unchanged Codex registration was replaced'
    & $updater -Version 'v1.2.3' -Codex -Url 'http://127.0.0.1:9300'
    Assert-True ($LASTEXITCODE -eq 1 -and $global:xerjTestCodexCalls -eq 1) 'Existing Codex configuration was replaced on an endpoint change'
    $config = Get-Content -Raw $openConfig | ConvertFrom-Json
    Assert-True ($config.theme -eq 'test' -and $config.mcp.existing.command[0] -eq 'example') 'Other OpenCode settings lost'
    Assert-True ($config.mcp.xerj.command[3] -eq 'http://127.0.0.1:9300') 'Endpoint was not updated'
    Assert-True $config.mcp.xerj.enabled 'OpenCode v1 registration must be enabled'
    $crushText = Get-Content -Raw $crushConfig
    Assert-True ($crushText.Contains('# retained user configuration')) 'Crush settings lost'
    Assert-True ([regex]::Matches($crushText, '# BEGIN xerj managed').Count -eq 1) 'Duplicate managed blocks'
    Assert-True ($global:xerjTestCodexCalls -eq 1) 'Codex was not registered exactly once'
    Assert-True ($global:xerjTestLatestCalls -eq 0) 'Pinned version queried latest release'
    & $updater copilot-cli claude --version v1.2.3 --url 'http://127.0.0.1:9300'
    Assert-True ($LASTEXITCODE -eq 0) 'Selective Copilot and Claude setup failed'
    $copilot = Get-Content -Raw $copilotConfig | ConvertFrom-Json
    $claude = Get-Content -Raw $claudeConfig | ConvertFrom-Json
    Assert-True ($copilot.mcpServers.xerj.command -eq $binary -and $copilot.mcpServers.xerj.tools[0] -eq '*') 'Wrong Copilot registration'
    Assert-True ($claude.mcpServers.xerj.type -eq 'stdio' -and $claude.mcpServers.xerj.args[2] -eq 'http://127.0.0.1:9300') 'Wrong Claude registration'
    Assert-True ($claude.theme -eq 'keep' -and $claude.mcpServers.other.command -eq 'keep' -and $copilot.mcpServers.other.command -eq 'keep') 'Unrelated Copilot or Claude settings lost'
    Assert-True ($global:xerjTestCodexCalls -eq 1) 'Selective registration called Codex'
    $swivalConfig = Join-Path $env:XDG_CONFIG_HOME 'swival/config.toml'
    & $updater swival --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $swivalConfig)) 'Missing Swival config was not created'
    $swivalOriginal = @'
commands = "ask"
[profiles.local]
provider = "generic"
model = "keep"
base_url = "http://127.0.0.1:8080"
'@
    [IO.File]::WriteAllText($swivalConfig, $swivalOriginal)
    $claudeBefore = Get-Content -Raw $claudeConfig
    & $updater swival --version v1.2.3 --url http://127.0.0.1:9300
    $swivalPublished = Get-Content -Raw $swivalConfig
    Assert-True ($LASTEXITCODE -eq 0 -and $swivalPublished.StartsWith($swivalOriginal) -and
        $swivalPublished.Contains('[mcp_servers.xerj]') -and $swivalPublished.Contains('http://127.0.0.1:9300')) 'Swival registration failed'
    Assert-True ((Get-Content -Raw $claudeConfig) -ceq $claudeBefore) 'Swival selection changed Claude'
    & $updater -Swival --version v1.2.3 --url http://127.0.0.1:9300
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw $swivalConfig) -ceq $swivalPublished) 'Swival registration is not idempotent'
    & $updater swival --version v1.2.3 --url https://example.org
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw $swivalConfig).Contains('https://example.org')) 'Swival URL did not change'
    [IO.File]::WriteAllText($swivalConfig, 'INVALID_TOML')
    & $updater swival --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1 -and (Get-Content -Raw $swivalConfig) -ceq 'INVALID_TOML') 'Invalid Swival config was replaced'
    [IO.File]::WriteAllText($swivalConfig, $swivalOriginal)
    $global:xerjTestMissing = @('swival')
    & $updater -Swival --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1 -and (Get-Content -Raw $swivalConfig) -ceq $swivalOriginal) 'Missing Swival was configured'
    $global:xerjTestMissing = @()
    $binaryOnlyBefore = Get-Content -Raw $claudeConfig
    & $updater --binary-only --version v1.2.3 --url 'http://127.0.0.1:9400'
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw $claudeConfig) -ceq $binaryOnlyBefore) 'Binary-only run touched configuration'
    $env:XERJ_URL = 'http://127.0.0.1:9700'
    & $updater claude --version v1.2.3
    $configuredClaude = Get-Content -Raw $claudeConfig | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $configuredClaude.mcpServers.xerj.args[2] -eq $env:XERJ_URL) 'XERJ_URL was ignored'
    $env:XERJ_URL = 'not an endpoint'
    & $updater -BinaryOnly --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 0) 'Binary-only run checked irrelevant XERJ_URL'
    $env:XERJ_URL = $null
    & $updater --binary-only claude
    Assert-True ($LASTEXITCODE -eq 2) 'Invalid binary-only combination was accepted'
    $unsafe = & $updater --url 'http://fixture:secret@example.org/' 6>&1
    Assert-True ($LASTEXITCODE -eq 2 -and (($unsafe -join '') -notmatch 'secret')) 'Credential-bearing URL was accepted or printed'
    $global:xerjTestMissing = @('claude')
    & $updater claude --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1) 'Missing selected client did not fail'
    & $updater
    Assert-True ($LASTEXITCODE -eq 0) 'Automatic version failed with API rate limit'
    $global:xerjTestLegacyResponse = $true
    & $updater
    Assert-True ($LASTEXITCODE -eq 0) 'Windows PowerShell response format rejected'
    Assert-True ($global:xerjTestLatestCalls -eq 2) 'Latest release was not resolved on both runs'
    $global:xerjTestMissing = @()
    & $updater all --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 0) 'Explicit all did not register available clients'
    $legacyConfig = '{"theme":"v2","mcp":{"timeout":12345,"xerj":{"type":"local","command":[],"enabled":false}}}' | ConvertFrom-Json
    $legacyConfig.mcp.xerj.command = @($binary, 'mcp', '--url', 'http://127.0.0.1:9200')
    $legacyConfig | ConvertTo-Json -Depth 8 | Set-Content $openConfig
    $global:xerjTestOpenCodeVersion = '2.2.0'
    & $updater opencode --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 0) 'Managed OpenCode entry did not migrate'
    $migrated = Get-Content -Raw $openConfig | ConvertFrom-Json
    Assert-True ($migrated.mcp.servers.xerj.disabled -and -not $migrated.mcp.PSObject.Properties['xerj']) 'Incorrect OpenCode 2 schema or lost disabled flag'
    Assert-True ($migrated.mcp.timeout -eq 12345) 'OpenCode 2 MCP options were lost'
    $unrelated = '{"mcpServers":{"xerj":{"type":"http","url":"http://other"}}}'
    [IO.File]::WriteAllText($claudeConfig, $unrelated)
    & $updater claude copilot-cli --version v1.2.3 --url http://127.0.0.1:9500
    Assert-True ($LASTEXITCODE -eq 1 -and (Get-Content -Raw $claudeConfig) -ceq $unrelated) 'Unrelated Claude server was overwritten'
    $configuredCopilot = Get-Content -Raw $copilotConfig | ConvertFrom-Json
    Assert-True ($configuredCopilot.mcpServers.xerj.args[2] -eq 'http://127.0.0.1:9500') 'Claude collision blocked unaffected Copilot registration'
    $env:CRUSH_GLOBAL_CONFIG = Join-Path $testRoot 'custom-crush'
    $customCrush = Join-Path $env:CRUSH_GLOBAL_CONFIG 'crushrc'
    $global:xerjTestCrushVersion = '0.87.0'
    & $updater crush --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1 -and -not (Test-Path -LiteralPath $customCrush)) 'An older explicitly selected Crush was configured'
    $global:xerjTestMissing = @('claude')
    $autoOutput = & $updater all --version v1.2.3 6>&1
    Assert-True ($LASTEXITCODE -eq 0 -and ($autoOutput -join "`n") -match 'Skipped crush\. Crush 0\.88\.0' -and
        -not (Test-Path -LiteralPath $customCrush)) 'Automatic registration did not skip legacy Crush'
    $global:xerjTestMissing = @()
    $global:xerjTestCrushVersion = '0.88.0'
    & $updater crush --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $customCrush)) 'Crush override was ignored'
    $modified = (Get-Content -Raw $customCrush).Replace("'http://127.0.0.1:9200'", "'http://127.0.0.1:9200'; echo 'keep'")
    [IO.File]::WriteAllText($customCrush, $modified)
    & $updater crush --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1 -and (Get-Content -Raw $customCrush) -ceq $modified) 'Customized Crush block was overwritten'
    Remove-Item -LiteralPath $customCrush
    $legacyCrush = Join-Path $env:CRUSH_GLOBAL_CONFIG 'crush.json'
    [IO.File]::WriteAllText($legacyCrush, '{"mcp":{"xerj":{"type":"stdio","command":"custom"}}}')
    & $updater crush --version v1.2.3
    Assert-True ($LASTEXITCODE -eq 1 -and -not (Test-Path -LiteralPath $customCrush)) 'Registration would shadow an unrelated legacy Crush server'
    $env:CRUSH_GLOBAL_CONFIG = $null
    foreach ($uri in @('https://example.com/xerj-org/xerj/releases/tag/v1.2.3',
            'https://github.com/xerj-org/xerj/releases/latest',
            'https://github.com/xerj-org/xerj/releases/tag/v1.2.3?unexpected=1')) {
        $global:xerjTestReleaseUri = $uri
        & $updater -ErrorAction SilentlyContinue
        Assert-True ($LASTEXITCODE -eq 1) 'Unexpected release redirect accepted'
        Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Binary changed after invalid release redirect'
    }
    $before = Get-Content -Raw $openConfig
    $global:xerjTestBadDigest = $true
    & $updater -Version 'v1.2.3' -OpenCode -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Bad checksum accepted'
    Assert-True ((Get-Content -Raw $openConfig) -eq $before) 'Configuration changed after checksum failure'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Binary changed after checksum failure'
    $global:xerjTestBadDigest = $false
    $global:xerjTestDuplicate = $true
    & $updater -Version 'v1.2.3' -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Duplicate executable entry accepted'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Binary changed after archive rejection'
    $global:xerjTestDuplicate = $false
    $global:xerjTestBanner = 'xerj v9.9.0'
    & $updater -Version 'v1.2.3' -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Mismatched staged version accepted'
    Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Binary changed after version mismatch'
    $global:xerjTestBanner = 'xerj v1.2.3'
    # Windows sharing semantics must be tested on Windows, not inferred from Unix.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        $locked = [IO.File]::Open($binary, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            & $updater -Version 'v1.2.3' -ErrorAction SilentlyContinue
            Assert-True ($LASTEXITCODE -eq 1) 'Locked destination update unexpectedly succeeded'
        }
        finally { $locked.Dispose() }
        Assert-True ((Get-Content -Raw $binary) -eq 'fixture binary; never execute') 'Locked original damaged'
    }
    else { Write-Output 'SKIP: Windows file-sharing failure test requires Windows' }
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $binary) -Filter '.xerj-*.exe' -Force).Count -eq 0) 'Abandoned binary staging files'
    foreach ($ambiguous in @('{ "theme": "one", "theme": "two" }', '{ /* comment */ "theme": "test" }')) {
        [IO.File]::WriteAllText($openConfig, $ambiguous)
        & $updater -Version 'v1.2.3' -OpenCode -ErrorAction SilentlyContinue
        Assert-True ($LASTEXITCODE -eq 1) 'Ambiguous OpenCode JSON was accepted'
        Assert-True ((Get-Content -Raw $openConfig) -eq $ambiguous) 'Ambiguous OpenCode JSON was rewritten'
    }
    [IO.File]::WriteAllText($openConfig, $before)
    Set-Content ([IO.Path]::ChangeExtension($openConfig, '.jsonc')) '// retain this file'
    & $updater -Version 'v1.2.3' -OpenCode -ErrorAction SilentlyContinue
    Assert-True ($LASTEXITCODE -eq 1) 'Ambiguous JSONC was accepted'
    Assert-True ((Get-Content -Raw $openConfig) -eq $before) 'JSON changed despite JSONC refusal'
    $dateConfig = '{"timestamp":"2025-01-01T23:00:00+03:00"}'
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        [IO.File]::WriteAllText($claudeConfig, $dateConfig)
        & $updater --version v1.2.3 claude
        $updated = Get-Content -Raw $claudeConfig | ConvertFrom-Json -DateKind String
        Assert-True ($LASTEXITCODE -eq 0 -and $updated.timestamp -ceq '2025-01-01T23:00:00+03:00') 'Unrelated JSON string was changed'
    }
    if (($dateConfig | ConvertFrom-Json).timestamp -is [datetime]) {
        [IO.File]::WriteAllText($claudeConfig, $dateConfig)
        $global:xerjTestLegacyJson = $true
        & $updater --version v1.2.3 claude
        $global:xerjTestLegacyJson = $false
        Assert-True ($LASTEXITCODE -eq 1 -and [IO.File]::ReadAllText($claudeConfig) -ceq $dateConfig) 'Legacy JSON coercion changed the original file'
    }
    $backups = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.bak.*')
    Assert-True ($backups.Count -eq 1 -and $backups[0].FullName -eq $oldBackup) 'Unexpected backup creation or removal'
    Assert-True ([IO.File]::ReadAllText($oldBackup) -eq 'old backup data') 'Existing backup was altered'
    Write-Output 'PASS: latest release without API, redirect validation, install, repeated update, preserved settings and existing backup, Codex registration, checksum and version rejection, JSONC refusal'
}
finally {
    $env:LOCALAPPDATA = $originalLocal
    $env:XDG_CONFIG_HOME = $originalConfig
    $env:CODEX_HOME = $originalCodex
    $env:COPILOT_HOME = $originalCopilot
    $env:CLAUDE_CONFIG_DIR = $originalClaude
    $env:OS = $originalOs
    $env:CRUSH_GLOBAL_CONFIG = $originalCrush
    $env:XERJ_URL = $originalUrl
    Remove-Variable -Name xerjTestBadDigest, xerjTestDuplicate, xerjTestCodexCalls -Scope Global
    Remove-Variable -Name xerjTestLatestCalls, xerjTestLegacyResponse, xerjTestReleaseUri, xerjTestBanner -Scope Global
    Remove-Variable -Name xerjTestOpenCodeVersion, xerjTestCrushVersion, xerjTestMissing, xerjTestCodexEntry -Scope Global
    Remove-Variable -Name xerjTestLegacyJson -Scope Global
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path $resolved) -eq $tempRoot -and (Split-Path $resolved -Leaf) -match '^xerj-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
