#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$previousOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Show-PsfmtHelp {
    @'
psfmt 0.1.0 - PowerShell formatting with PSScriptAnalyzer / Invoke-Formatter
Usage: psfmt.ps1 [options] [file|directory ...]

  -w                 Write changed files safely, preserving text encoding.
  -d                 Print a unified diff; do not write files.
  -l                 Print only paths of files that would change.
  -c                 Check formatting for CI; do not write files.
  -r                 Recurse (directories are recursive by default).
  -settings FILE     Pass a .psd1 settings file to Invoke-Formatter.
  -exclude PATTERN   Exclude a name or path glob; repeat to add patterns.
  -h, -help          Show this help.
  -version           Print psfmt 0.1.0.
  --                 Treat subsequent arguments as literal paths.

Choose at most one of -w, -d, -l, -c. With no mode, exactly one explicit
file is required and its formatted text is emitted to the output pipeline.
With a mode and no paths, the current directory is selected.
Supported files: .ps1, .psm1, .psd1 (including hidden files).
Ignored directories: .git, .svn, .hg, node_modules, bin, obj, vendor.
Reparse points, symlinks and junctions (including path ancestors) are skipped.
Exclusions match names, absolute paths or paths relative to the working
directory, with '/' separators. Globs are case-insensitive; '*' spans '/'.
Missing PSScriptAnalyzer is installed with Install-Module -Scope CurrentUser.

Exit codes: 0 success; 1 usage/read/parse/format/write/dependency error;
            2 files need formatting in -c mode (errors take precedence).

Examples:
  .\psfmt.ps1 script.ps1 > formatted.ps1
  .\psfmt.ps1 -w .
  .\psfmt.ps1 -w src tests
  .\psfmt.ps1 -d .
  .\psfmt.ps1 -l -exclude '*.generated.ps1' -exclude 'build' .
  .\psfmt.ps1 -c .
  .\psfmt.ps1 -w -settings .\PSScriptAnalyzerSettings.psd1 .

Writes preserve UTF-8 (with/without BOM), BOM-marked UTF-16 LE/BE,
uniform LF/CRLF and the exact trailing newline sequence. Ambiguous encodings,
mixed line endings and bare CR are rejected. Output redirection is rendered
by PowerShell; use -w to preserve the original file's byte-level metadata.
'@
}

function Write-PsfmtDiagnostic {
    param([string] $Message)
    # Continue reports on stream 2 without letting the caller's Stop preference
    # abort processing of other files; the CLI supplies the final exit code.
    Write-Error -Message "psfmt: $Message" -ErrorAction Continue
}

function Get-PsfmtOption {
    param([object[]] $Arguments)
    $paths = [Collections.Generic.List[string]]::new()
    $exclusions = [Collections.Generic.List[string]]::new()
    $mode = ''
    $settings = $null
    $literal = $false
    $help = $false
    $version = $false
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string] $Arguments[$index]
        if ($literal) { $paths.Add($argument); continue }
        switch -CaseSensitive ($argument) {
            '--' { $literal = $true }
            { $_ -in '-w', '-d', '-l', '-c' } {
                if ($mode -and $mode -ne $argument) { throw 'Choose only one of -w, -d, -l and -c.' }
                $mode = $argument
            }
            '-r' { }
            { $_ -in '-h', '-help' } { $help = $true }
            '-version' { $version = $true }
            { $_ -in '-settings', '-exclude' } {
                $index++
                if ($index -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string] $Arguments[$index])) {
                    throw "Missing value for $argument."
                }
                if ($argument -eq '-settings') {
                    if ($null -ne $settings) { throw '-settings may only be specified once.' }
                    $settings = [string] $Arguments[$index]
                }
                else {
                    $exclusions.Add([string] $Arguments[$index])
                }
            }
            default {
                if ($argument.StartsWith('-')) { throw "Unknown option: $argument. Use -- before paths starting with '-'." }
                if ([string]::IsNullOrWhiteSpace($argument)) { throw 'Empty path argument.' }
                $paths.Add($argument)
            }
        }
    }
    [pscustomobject]@{ Mode = $mode; Paths = $paths; Exclusions = $exclusions; Settings = $settings; Help = $help; Version = $version }
}

