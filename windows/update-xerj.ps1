#!/usr/bin/env pwsh

# xerj installer and updater for Windows.
# - Installs a checksum-verified release for the current user without admin.
# - Configures stdio MCP for selected or detected clients.
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
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments,
    [switch]$Codex,
    [switch]$Crush,
    [switch]$OpenCode,
    [switch]$Swival,
    [switch]$VerifyAttestation,
    [switch]$BinaryOnly
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
        [IO.File]::Replace($Pending, $Path, [NullString]::Value)
    }
    else {
        [IO.File]::Move($Pending, $Path)
    }
}

function Assert-XerjPrivateDirectory {
    param([string]$Path)

    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { return }
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) {
        throw 'Xerj requires an absolute local directory.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $trusted = @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    }
    finally { $identity.Dispose() }
    $replace = [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
    $rights = $replace -bor [Security.AccessControl.FileSystemRights]::Write
    for ($ancestor = [IO.Path]::GetFullPath($Path); $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a non-directory or reparse path: $ancestor"
        }
        $acl = Get-Acl -LiteralPath $ancestor
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
            throw "Refusing a directory with an untrusted owner: $ancestor"
        }
        $untrusted = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin ($trusted + 'S-1-3-0') -and
                ($_.FileSystemRights -band $rights) -and -not ($_.PropagationFlags -band 'InheritOnly')
            }).Count
        if ($untrusted) { throw "Refusing a shared writable directory: $ancestor" }
        $rights = $replace
    }
}

function Save-Config {
    param([string]$Path, [string]$Text, [AllowNull()][object]$Original)
    if ($null -ne $Original -and $Text -ceq $Original) { return }
    $directory = Split-Path $Path
    Assert-XerjPrivateDirectory $directory
    $null = New-Item -ItemType Directory -Force -Path $directory
    Assert-XerjPrivateDirectory $directory
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        if ($null -ne $Original -and [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
            $null = New-Item -ItemType File -Path $temporary
            Set-Acl -LiteralPath $temporary -AclObject (Get-Acl -LiteralPath $Path)
        }
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        $current = Read-Config $Path
        if ($current -cne $Original) { throw 'Configuration changed concurrently. Retry after closing the client.' }
        Complete-FileReplacement $temporary $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Confirm-StagedXerj {
    param([string]$Path, [string]$Tag, [string]$Stage)

    $stdout = Join-Path $Stage 'version.out'
    $stderr = Join-Path $Stage 'version.err'
    $arguments = @{
        FilePath               = $Path
        ArgumentList           = '--version'
        PassThru               = $true
        NoNewWindow            = $true
        WorkingDirectory       = $Stage
        RedirectStandardOutput = $stdout
        RedirectStandardError  = $stderr
    }
    $process = Start-Process @arguments
    try {
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            throw 'Staged executable timed out during its version check.'
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or ([IO.File]::ReadAllText($stdout)).TrimEnd() -cne "xerj $Tag") {
            throw 'Staged executable failed its version check.'
        }
    }
    finally { $process.Dispose() }
}

function ConvertTo-BashLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-XerjLatestTag {
    # Follow the public redirect instead of consuming the shared GitHub API quota.
    $response = Invoke-WebRequest -Uri 'https://github.com/xerj-org/xerj/releases/latest' -Method Head -TimeoutSec 60 -UseBasicParsing
    $baseResponse = $response.BaseResponse
    # Windows PowerShell uses HttpWebResponse; PowerShell 7 uses HttpResponseMessage.
    $uri = if ($baseResponse.PSObject.Properties['ResponseUri']) {
        $baseResponse.ResponseUri
    }
    else { $baseResponse.RequestMessage.RequestUri }
    if ([string]$uri -cnotmatch '^https://github\.com/xerj-org/xerj/releases/tag/(v[0-9][A-Za-z0-9.+-]*)$') {
        throw 'Could not resolve the latest xerj release. Retry or specify -Version TAG.'
    }
    return $Matches[1]
}

# ---------------------------------------------------------------------------
# Install and configure
# ---------------------------------------------------------------------------
$stage = $null
function Test-JsonDateCoercion {
    param($Value)

    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return $true }
    if ($Value -is [array]) {
        foreach ($item in $Value) {
            if (Test-JsonDateCoercion $item) { return $true }
        }
    }
    elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-JsonDateCoercion $property.Value) { return $true }
        }
    }
    return $false
}

