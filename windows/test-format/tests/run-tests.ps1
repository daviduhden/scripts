#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -ErrorAction Stop

$wrapper = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'psfmt.ps1'))
# Generated cases live below vendor so a later `psfmt -w .` never formats
# intentionally invalid fixtures, module copies or diagnostic evidence.
$work = [IO.Path]::Combine($PSScriptRoot, 'vendor', 'work', [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($work)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$sample = "function Test-Sample{`n`$text='Español 日本語 😀';if(`$true){Write-Output `$text}`n}"
$formatted = Invoke-Formatter -ScriptDefinition $sample
$passed = [Collections.Generic.List[string]]::new()
$failed = [Collections.Generic.List[string]]::new()
$skipped = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Case {
    param([string] $Name, [scriptblock] $Body)
    try {
        $previousSkipCount = $skipped.Count
        & $Body
        if ($skipped.Count -gt $previousSkipCount) { Write-Output "SKIP $Name"; return }
        $passed.Add($Name)
        Write-Output "PASS $Name"
    }
    catch {
        $failed.Add($Name + ': ' + $_.Exception.Message)
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
}

function New-Source {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture creation is limited to the generated test directory.')]
    param([string] $RelativePath, [string] $Text = $sample, [Text.Encoding] $Encoding = $utf8)
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($work, $RelativePath))
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllBytes($path, [byte[]] ($Encoding.GetPreamble() + $Encoding.GetBytes($Text)))
    return $path
}

function Invoke-Tool {
    param([string[]] $Arguments, [string] $Entry = $wrapper, [string] $Directory = $work)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [IO.Path]::Combine($PSHOME, 'pwsh.exe')
    if (-not $IsWindows) { $start.FileName = [IO.Path]::Combine($PSHOME, 'pwsh') }
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Entry) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw 'Test process timed out.' }
        [pscustomobject]@{ Code = $process.ExitCode; Out = $stdout.GetAwaiter().GetResult(); Err = $stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Assert-Code {
    param($Result, [int] $Code)
    Assert-True ($Result.Code -eq $Code) "Expected exit $Code, got $($Result.Code): $($Result.Err) $($Result.Out)"
}

function Get-BytesKey {
    param([string] $Path)
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

# Work is inside an ignored directory in the real tree. Each invocation uses
# a junction-free mirror outside vendor, still entirely within test-format.
$active = [IO.Path]::Combine($PSScriptRoot, 'work', [IO.Path]::GetFileName($work))
$null = [IO.Directory]::CreateDirectory($active)
$work = $active

Invoke-Case 'help and version work without formatting' {
    foreach ($option in '-h', '-help', '-version') {
        $result = Invoke-Tool @($option)
        Assert-Code $result 0
        Assert-True ($result.Err -eq '' -and $result.Out.Contains('psfmt 0.1.0')) $option
    }
}
Invoke-Case 'single file stdout is only Invoke-Formatter output' {
    $path = New-Source 'stdout/espacio ñ 日本語.ps1'
    $before = Get-BytesKey $path
    $result = Invoke-Tool @($path)
    Assert-Code $result 0
    Assert-True ($result.Err -eq '') $result.Err
    Assert-True ($result.Out -ceq ($formatted + [Environment]::NewLine)) 'Unexpected stdout text'
    Assert-True ((Get-BytesKey $path) -ceq $before) 'stdout modified source'
}
Invoke-Case 'PowerShell script redirection creates formatted code' {
    $path = New-Source 'redirect/input.ps1'
    $output = [IO.Path]::Combine($work, 'redirect', 'output.ps1')
    $entry = New-Source 'redirect/run.ps1' '& $args[0] $args[1] > $args[2]; exit $LASTEXITCODE'
    $result = Invoke-Tool -Entry $entry -Arguments @($wrapper, $path, $output)
    Assert-Code $result 0
    Assert-True ($result.Out -eq '' -and $result.Err -eq '') 'Redirection leaked text'
    Assert-True ([IO.File]::ReadAllText($output) -ceq ($formatted + [Environment]::NewLine)) 'Bad redirected code'
}

foreach ($encodingName in 'utf8', 'utf8-bom', 'utf16le', 'utf16be') {
    $encoding = switch ($encodingName) {
        'utf8' { [Text.UTF8Encoding]::new($false, $true) }
        'utf8-bom' { [Text.UTF8Encoding]::new($true, $true) }
        'utf16le' { [Text.UnicodeEncoding]::new($false, $true, $true) }
        'utf16be' { [Text.UnicodeEncoding]::new($true, $true, $true) }
    }
    foreach ($newline in @("`n", "`r`n")) {
        foreach ($ending in @('', $newline, ($newline + $newline))) {
            $caseName = "$encodingName EOL=$($newline.Length) final=$($ending.Length)"
            Invoke-Case $caseName {
                $path = New-Source -RelativePath "encodings/$encodingName-$($newline.Length)-$($ending.Length).ps1" -Text ($sample.Replace("`n", $newline) + $ending) -Encoding $encoding
                $expected = $encoding.GetPreamble() + $encoding.GetBytes($formatted.Replace("`n", $newline) + $ending)
                Assert-Code (Invoke-Tool @('-c', $path)) 2
                Assert-Code (Invoke-Tool @('-w', $path)) 0
                Assert-True ((Get-BytesKey $path) -ceq [Convert]::ToBase64String([byte[]] $expected)) 'Encoding/BOM/Unicode/newline changed'
                $stamp = [IO.File]::GetLastWriteTimeUtc($path)
                Assert-Code (Invoke-Tool @('-c', $path)) 0
                Assert-Code (Invoke-Tool @('-w', $path)) 0
                Assert-True ([IO.File]::GetLastWriteTimeUtc($path) -eq $stamp) 'Second write touched formatted file'
            }
        }
    }
}

Invoke-Case 'list/diff/check are read-only; only changed paths listed' {
    $bad = New-Source 'modes/b.ps1'
    $good = New-Source 'modes/a.ps1' $formatted
    $before = Get-BytesKey $bad
    $badTime = [IO.File]::GetLastWriteTimeUtc($bad)
    $goodTime = [IO.File]::GetLastWriteTimeUtc($good)
    $directory = [IO.Path]::GetDirectoryName($bad)
    $list = Invoke-Tool @('-l', $directory)
    Assert-Code $list 0
    Assert-True ($list.Out.TrimEnd() -ceq $bad -and $list.Err -eq '') 'List included extra output or clean file'
    $diff = Invoke-Tool @('-d', $directory)
    Assert-Code $diff 0
    Assert-True ($diff.Out.StartsWith("--- $bad") -and $diff.Out.Contains("+++ $bad") -and $diff.Out.Contains('@@ -') -and $diff.Out.Contains('\ No newline at end of file')) 'Invalid diff headers'
    Assert-Code (Invoke-Tool @('-c', $directory)) 2
    Assert-True ((Get-BytesKey $bad) -ceq $before -and [IO.File]::GetLastWriteTimeUtc($bad) -eq $badTime) 'Non-write mode wrote a file'
    Assert-Code (Invoke-Tool @('-w', $directory)) 0
    Assert-True ([IO.File]::GetLastWriteTimeUtc($good) -eq $goodTime) 'Unchanged file was written'
}
Invoke-Case 'empty directory and empty file' {
    $directory = [IO.Path]::Combine($work, 'empty')
    $null = [IO.Directory]::CreateDirectory($directory)
    foreach ($mode in '-c', '-w', '-d', '-l') {
        $result = Invoke-Tool @($mode, $directory)
        Assert-Code $result 0
        Assert-True ($result.Out -eq '' -and $result.Err -eq '') 'Empty directory output'
    }
    $path = New-Source 'empty/empty.ps1' ''
    Assert-Code (Invoke-Tool @('-w', $path)) 0
    Assert-True (([IO.File]::ReadAllBytes($path)).Length -eq 0) 'Empty file changed'
}
Invoke-Case 'missing file and directory diagnostics use stderr' {
    foreach ($name in 'missing.ps1', 'missing-directory') {
        $path = [IO.Path]::Combine($work, $name)
        $result = Invoke-Tool @('-c', $path)
        Assert-Code $result 1
        Assert-True ($result.Out -eq '' -and $result.Err.Contains($path)) 'Missing path diagnostic'
    }
}
Invoke-Case 'invalid syntax continues to next file; errors take precedence' {
    $invalid = New-Source 'invalid/a.ps1' 'function Broken {'
    $valid = New-Source 'invalid/b.ps1'
    $before = Get-BytesKey $invalid
    Assert-Code (Invoke-Tool @('-c', [IO.Path]::GetDirectoryName($invalid))) 1
    $result = Invoke-Tool @('-w', $invalid, $valid)
    Assert-Code $result 1
    Assert-True ($result.Err.Contains($invalid) -and $result.Out -eq '') 'Missing parse diagnostic'
    Assert-True ((Get-BytesKey $invalid) -ceq $before) 'Invalid file changed'
    Assert-True ([IO.File]::ReadAllText($valid) -ceq $formatted) 'Processing stopped on invalid file'
}
Invoke-Case 'multiple directories, canonical deduplication, order, -r and extensions' {
    $first = New-Source 'multi/one/z.psm1'
    $second = New-Source 'multi/two/a.psd1' '@{Key=1;Other=2}'
    $third = New-Source 'multi/one/deep/UPPER.PS1'
    $other = New-Source 'multi/one/keep.txt'
    $otherBefore = Get-BytesKey $other
    $root = [IO.Path]::Combine($work, 'multi')
    $arguments = @('-l', '-r', "$root/one", "$root/two", "$root/one/../one/z.psm1", $first, $root)
    $result = Invoke-Tool $arguments
    Assert-Code $result 0
    $actual = @($result.Out.TrimEnd() -split '\r?\n')
    $expected = [string[]] @($first, $second, $third)
    [Array]::Sort($expected, [StringComparer]::OrdinalIgnoreCase)
    Assert-True (($actual -join '|') -ceq ($expected -join '|')) 'Deduplication or deterministic sorting failed'
    Assert-Code (Invoke-Tool @('-w', "$root/one", "$root/two")) 0
    Assert-Code (Invoke-Tool @('-c', $root)) 0
    Assert-True ((Get-BytesKey $other) -ceq $otherBefore) 'Unsupported file changed'
}
Invoke-Case 'all default exclusions including hidden VCS directories' {
    foreach ($name in '.git', '.svn', '.hg', 'node_modules', 'bin', 'obj', 'vendor') { $null = New-Source "ignored/$name/bad.ps1" 'function Invalid {' }
    $path = New-Source 'ignored/keep.ps1' $formatted
    Assert-Code (Invoke-Tool @('-c', [IO.Path]::GetDirectoryName($path))) 0
}
Invoke-Case 'repeated glob and directory exclusions prune before parsing' {
    $null = New-Source 'exclude/generated/a.ps1' 'function Invalid {'
    $null = New-Source 'exclude/a.generated.ps1' 'function Invalid {'
    $path = New-Source 'exclude/keep.ps1'
    $result = Invoke-Tool @('-l', '-exclude', 'generated', '-exclude', '*.generated.ps1', [IO.Path]::GetDirectoryName($path))
    Assert-Code $result 0
    Assert-True ($result.Out.TrimEnd() -ceq $path) 'Exclusion selected incorrect paths'
}
Invoke-Case 'hidden files are discovered' {
    $path = New-Source 'hidden/hidden.ps1'
    if ($IsWindows) { [IO.File]::SetAttributes($path, [IO.FileAttributes]::Hidden) }
    $result = Invoke-Tool @('-l', [IO.Path]::GetDirectoryName($path))
    Assert-Code $result 0
    Assert-True ($result.Out.TrimEnd() -ceq $path) 'Hidden file missing'
    Assert-Code (Invoke-Tool @('-w', $path)) 0
    if ($IsWindows) { Assert-True (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Hidden) -ne 0) 'Hidden attribute lost' }
}
Invoke-Case 'settings are passed to Invoke-Formatter' {
    $settings = New-Source 'settings/custom.psd1' "@{IncludeRules=@('PSUseConsistentIndentation');Rules=@{PSUseConsistentIndentation=@{Enable=`$true;IndentationSize=2;Kind='space'}}}"
    $path = New-Source 'settings/source.ps1'
    $expected = Invoke-Formatter -ScriptDefinition $sample -Settings $settings
    Assert-Code (Invoke-Tool @('-w', '-settings', $settings, $path)) 0
    Assert-True ([IO.File]::ReadAllText($path) -ceq $expected) 'Settings not applied'
    Assert-Code (Invoke-Tool @('-c', '-settings', $settings, $path)) 0
    $result = Invoke-Tool @('-w', '-settings', "$settings.missing.psd1", $path)
    Assert-Code $result 1
    Assert-True ($result.Err.Contains('missing.psd1') -and $result.Out -eq '') 'Missing settings diagnostic'
}
Invoke-Case 'unified diff reconstructs formatter output without git' {
    $source = ((1..8 | ForEach-Object { "# prefix $_" }) -join "`n") + "`n" + $sample + "`n" + ((1..8 | ForEach-Object { "# suffix $_" }) -join "`n")
    $path = New-Source 'diff/source.ps1' $source
    $result = Invoke-Tool @('-d', $path)
    Assert-Code $result 0
    $lines = $result.Out -split '\r?\n'
    Assert-True ($lines[2] -match '^@@ -(\d+),(\d+) \+(\d+),(\d+) @@$') 'Malformed hunk'
    $start = [int] $Matches[1] - 1
    $length = [int] $Matches[2]
    $originalLines = $source.Split("`n")
    $replacement = [Collections.Generic.List[string]]::new()
    for ($index = 3; $index -lt $lines.Count; $index++) {
        if ($lines[$index].StartsWith('+') -or $lines[$index].StartsWith(' ')) { $replacement.Add($lines[$index].Substring(1)) }
    }
    $reconstructed = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $start; $index++) { $reconstructed.Add($originalLines[$index]) }
    $reconstructed.AddRange($replacement)
    for ($index = $start + $length; $index -lt $originalLines.Count; $index++) { $reconstructed.Add($originalLines[$index]) }
    Assert-True (($reconstructed -join "`n") -ceq (Invoke-Formatter -ScriptDefinition $source)) 'Diff does not reconstruct formatted code'
}
Invoke-Case 'PowerShell error stream can be redirected separately' {
    $missing = [IO.Path]::Combine($work, 'stderr', 'missing.ps1')
    $errorFile = [IO.Path]::Combine($work, 'stderr', 'errors.txt')
    $entry = New-Source 'stderr/run.ps1' '& $args[0] -c $args[1] 2> $args[2]; exit $LASTEXITCODE'
    $result = Invoke-Tool -Entry $entry -Arguments @($wrapper, $missing, $errorFile)
    Assert-Code $result 1
    Assert-True ($result.Out -eq '' -and $result.Err -eq '') 'Redirected diagnostic leaked'
    Assert-True ([IO.File]::ReadAllText($errorFile).Contains($missing)) 'Missing redirected diagnostic'
}
Invoke-Case 'formatter settings failure preserves source bytes' {
    $settings = New-Source 'formatter-error/custom.psd1' "@{Rules='invalid'}"
    $path = New-Source 'formatter-error/source.ps1'
    $before = Get-BytesKey $path
    $result = Invoke-Tool @('-w', '-settings', $settings, $path)
    Assert-Code $result 1
    Assert-True ($result.Err.Contains($path) -and $result.Out -eq '') 'Missing formatter error diagnostic'
    Assert-True ((Get-BytesKey $path) -ceq $before) 'Formatter error changed source'
}
Invoke-Case 'usage errors are diagnosed without stdout' {
    $first = New-Source 'usage/a.ps1'
    $second = New-Source 'usage/b.ps1'
    foreach ($arguments in @(@($first, $second), @([IO.Path]::GetDirectoryName($first)), @('-w', '-c', $first), @('-unknown'), @('-settings'), @('-exclude'))) {
        $result = Invoke-Tool $arguments
        Assert-Code $result 1
        Assert-True ($result.Err.Length -gt 0 -and $result.Out -eq '') 'Usage output streams'
    }
}
Invoke-Case 'relative paths, dot/dotdot, brackets and --' {
    $path = New-Source 'literal/[ñ space]/-file.ps1'
    $directory = [IO.Path]::GetDirectoryName($path)
    $result = Invoke-Tool -Directory $directory -Arguments @('-l', '--', '-file.ps1', './-file.ps1', '../[ñ space]/-file.ps1')
    Assert-Code $result 0
    Assert-True ($result.Out.TrimEnd() -ceq $path) 'Literal path handling'
}
Invoke-Case 'read-only and locked files remain intact; other files continue' {
    $readOnly = New-Source 'write-errors/a.ps1'
    $locked = New-Source 'write-errors/b.ps1'
    $valid = New-Source 'write-errors/c.ps1'
    $before = Get-BytesKey $readOnly
    [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
    $stream = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Invoke-Tool @('-w', $readOnly, $locked, $valid)
        Assert-Code $result 1
        Assert-True ($result.Err.Contains($readOnly) -and $result.Err.Contains($locked)) 'Missing individual error'
        Assert-True ((Get-BytesKey $readOnly) -ceq $before) 'Read-only file changed'
        Assert-True ([IO.File]::ReadAllText($valid) -ceq $formatted) 'Did not continue after write/read error'
    }
    finally { $stream.Dispose(); [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::Normal) }
}
Invoke-Case 'failed atomic replacement removes temporary and preserves original' {
    $path = New-Source 'replace-error/source.ps1'
    $before = Get-BytesKey $path
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $result = Invoke-Tool @('-w', $path)
        Assert-Code $result 1
        Assert-True ($result.Err.Contains($path) -and $result.Out -eq '') 'Missing replacement error diagnostic'
        Assert-True ((Get-BytesKey $path) -ceq $before) 'Replacement failure changed original'
        Assert-True (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($path)) -Force -Filter '.psfmt-*.tmp').Count -eq 0) 'Replacement leaked temporary'
    }
    finally { $stream.Dispose() }
}
Invoke-Case 'pipeline cancellation before commit leaves whole source' {
    $path = New-Source 'cancellation/source.ps1' (("`$x=1`n") * 20000)
    $before = Get-BytesKey $path
    $pipeline = [PowerShell]::Create()
    try {
        $null = $pipeline.AddCommand($wrapper).AddArgument('-w').AddArgument($path)
        $null = $pipeline.BeginInvoke()
        [Threading.Thread]::Sleep(200)
        $pipeline.Stop()
        Assert-True ($pipeline.InvocationStateInfo.State -eq 'Stopped') 'Cancellation did not stop pipeline'
        Assert-True ((Get-BytesKey $path) -ceq $before) 'Cancellation changed source before commit'
        Assert-True (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($path)) -Force -Filter '.psfmt-*.tmp').Count -eq 0) 'Cancellation leaked temporary'
    }
    finally { $pipeline.Dispose() }
}
Invoke-Case 'unsupported encoding and mixed newlines do not change bytes' {
    $paths = @(
        (New-Source 'unsupported/mixed.ps1' "`$x=1`r`n`$y=2`n"),
        (New-Source 'unsupported/cr.ps1' "`$x=1`r`$y=2"),
        (New-Source -RelativePath 'unsupported/utf32.ps1' -Text $sample -Encoding ([Text.UTF32Encoding]::new($false, $true, $true))),
        (New-Source -RelativePath 'unsupported/no-bom-utf16.ps1' -Text $sample -Encoding ([Text.UnicodeEncoding]::new($false, $false, $true)))
    )
    $invalidUtf8 = New-Source 'unsupported/invalid-utf8.ps1'
    [IO.File]::WriteAllBytes($invalidUtf8, [byte[]] @(255, 255, 255))
    $paths += $invalidUtf8
    $before = @($paths | ForEach-Object { Get-BytesKey $_ })
    $result = Invoke-Tool (@('-w') + $paths)
    Assert-Code $result 1
    for ($index = 0; $index -lt $paths.Count; $index++) {
        Assert-True ((Get-BytesKey $paths[$index]) -ceq $before[$index] -and $result.Err.Contains($paths[$index])) 'Encoding rejection failed'
    }
}
Invoke-Case 'junction cycle, reparse entry, explicit link and ancestor are skipped' {
    if (-not $IsWindows) { $skipped.Add('Windows junctions (not Windows)'); return }
    $target = New-Source 'links/target/invalid.ps1' 'function Invalid {'
    $root = [IO.Path]::Combine($work, 'links', 'root')
    $null = [IO.Directory]::CreateDirectory($root)
    $link = [IO.Path]::Combine($root, 'junction')
    $cycle = [IO.Path]::Combine($root, 'cycle')
    $null = New-Item -ItemType Junction -Path $link -Target ([IO.Path]::GetDirectoryName($target))
    $null = New-Item -ItemType Junction -Path $cycle -Target $root
    try {
        Assert-True (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Not a real reparse point'
        Assert-Code (Invoke-Tool @('-c', $root)) 0
        Assert-Code (Invoke-Tool @('-w', $link)) 0
        $result = Invoke-Tool @('-w', [IO.Path]::Combine($link, 'invalid.ps1'))
        Assert-Code $result 0
        Assert-True ($result.Err.Contains('reparse') -and $result.Out -eq '') 'Explicit reparse path not diagnosed'
        Assert-True ([IO.File]::ReadAllText($target) -ceq 'function Invalid {') 'Traversed link'
    }
    finally { [IO.Directory]::Delete($link); [IO.Directory]::Delete($cycle) }
}
Invoke-Case 'symbolic links are skipped when the OS permits their creation' {
    $target = New-Source 'symlinks/target.ps1' 'function Invalid {'
    $root = [IO.Path]::Combine($work, 'symlinks', 'root')
    $null = [IO.Directory]::CreateDirectory($root)
    $link = [IO.Path]::Combine($root, 'link.ps1')
    try { $null = [IO.File]::CreateSymbolicLink($link, $target) }
    catch { $skipped.Add('Symbolic-link creation is not permitted: ' + $_.Exception.Message); return }
    try { Assert-Code (Invoke-Tool @('-c', $root)) 0 } finally { [IO.File]::Delete($link) }
}
Invoke-Case 'automatic installation is scoped and failures are clear (mocked, no install)' {
    $entry = New-Source 'dependency/run.ps1' @'
function Get-Module { param([switch] $ListAvailable, [string] $Name); return @() }
function Install-Module {
    param([string] $Name, [string] $Scope, [string] $Repository, [switch] $Force, [switch] $Confirm)
    if ($Name -ne 'PSScriptAnalyzer' -or $Scope -ne 'CurrentUser' -or $Repository -ne 'PSGallery') { throw 'Incorrect installation arguments' }
    if ($env:PSFMT_TEST_FAIL -eq '1') { throw 'Simulated gallery failure' }
    Write-Warning 'Simulated installation notice'
}
& $args[0] @($args | Select-Object -Skip 1)
exit $LASTEXITCODE
'@
    $path = New-Source 'dependency/input.ps1'
    $result = Invoke-Tool -Entry $entry -Arguments @($wrapper, $path)
    Assert-Code $result 0
    Assert-True ($result.Out -ceq ($formatted + [Environment]::NewLine) -and $result.Err.Contains('Simulated installation notice')) 'Installation polluted stdout'
    $env:PSFMT_TEST_FAIL = '1'
    try {
        $result = Invoke-Tool -Entry $entry -Arguments @($wrapper, $path)
        Assert-Code $result 1
        Assert-True ($result.Out -eq '' -and $result.Err.Contains('Install-Module PSScriptAnalyzer -Scope CurrentUser')) 'Installation error lacks recovery command'
    }
    finally { $env:PSFMT_TEST_FAIL = $null }
}
Invoke-Case 'whole directory default selection and idempotence' {
    $first = New-Source 'idempotent/one.ps1'
    $second = New-Source 'idempotent/deep/two.psm1'
    $directory = [IO.Path]::GetDirectoryName($first)
    Assert-Code (Invoke-Tool -Directory $directory -Arguments @('-w', '.')) 0
    Assert-Code (Invoke-Tool -Directory $directory -Arguments @('-c', '.')) 0
    $before = @((Get-BytesKey $first), (Get-BytesKey $second), [IO.File]::GetLastWriteTimeUtc($first), [IO.File]::GetLastWriteTimeUtc($second))
    Assert-Code (Invoke-Tool -Directory $directory -Arguments @('-w')) 0
    Assert-True ((Get-BytesKey $first) -ceq $before[0] -and (Get-BytesKey $second) -ceq $before[1]) 'Second write changed bytes'
    Assert-True ([IO.File]::GetLastWriteTimeUtc($first) -eq $before[2] -and [IO.File]::GetLastWriteTimeUtc($second) -eq $before[3]) 'Second write changed timestamps'
}
Invoke-Case 'no abandoned atomic-write temporary files' {
    Assert-True (@(Get-ChildItem -LiteralPath $work -Recurse -Force -Filter '.psfmt-*.tmp').Count -eq 0) 'Temporary file leak'
}
Invoke-Case 'PSScriptAnalyzer static analysis' {
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $wrapper)
    Assert-True ($diagnostics.Count -eq 0) ($diagnostics | Out-String)
}

$report = [pscustomobject]@{
    PowerShell       = $PSVersionTable.PSVersion.ToString()
    PSScriptAnalyzer = (Get-Module PSScriptAnalyzer).Version.ToString()
    Passed           = $passed.Count
    Failed           = @($failed)
    Skipped          = @($skipped)
    Cases            = @($passed)
    FixtureDirectory = [IO.Path]::Combine($PSScriptRoot, 'vendor', 'work', [IO.Path]::GetFileName($work))
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, 'results.json')) -Encoding utf8
Write-Output "RESULT: $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped"
foreach ($item in $skipped) { Write-Output "SKIP $item" }
# Retain evidence, but move it into ignored vendor; no traversal or deletion
# of junction targets is needed. All generated paths remain in test-format.
$archive = [IO.Path]::Combine($PSScriptRoot, 'vendor', 'work', [IO.Path]::GetFileName($work))
if ([IO.Directory]::Exists($archive)) { [IO.Directory]::Delete($archive) }
[IO.Directory]::Move($work, $archive)
if ($failed.Count -gt 0) { exit 1 }
exit 0