function Initialize-PsfmtEngine {
    # Redirect every non-success stream: dependency notices must not contaminate code stdout.
    if (@(Get-Module -ListAvailable -Name PSScriptAnalyzer).Count -eq 0) {
        Write-PsfmtDiagnostic 'PSScriptAnalyzer is missing; installing it for the current user.'
        try {
            $messages = @(Install-Module PSScriptAnalyzer -Scope CurrentUser -Repository PSGallery -Force -Confirm:$false 3>&1 4>&1 5>&1 6>&1)
            foreach ($message in $messages) { Write-PsfmtDiagnostic ([string] $message) }
        }
        catch {
            Write-PsfmtDiagnostic 'Run: Install-Module PSScriptAnalyzer -Scope CurrentUser'
            throw "Cannot install PSScriptAnalyzer: $($_.Exception.Message)"
        }
    }
    $messages = @(Import-Module PSScriptAnalyzer -ErrorAction Stop 3>&1 4>&1 5>&1 6>&1)
    foreach ($message in $messages) { Write-PsfmtDiagnostic ([string] $message) }
    $null = Get-Command PSScriptAnalyzer\Invoke-Formatter -ErrorAction Stop
}

function Test-PsfmtReparsePath {
    param([string] $Path)
    # Check ancestors too: a literal file argument can otherwise bypass traversal protection.
    $current = $Path
    while ($current) {
        if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $false
}

function Test-PsfmtExcluded {
    param([string] $Path, [string] $BasePath, [Collections.Generic.List[Management.Automation.WildcardPattern]] $Patterns)
    $normalized = $Path.Replace('\', '/')
    $relative = [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
    $name = [IO.Path]::GetFileName($Path)
    $parent = [string] [IO.Path]::GetDirectoryName($Path)
    $ignored = @('.git', '.svn', '.hg', 'node_modules', 'bin', 'obj', 'vendor')
    if (([IO.Directory]::Exists($Path) -and $name -in $ignored) -or
        @($parent.Replace('\', '/').Split('/') | Where-Object { $_ -in $ignored }).Count -gt 0) { return $true }
    foreach ($pattern in $Patterns) {
        if ($pattern.IsMatch($name) -or $pattern.IsMatch($normalized) -or $pattern.IsMatch($relative)) { return $true }
    }
    return $false
}

function Get-PsfmtFile {
    param([Collections.Generic.List[string]] $Paths, [string] $BasePath, [Collections.Generic.List[string]] $Exclusions)
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $files = [Collections.Generic.HashSet[string]]::new($comparer)
    $visited = [Collections.Generic.HashSet[string]]::new($comparer)
    $pending = [Collections.Generic.Queue[string]]::new()
    $patterns = [Collections.Generic.List[Management.Automation.WildcardPattern]]::new()
    foreach ($exclusion in $Exclusions) {
        $patterns.Add([Management.Automation.WildcardPattern]::new($exclusion.Replace('\', '/'), [Management.Automation.WildcardOptions]::IgnoreCase))
    }
    $failed = $false
    foreach ($inputPath in $Paths) {
        try {
            $path = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($inputPath, $BasePath))
            $attributes = [IO.File]::GetAttributes($path)
            if (Test-PsfmtReparsePath $path) { Write-PsfmtDiagnostic "Skipping reparse path: $path"; continue }
            if (Test-PsfmtExcluded -Path $path -BasePath $BasePath -Patterns $patterns) { continue }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Enqueue($path) }
            elseif ([IO.Path]::GetExtension($path) -in '.ps1', '.psm1', '.psd1') { $null = $files.Add($path) }
            else { throw 'Only .ps1, .psm1 and .psd1 files are supported.' }
        }
        catch {
            Write-PsfmtDiagnostic "${inputPath}: $($_.Exception.Message)"
            $failed = $true
        }
    }
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        if (-not $visited.Add($directory)) { continue }
        try {
            if (Test-PsfmtReparsePath $directory) { continue }
            $children = [IO.Directory]::GetFileSystemEntries($directory)
            [Array]::Sort($children, $comparer)
            foreach ($child in $children) {
                try {
                    $attributes = [IO.File]::GetAttributes($child)
                    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (Test-PsfmtExcluded -Path $child -BasePath $BasePath -Patterns $patterns) { continue }
                    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Enqueue($child) }
                    elseif ([IO.Path]::GetExtension($child) -in '.ps1', '.psm1', '.psd1') { $null = $files.Add($child) }
                }
                catch {
                    Write-PsfmtDiagnostic "${child}: $($_.Exception.Message)"
                    $failed = $true
                }
            }
        }
        catch {
            Write-PsfmtDiagnostic "${directory}: $($_.Exception.Message)"
            $failed = $true
        }
    }
    $sorted = [string[]] @($files)
    [Array]::Sort($sorted, $comparer)
    [pscustomobject]@{ Files = $sorted; Failed = $failed }
}

function Read-PsfmtText {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    # BOM-less input must be strict UTF-8. Never guess ANSI or BOM-less UTF-16.
    if ($bytes.Length -ge 4 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or
            ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255))) { throw 'UTF-32 is not supported.' }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $encoding = [Text.UTF8Encoding]::new($true, $true); $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2
    }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    if ($text.Contains([char] 0)) { throw 'NUL content or ambiguous BOM-less UTF-16 is not supported.' }
    if ($text -match '\r(?!\n)' -or ($text.Contains("`r`n") -and $text -match '(?<!\r)\n')) {
        throw 'Mixed line endings or bare CR: refusing an implicit newline conversion.'
    }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $ending = [regex]::Match($text, '(?:\r\n|\n)+\z').Value
    [pscustomobject]@{ Bytes = $bytes; Text = $text; Encoding = $encoding; Newline = $newline; Ending = $ending }
}

function Assert-PsfmtSyntax {
    param([string] $Text)
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors.Count -gt 0) {
        $first = $parseErrors[0]
        throw "PowerShell parsing failed at line $($first.Extent.StartLineNumber): $($first.Message)"
    }
}

function Format-PsfmtText {
    param([pscustomobject] $Document, [string] $Settings, [string] $Path)
    Assert-PsfmtSyntax $Document.Text
    if ($Document.Text.Length -eq 0) { return '' }
    $parameters = @{ ScriptDefinition = $Document.Text; ErrorAction = 'Stop' }
    if ($Settings) { $parameters.Settings = $Settings }
    $records = @(PSScriptAnalyzer\Invoke-Formatter @parameters 3>&1 4>&1 5>&1 6>&1)
    $strings = [Collections.Generic.List[string]]::new()
    foreach ($record in $records) {
        if ($record -is [string]) { $strings.Add($record) }
        else { Write-PsfmtDiagnostic "${Path}: $record" }
    }
    if ($strings.Count -ne 1) { throw 'Invoke-Formatter did not return exactly one string.' }
    # Restore textual metadata, not formatting rules. Uniform original EOLs also
    # keep multiline strings consistent; mixed EOLs were rejected before formatting.
    $formatted = $strings[0].Replace("`r`n", "`n").Replace("`n", $Document.Newline)
    $formatted = [regex]::Replace($formatted, '(?:\r\n|\n)+\z', '') + $Document.Ending
    Assert-PsfmtSyntax $formatted
    return $formatted
}

function Write-PsfmtAtomicFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes are explicitly selected by the CLI -w mode, not a cmdlet API.')]
    param([string] $Path, [pscustomobject] $Document, [string] $Text)
    if (Test-PsfmtReparsePath $Path) { throw 'Path became a reparse point before writing.' }
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { throw 'File is read-only.' }
    $bytes = [byte[]] ($Document.Encoding.GetPreamble() + $Document.Encoding.GetBytes($Text))
    $temporary = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Path), '.psfmt-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($temporary)) -cne [Convert]::ToBase64String($bytes)) { throw 'Temporary file verification failed.' }
        if (Test-PsfmtReparsePath $Path) { throw 'Path became a reparse point during writing.' }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne [Convert]::ToBase64String($Document.Bytes)) {
            throw 'File changed since reading; refusing to overwrite concurrent edits.'
        }
        [IO.File]::SetAttributes($temporary, $attributes)
        # Same-directory replacement is atomic on supported filesystems. No unsafe
        # delete-then-move fallback: failure leaves the original file in place.
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            try { [IO.File]::Delete($temporary) } catch { Write-PsfmtDiagnostic "${temporary}: cannot remove temporary file: $($_.Exception.Message)" }
        }
    }
}