function ConvertFrom-StrictConfig {
    param([string]$Text)

    if ($Text -notmatch '^\s*\{') { throw 'Configuration must be a JSON object.' }
    # Preflight constructs that cannot safely round-trip through PowerShell
    # objects. ConvertFrom-Json still checks the actual JSON grammar.
    $objects = [Collections.Generic.Stack[hashtable]]::new()
    $tokens = [regex]::Matches($Text, '(?<string>"(?:[^"\\\x00-\x1f]|\\.)*")(?<property>\s*:)?|(?<open>\{)|(?<close>\})|(?<arrayOpen>\[)|(?<arrayClose>\])|(?<nonstandard>//|/\*|\x27|,\s*[}\]])')
    $depth = 0
    foreach ($token in $tokens) {
        if ($token.Groups['nonstandard'].Success) {
            throw 'Configuration contains nonstandard JSON. Merge the xerj registration manually.'
        }
        if ($token.Groups['open'].Success -or $token.Groups['arrayOpen'].Success) { $depth++ }
        if ($token.Groups['close'].Success -or $token.Groups['arrayClose'].Success) { $depth-- }
        if ($depth -gt 96) { throw 'Configuration is too deeply nested for safe rewriting.' }
        if ($token.Groups['open'].Success) { $objects.Push(@{}); continue }
        if ($token.Groups['close'].Success) { $null = $objects.Pop(); continue }
        if (-not $token.Groups['property'].Success) { continue }
        $decoded = ('{' + $token.Groups['string'].Value + ':null}') | ConvertFrom-Json
        $key = ($decoded.PSObject.Properties | Select-Object -First 1).Name
        $names = $objects.Peek()
        if ($names.ContainsKey($key)) {
            throw 'Configuration contains a duplicate property.'
        }
        $names[$key] = $true
    }
    $json = @{ InputObject = $Text }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $json.DateKind = 'String' }
    try { $result = ConvertFrom-Json @json }
    catch { throw 'Configuration contains invalid JSON.' }
    if (-not $json.ContainsKey('DateKind') -and (Test-JsonDateCoercion $result)) {
        throw 'This PowerShell version converted a JSON string to a date. Use a newer PowerShell or merge xerj manually.'
    }
    return $result
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing a configuration directory or reparse point.'
    }
    return [IO.File]::ReadAllText($Path)
}

function Get-JsonObject {
    param($Parent, [string]$Name)
    $property = $Parent.PSObject.Properties[$Name]
    if (-not $property) {
        $Parent | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{})
        $property = $Parent.PSObject.Properties[$Name]
    }
    if ($property.Value -isnot [pscustomobject]) { throw "The JSON property '$Name' must be an object." }
    return $property.Value
}

function Test-ManagedCommand {
    param($Command, $CommandArgs, [string]$Binary)
    # The executable and argument shape establish ownership. The URL value
    # may differ because a subsequent registration can change the endpoint.
    return ($Command -is [string] -and $Command -ieq $Binary -and $CommandArgs -is [array] -and
        $CommandArgs.Count -eq 3 -and $CommandArgs[0] -ceq 'mcp' -and $CommandArgs[1] -ceq '--url' -and
        $CommandArgs[2] -is [string])
}

function Merge-JsonMcpEntry {
    param($Table, [string]$Client, [string]$Binary, [string]$Endpoint)
    $argsList = @('mcp', '--url', $Endpoint)
    $property = $Table.PSObject.Properties['xerj']
    if ($property) {
        $entry = $property.Value
        if ($entry -isnot [pscustomobject]) { throw 'An unrelated MCP server named xerj already exists.' }
        $type = $entry.PSObject.Properties['type'].Value
        switch ($Client) {
            'opencode' { if ($type -cne 'local') { throw 'An unrelated MCP server named xerj already exists.' } }
            'copilot-cli' { if ($type -cnotin @('local', 'stdio')) { throw 'An unrelated MCP server named xerj already exists.' } }
            'claude' { if ($type -cne 'stdio') { throw 'An unrelated MCP server named xerj already exists.' } }
        }
        $command = $entry.PSObject.Properties['command'].Value
        if ($Client -eq 'opencode') {
            if ($command -isnot [array] -or $command.Count -ne 4 -or -not (Test-ManagedCommand $command[0] $command[1..3] $Binary)) {
                throw 'An unrelated MCP server named xerj already exists.'
            }
            $entry.command = @($Binary) + $argsList
        }
        else {
            $existingArgs = $entry.PSObject.Properties['args'].Value
            if (-not (Test-ManagedCommand $command $existingArgs $Binary)) { throw 'An unrelated MCP server named xerj already exists.' }
            $entry.args = $argsList
        }
        return
    }

    $entry = switch ($Client) {
        'opencode' { [pscustomobject]@{ type = 'local'; command = @($Binary) + $argsList } }
        'copilot-cli' { [pscustomobject]@{ type = 'local'; command = $Binary; args = $argsList; tools = @('*') } }
        'claude' { [pscustomobject]@{ type = 'stdio'; command = $Binary; args = $argsList; env = @{} } }
    }
    $Table | Add-Member -NotePropertyName xerj -NotePropertyValue $entry
}

function Register-JsonMcp {
    param([string]$Client, [string]$Config, [string]$Binary, [string]$Endpoint, [int]$OpenCodeMajor)

    $old = Read-Config $Config
    $data = if ($null -ne $old) { ConvertFrom-StrictConfig $old } else { [pscustomobject]@{} }
    if ($Client -eq 'opencode') {
        $mcp = Get-JsonObject $data 'mcp'
        $table = $mcp
        if ($OpenCodeMajor -eq 2) {
            # OpenCode 2 expects its server definitions under mcp.servers.
            if (@($mcp.PSObject.Properties | Where-Object {
                        $_.Name -cnotin @('servers', 'xerj') -and $_.Value -is [pscustomobject] -and
                        $_.Value.PSObject.Properties['type']
                    }).Count) {
                throw 'OpenCode 2 migration would affect unrelated legacy settings. Migrate them in OpenCode first.'
            }
            $table = Get-JsonObject $mcp 'servers'
            $legacy = $mcp.PSObject.Properties['xerj']
            if ($legacy) {
                if ($table.PSObject.Properties['xerj']) { throw 'Both OpenCode MCP schemas contain xerj; resolve the conflict manually.' }
                Merge-JsonMcpEntry $mcp $Client $Binary $Endpoint
                $entry = $legacy.Value
                if ($entry.PSObject.Properties['enabled']) {
                    if ($entry.enabled -isnot [bool] -or $entry.PSObject.Properties['disabled']) { throw 'Ambiguous OpenCode enabled setting.' }
                    if (-not $entry.enabled) { $entry | Add-Member -NotePropertyName disabled -NotePropertyValue $true }
                    $entry.PSObject.Properties.Remove('enabled')
                }
                $table | Add-Member -NotePropertyName xerj -NotePropertyValue $entry
                $mcp.PSObject.Properties.Remove('xerj')
            }
        }
        elseif ($mcp.PSObject.Properties['servers']) { throw 'OpenCode 1 cannot use the existing OpenCode 2 MCP configuration.' }
    }
    else { $table = Get-JsonObject $data 'mcpServers' }
    $newEntry = -not $table.PSObject.Properties['xerj']
    Merge-JsonMcpEntry $table $Client $Binary $Endpoint
    if ($Client -eq 'opencode' -and $OpenCodeMajor -eq 1 -and $newEntry) {
        $table.xerj | Add-Member -NotePropertyName enabled -NotePropertyValue $true
    }
    Save-Config $Config (($data | ConvertTo-Json -Depth 100 -WarningAction Stop) + "`n") $old
}