function Write-PsfmtDiff {
    param([string] $Path, [string] $Original, [string] $Formatted)
    # One valid unified hunk spanning the changed region. Linear memory/time;
    # deliberately not a shortest-edit algorithm for large generated scripts.
    $oldLines = [Collections.Generic.List[string]]::new()
    $newLines = [Collections.Generic.List[string]]::new()
    if ($Original.Length -gt 0) { $oldLines.AddRange([string[]] $Original.Replace("`r`n", "`n").Split("`n")) }
    if ($Formatted.Length -gt 0) { $newLines.AddRange([string[]] $Formatted.Replace("`r`n", "`n").Split("`n")) }
    if ($Original.EndsWith("`n")) { $oldLines.RemoveAt($oldLines.Count - 1) }
    if ($Formatted.EndsWith("`n")) { $newLines.RemoveAt($newLines.Count - 1) }
    $prefix = 0
    while ($prefix -lt $oldLines.Count -and $prefix -lt $newLines.Count -and $oldLines[$prefix] -ceq $newLines[$prefix]) { $prefix++ }
    $suffix = 0
    while ($suffix -lt ($oldLines.Count - $prefix) -and $suffix -lt ($newLines.Count - $prefix) -and
        $oldLines[$oldLines.Count - $suffix - 1] -ceq $newLines[$newLines.Count - $suffix - 1]) { $suffix++ }
    $start = [Math]::Max(0, $prefix - 3)
    $oldEnd = [Math]::Min($oldLines.Count, $oldLines.Count - $suffix + 3)
    $newEnd = [Math]::Min($newLines.Count, $newLines.Count - $suffix + 3)
    $oldStart = if ($oldEnd -eq 0) { 0 } else { $start + 1 }
    $newStart = if ($newEnd -eq 0) { 0 } else { $start + 1 }
    "--- $Path"
    "+++ $Path"
    "@@ -$oldStart,$($oldEnd - $start) +$newStart,$($newEnd - $start) @@"
    for ($index = $start; $index -lt $prefix; $index++) { ' ' + $oldLines[$index] }
    for ($index = $prefix; $index -lt ($oldLines.Count - $suffix); $index++) {
        '-' + $oldLines[$index]
        if ($index -eq ($oldLines.Count - 1) -and -not $Original.EndsWith("`n")) { '\ No newline at end of file' }
    }
    for ($index = $prefix; $index -lt ($newLines.Count - $suffix); $index++) {
        '+' + $newLines[$index]
        if ($index -eq ($newLines.Count - 1) -and -not $Formatted.EndsWith("`n")) { '\ No newline at end of file' }
    }
    for ($index = $oldLines.Count - $suffix; $index -lt $oldEnd; $index++) {
        ' ' + $oldLines[$index]
        if ($index -eq ($oldLines.Count - 1) -and -not $Original.EndsWith("`n")) { '\ No newline at end of file' }
    }
}