function Register-CodexMcp {
    param($Command, [string]$Binary, [string]$Endpoint)
    if ($Command -is [Management.Automation.ApplicationInfo] -and $Command.Path -match '\.(cmd|bat)$' -and
        "$Binary$Endpoint" -match '[&!^()%]') {
        throw 'Use the native Codex executable when a path or endpoint contains CMD metacharacters.'
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Command mcp get xerj --json 2>&1
    }
    finally { $ErrorActionPreference = $previousPreference }
    $status = $LASTEXITCODE
    if ($status -eq 0) {
        $payload = ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n"
        try { $entry = ConvertFrom-StrictConfig $payload }
        catch { throw 'Codex returned an invalid MCP description.' }
        if ($entry.transport.type -cne 'stdio' -or -not (Test-ManagedCommand $entry.transport.command $entry.transport.args $Binary)) {
            throw 'An unrelated Codex MCP server named xerj already exists.'
        }
        if ($entry.transport.args[2] -ceq $Endpoint) { return }
        # Codex get omits fields such as "required". Adding a server again
        # replaces its complete table and could discard those settings.
        throw 'Update the existing Codex xerj endpoint manually in config.toml.'
    }
    else {
        $payload = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ($payload -notmatch "(?m)^(?:Error: )?No MCP server named 'xerj' found\.\s*$") {
            throw 'Could not inspect the Codex MCP configuration.'
        }
    }
    $registration = @('mcp', 'add', 'xerj', '--', $Binary, 'mcp', '--url', $Endpoint)
    & $Command @registration *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Codex MCP registration failed.' }
}

function Test-CrushShellConfig {
    param($Command)
    $PSNativeCommandUseErrorActionPreference = $false
    try { $output = & $Command --version 2>$null }
    catch { return $false }
    $banner = $output -join "`n"
    if ($LASTEXITCODE -ne 0 -or $banner -notmatch '(?m)^\s*(?:crush\s+)?(?:version\s+)?v?(\d+\.\d+\.\d+)([-+][A-Za-z0-9.+-]+)?\s*$') {
        return $false
    }
    $version = $null
    if (-not [version]::TryParse($Matches[1], [ref]$version)) { return $false }
    $minimum = [version]'0.88.0'
    return ($version -gt $minimum -or ($version -eq $minimum -and $Matches[2] -notlike '-*'))
}

function Register-CrushMcp {
    param([string]$Config, [string]$Binary, [string]$Endpoint)
    $legacyText = Read-Config (Join-Path (Split-Path $Config) 'crush.json')
    if ($null -ne $legacyText) {
        $legacy = ConvertFrom-StrictConfig $legacyText
        $legacyMcp = $legacy.PSObject.Properties['mcp']
        if ($legacyMcp -and ($legacyMcp.Value -isnot [pscustomobject] -or $legacyMcp.Value.PSObject.Properties['xerj'])) {
            throw 'The legacy Crush configuration contains an MCP conflict. Merge xerj manually.'
        }
    }
    $old = Read-Config $Config
    $begin = '# BEGIN xerj managed'
    $end = '# END xerj managed'
    $body = [string]$old
    $block = '(?m)^' + [regex]::Escape($begin) + '\r?\n(?<line>[^\r\n]*)\r?\n' + [regex]::Escape($end) + '(?:\r?\n|$)'
    $markers = [regex]::Matches($body, '(?m)^# (?:BEGIN|END) xerj managed\r?$')
    $existing = [regex]::Matches($body, $block)
    $command = ConvertTo-BashLiteral ($Binary.Replace('\', '/'))
    $prefix = "mcp add xerj --type stdio --command $command --args mcp --args --url --args "
    if ($markers.Count -ne $existing.Count * 2 -or $existing.Count -gt 1) { throw 'Malformed xerj managed block.' }
    if ($existing.Count -eq 1) {
        $line = $existing[0].Groups['line'].Value
        if (-not $line.StartsWith($prefix, [StringComparison]::Ordinal)) {
            throw 'The existing Crush MCP block is unrelated to this installation.'
        }
        $literal = $line.Substring($prefix.Length)
        if ($literal.Length -lt 2 -or -not $literal.StartsWith("'") -or -not $literal.EndsWith("'")) {
            throw 'The managed Crush MCP block has an invalid endpoint argument.'
        }
        $value = $literal.Substring(1, $literal.Length - 2).Replace("'\''", "'")
        if ((ConvertTo-BashLiteral $value) -cne $literal) { throw 'The managed Crush MCP block contains an extra command or argument.' }
    }
    $unmanaged = [regex]::Replace($body, $block, '')
    if ($unmanaged -match '(?:^|[;\n])\s*(?:command\s+)?mcp\s+add\s+["'']?xerj(?:["'']|\s|$)') {
        throw 'An unrelated Crush MCP server named xerj already exists.'
    }
    $endpointLiteral = ConvertTo-BashLiteral $Endpoint
    $replacement = "$begin`n$prefix$endpointLiteral`n$end`n"
    $text = if ($existing.Count -eq 1) {
        $body.Substring(0, $existing[0].Index) + $replacement + $body.Substring($existing[0].Index + $existing[0].Length)
    }
    else {
        $separator = if ($body -and -not $body.EndsWith("`n")) { "`n" } else { '' }
        $body + $separator + $replacement
    }
    Save-Config $Config $text $old
}

function Confirm-SwivalConfig {
    param($Command, [string]$Candidate, [string]$Stage)

    $configDir = Join-Path $Stage 'swival'
    $project = Join-Path $Stage 'swival-config-check'
    $null = New-Item -ItemType Directory -Force -Path $configDir, $project
    $configPath = Join-Path $configDir 'config.toml'
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -and
        -not (Test-Path -LiteralPath $configPath)) {
        # Existing Swival settings can contain secrets. Restrict the validation
        # copy before writing user data, including under a custom TEMP path.
        $null = New-Item -ItemType File -Path $configPath
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User, 'FullControl', 'Allow'))
            Set-Acl -LiteralPath $configPath -AclObject $acl
        }
        finally { $identity.Dispose() }
    }
    [IO.File]::WriteAllText($configPath, $Candidate, [Text.UTF8Encoding]::new($false))
    $engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' }
    elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'pwsh.exe' }
    else { 'pwsh' }
    $probe = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
& $env:XERJ_SWIVAL_PROBE --list-profiles --base-dir $env:XERJ_SWIVAL_PROJECT
if (-not $?) { exit 1 }
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $engine
    $start.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $project
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $Stage
    $start.EnvironmentVariables['XERJ_SWIVAL_PROBE'] = $Command.Source
    $start.EnvironmentVariables['XERJ_SWIVAL_PROJECT'] = $project
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start Swival configuration validation.' }
        $process.StandardInput.Close()
        # Drain both streams even though only the exit status is needed.
        # Forwarding diagnostics could expose values from the user's config.
        $output = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        $errors = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        if (-not $process.WaitForExit(20000) -or $process.ExitCode -ne 0 -or
            -not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output, $errors), 3000)) {
            throw 'Swival could not validate its TOML configuration.'
        }
    }
    finally {
        try {
            if (-not $process.HasExited) {
                if ($PSVersionTable.PSEdition -eq 'Desktop') { $process.Kill() }
                else { $process.Kill($true) }
            }
        }
        catch { Write-Verbose 'The Swival validation process could not be stopped.' }
        $process.Dispose()
    }
}