try {
    $options = Get-PsfmtOption $args
    if ($options.Help) { Show-PsfmtHelp; exit 0 }
    if ($options.Version) { 'psfmt 0.1.0'; exit 0 }
    if ((Get-Location).Provider.Name -ne 'FileSystem') { throw 'The working directory must be a filesystem directory.' }
    $basePath = (Get-Location).ProviderPath
    if (-not $options.Mode) {
        if ($options.Paths.Count -ne 1) { throw 'Without -w/-d/-l/-c, select exactly one explicit file.' }
        $singlePath = [IO.Path]::GetFullPath($options.Paths[0], $basePath)
        if ([IO.Directory]::Exists($singlePath)) { throw 'Directory arguments require -w, -d, -l or -c.' }
    }
    elseif ($options.Paths.Count -eq 0) { $options.Paths.Add('.') }
    Initialize-PsfmtEngine
    $settingsPath = $null
    if ($null -ne $options.Settings) {
        $settingsPath = [IO.Path]::GetFullPath($options.Settings, $basePath)
        if ([IO.Path]::GetExtension($settingsPath) -ne '.psd1' -or -not [IO.File]::Exists($settingsPath)) { throw "Settings file does not exist or is not .psd1: $settingsPath" }
        if (Test-PsfmtReparsePath $settingsPath) { throw "Settings cannot be a reparse path: $settingsPath" }
        $null = Import-PowerShellDataFile -LiteralPath $settingsPath
    }
    $selection = Get-PsfmtFile -Paths $options.Paths -BasePath $basePath -Exclusions $options.Exclusions
    $failed = $selection.Failed
    $changed = $false
    foreach ($path in $selection.Files) {
        try {
            if (Test-PsfmtReparsePath $path) { throw 'Path became a reparse point before reading.' }
            $document = Read-PsfmtText $path
            $formatted = Format-PsfmtText -Document $document -Settings $settingsPath -Path $path
            $different = $document.Text -cne $formatted
            if ($different) { $changed = $true }
            switch ($options.Mode) {
                '-w' { if ($different) { Write-PsfmtAtomicFile -Path $path -Document $document -Text $formatted } }
                '-d' { if ($different) { Write-PsfmtDiff -Path $path -Original $document.Text -Formatted $formatted } }
                '-l' { if ($different) { $path } }
                '-c' { }
                default { Write-Output -InputObject $formatted -NoEnumerate }
            }
        }
        catch {
            Write-PsfmtDiagnostic "${path}: $($_.Exception.Message)"
            $failed = $true
        }
    }
    if ($failed) { exit 1 }
    if ($options.Mode -eq '-c' -and $changed) { exit 2 }
    exit 0
}
catch {
    Write-PsfmtDiagnostic $_.Exception.Message
    exit 1
}
finally {
    [Console]::OutputEncoding = $previousOutputEncoding
}