function Register-SwivalMcp {
    param($Command, [string]$Config, [string]$Binary, [string]$Endpoint, [string]$Stage)

    Assert-XerjPrivateDirectory (Split-Path $Config)
    $old = Read-Config $Config
    if ($null -ne $old) {
        try {
            $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
            $decoded = $strictUtf8.GetString([IO.File]::ReadAllBytes($Config))
        }
        catch { throw 'Swival configuration must be valid UTF-8.' }
        if ($decoded -cne $old) { throw 'Swival configuration must be UTF-8 without a BOM.' }
    }
    $body = [string]$old
    $begin = '# BEGIN xerj managed'
    $end = '# END xerj managed'
    $table = '[mcp_servers.xerj]'
    $commandLine = 'command = ' + (ConvertTo-Json -InputObject $Binary -Compress)
    $prefix = 'args = ["mcp", "--url", '
    $encodedUrl = ConvertTo-Json -InputObject $Endpoint -Compress
    $argsLine = $prefix + $encodedUrl + ']'
    $block = "$begin`n$table`n$commandLine`n$argsLine`n$end`n"
    $markers = [regex]::Matches($body, '(?m)^(?:' + [regex]::Escape($begin) + '|' + [regex]::Escape($end) + ')\r?$')
    if ($markers.Count) {
        $owned = '(?m)^' + [regex]::Escape($begin) + '\r?\n' + [regex]::Escape($table) + '\r?\n' +
        [regex]::Escape($commandLine) + '\r?\n' + [regex]::Escape($prefix) + '(?<url>"https?://[^"\r\n]+")\]\r?\n' +
        [regex]::Escape($end) + '\r?(?:\n|\z)\s*\z'
        $match = [regex]::Match($body, $owned)
        if ($markers.Count -ne 2 -or -not $match.Success) {
            throw 'Existing xerj MCP definition requires manual editing.'
        }
        $urlMatch = $match.Groups['url']
        $text = $body.Substring(0, $urlMatch.Index) + $encodedUrl + $body.Substring($urlMatch.Index + $urlMatch.Length)
    }
    else {
        $separator = if ($body -and -not $body.EndsWith("`n")) { "`n" } else { '' }
        $text = $body + $separator + $block
    }

    if ($body) { Confirm-SwivalConfig $Command $body $Stage }
    if ($text -cne $old) { Confirm-SwivalConfig $Command $text $Stage }
    Save-Config $Config $text $old
}

if ($Arguments -and $Arguments.Count -eq 1 -and $Arguments[0] -cin @('--help', '-h')) {
    Write-Output @'
Usage: update-xerj [all | AGENT ... | --binary-only] [--version TAG] [--url URL] [--verify-attestation]
Agents: codex crush opencode copilot-cli claude swival
Without selectors or with all, configure detected clients only.
Windows also accepts -Version, -Url, -BinaryOnly, -Codex, -Crush, -OpenCode and -Swival.
'@
    exit 0
}

try {
    $clients = [ordered]@{ codex = 'codex'; crush = 'crush'; opencode = 'opencode'; 'copilot-cli' = 'copilot'; claude = 'claude'; swival = 'swival' }
    $selected = @()
    if ($Codex) { $selected += 'codex' }
    if ($Crush) { $selected += 'crush' }
    if ($OpenCode) { $selected += 'opencode' }
    if ($Swival) { $selected += 'swival' }
    $selectAll = $false
    $Version = $null
    $Url = if ($env:XERJ_URL) { $env:XERJ_URL } else { 'http://127.0.0.1:9200' }
    $hasVersion = $false
    $hasUrl = $false
    for ($i = 0; $Arguments -and $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        $option = switch ($argument) {
            '-Version' { '--version' }
            '-Url' { '--url' }
            default { $argument }
        }
        switch -CaseSensitive ($option) {
            '--version' {
                if ($hasVersion -or ++$i -ge $Arguments.Count) { throw 'Specify a release tag once.' }
                $Version = $Arguments[$i]
                $hasVersion = $true
            }
            '--url' {
                if ($hasUrl -or ++$i -ge $Arguments.Count) { throw 'Specify one endpoint URL.' }
                $Url = $Arguments[$i]
                $hasUrl = $true
            }
            '--verify-attestation' { $VerifyAttestation = $true }
            '--binary-only' { $BinaryOnly = $true }
            'all' { $selectAll = $true }
            default {
                if ($argument.StartsWith('--')) { $argument = $argument.Substring(2) }
                if ($argument -cnotin $clients.Keys) { throw 'Invalid selector or option. See update-xerj --help.' }
                $selected += $argument
            }
        }
    }
    if (($selectAll -and $selected) -or ($BinaryOnly -and ($selectAll -or $selected))) { throw 'Select all, specific agents or --binary-only.' }
    if ($hasVersion -and $Version -cnotmatch '^v?[0-9][A-Za-z0-9.+-]*$') { throw 'Invalid release tag.' }
    $endpoint = $null
    if (-not $BinaryOnly -or $hasUrl) {
        if ($Url -match '[\x00-\x20\x7f\\"<>|%?#]' -or
            -not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$endpoint) -or
            $endpoint.Scheme -notin @('http', 'https') -or -not $endpoint.Host -or $endpoint.UserInfo) {
            throw 'Use an absolute HTTP(S) endpoint without credentials, query, or fragment.'
        }
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 2
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
    $commands = [ordered]@{}
    if (-not $BinaryOnly) {
        $requested = if ($selected) { $selected | Select-Object -Unique } else { $clients.Keys }
        foreach ($client in $requested) {
            $command = Get-Command $clients[$client] -CommandType Application, ExternalScript -ErrorAction SilentlyContinue
            if ($client -eq 'crush' -and $command -and -not (Test-CrushShellConfig $command)) {
                $reason = 'Crush 0.88.0 or newer is required for crushrc MCP registration.'
                if ($selected) { throw $reason }
                Write-Info "Skipped crush. $reason"
            }
            elseif ($command) { $commands[$client] = $command }
            elseif ($selected) { throw "Selected client is unavailable: $client" }
            else { Write-Info "Skipped $client (client unavailable)." }
        }
    }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($architecture) {
        'X64' { $target = 'x86_64' }
        'Arm64' { $target = 'aarch64' }
        default { throw "Unsupported architecture: $architecture" }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $Version) {
        $Version = Get-XerjLatestTag
    }
    $tag = 'v' + $Version.TrimStart('v')
    if ($tag -cnotmatch '^v[0-9][A-Za-z0-9.+-]*$') { throw 'Invalid release tag.' }
    $asset = "xerj-$($tag.Substring(1))-$target-pc-windows-msvc.zip"
    $base = "https://github.com/xerj-org/xerj/releases/download/$tag"
    $tempRoot = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    Assert-XerjPrivateDirectory $tempRoot
    $stage = Join-Path $tempRoot ('update-xerj-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    Assert-XerjPrivateDirectory $stage
    $archive = Join-Path $stage $asset
    Invoke-WebRequest "$base/$asset" -OutFile $archive -TimeoutSec 300 -UseBasicParsing
    Invoke-WebRequest "$base/$asset.sha256" -OutFile "$archive.sha256" -TimeoutSec 60 -UseBasicParsing
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines = [IO.File]::ReadAllLines("$archive.sha256")
    if ($lines -cnotcontains "$digest  $asset" -and $lines -cnotcontains "$digest *$asset") {
        throw 'SHA-256 mismatch; refusing installation.'
    }
    if ($VerifyAttestation) {
        $gh = Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $gh.Source release verify-asset -R github.com/xerj-org/xerj $tag $archive
        if ($LASTEXITCODE -ne 0) { throw 'GitHub release attestation verification failed.' }
    }
    # Read only the expected entry; do not extract archive paths.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $expected = "$($asset.Substring(0, $asset.Length - 4))/xerj.exe"
        $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $expected })
        if ($entries.Count -ne 1) { throw 'Expected exactly one xerj.exe in release.' }
        $entry = $entries[0]
        $entryType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($entry.Length -le 0 -or $entry.Length -gt 536870912 -or
            $entryType -notin @(0, 0x8000) -or
            ($entry.ExternalAttributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) {
            throw 'Invalid executable entry in release.'
        }
        $root = Join-Path $env:LOCALAPPDATA 'Programs/xerj'
        Assert-XerjPrivateDirectory $root
        $null = New-Item -ItemType Directory -Force -Path $root
        Assert-XerjPrivateDirectory $root
        $binary = Join-Path $root 'xerj.exe'
        $pending = Join-Path $root ('.xerj-' + [guid]::NewGuid().ToString('N') + '.exe')
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $pending)
            Confirm-StagedXerj $pending $tag $stage
            Complete-FileReplacement $pending $binary
        }
        finally {
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
        }
    }
    finally { $zip.Dispose() }
    Write-Info "Installed $tag at $binary"
    $registrationFailed = $false
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userHome '.config' }
    foreach ($client in $commands.Keys) {
        try {
            switch ($client) {
                'codex' {
                    # Inspect user settings from private staging rather than a
                    # project that may shadow the user MCP registration.
                    $codexHome = $env:CODEX_HOME
                    if ($codexHome -and -not [IO.Path]::IsPathRooted($codexHome)) {
                        $env:CODEX_HOME = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($codexHome)
                    }
                    try {
                        Push-Location -LiteralPath $stage
                        try { Register-CodexMcp $commands[$client] $binary $Url }
                        finally { Pop-Location }
                    }
                    finally { $env:CODEX_HOME = $codexHome }
                }
                'crush' {
                    $root = if ($env:CRUSH_GLOBAL_CONFIG) { $env:CRUSH_GLOBAL_CONFIG } else { Join-Path $configRoot 'crush' }
                    Register-CrushMcp (Join-Path $root 'crushrc') $binary $Url
                }
                'opencode' {
                    if ($env:OPENCODE_CONFIG -or $env:OPENCODE_CONFIG_DIR -or $env:OPENCODE_CONFIG_CONTENT) {
                        throw 'OpenCode has an explicit configuration override. Merge xerj manually into the active configuration.'
                    }
                    $config = Join-Path $configRoot 'opencode/opencode.json'
                    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($config, '.jsonc'))) {
                        throw 'Merge xerj into the existing opencode.jsonc manually.'
                    }
                    $PSNativeCommandUseErrorActionPreference = $false
                    $output = & $commands[$client] --version 2>$null
                    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch '(?m)^\s*(?:opencode\s+)?v?([12])\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\s*$') {
                        throw 'Could not determine whether OpenCode uses the v1 or v2 MCP schema.'
                    }
                    Register-JsonMcp $client $config $binary $Url ([int]$Matches[1])
                }
                'copilot-cli' {
                    $root = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $userHome '.copilot' }
                    Register-JsonMcp $client (Join-Path $root 'mcp-config.json') $binary $Url
                }
                'swival' {
                    Register-SwivalMcp $commands[$client] (Join-Path $configRoot 'swival/config.toml') $binary $Url $stage
                }
                'claude' {
                    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $userHome }
                    Register-JsonMcp $client (Join-Path $root '.claude.json') $binary $Url
                }
            }
            Write-Info "$client MCP configured."
        }
        catch {
            Write-Fail "${client}: $($_.Exception.Message)"
            $registrationFailed = $true
        }
    }
    if ($commands.Count) {
        Write-Info 'MCP requires a running xerj node. See windows/README.md for startup and authentication.'
    }
    if ($registrationFailed) { exit 1 }
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
