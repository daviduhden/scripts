# psfmt 0.1.0

A PowerShell 7 wrapper for Windows 10/11 using
`PSScriptAnalyzer\Invoke-Formatter` as its only formatting engine. It requires
no Git, Make, POSIX shell, or administrator privileges. The
[Windows installer](../install-windows.bat) installs it as `psfmt`;
PowerShell 7 must be installed separately.

From this directory:

```powershell
.\psfmt.ps1 -w .
.\psfmt.ps1 -c .
.\psfmt.ps1 script.ps1 > formatted.ps1
.\psfmt.ps1 -w src tests
.\psfmt.ps1 -d .
.\psfmt.ps1 -l -exclude '*.generated.ps1' -exclude build .
.\psfmt.ps1 -w -settings .\PSScriptAnalyzerSettings.psd1 .
```

If the module is missing, the script attempts to install it from PSGallery with
`Install-Module PSScriptAnalyzer -Scope CurrentUser -Repository PSGallery
-Force -Confirm:$false`. It does not update an existing module or change
repository trust settings or the execution policy. Installation failures return
code 1 and display the manual installation command. Help and version commands
do not require the module. Automatic installation is the explicitly requested
exception to avoiding configuration changes and uses the user's module
directory rather than this project.

## Interface

`psfmt.ps1 [options] [file|directory ...]`

| Option | Behavior |
| --- | --- |
| No mode | Requires exactly one file and sends its formatted code to the output pipeline. |
| `-w` | Replaces only files whose contents change. |
| `-d` | Prints a unified diff without writing files. |
| `-l` | Prints only absolute paths of files that would change. |
| `-c` | Checks formatting silently for CI. |
| `-r` | Explicit recursion; directories are already recursive by default. |
| `-settings file.psd1` | Validates settings and passes them to Invoke-Formatter; otherwise uses its defaults. |
| `-exclude pattern` | Excludes names or paths; may be repeated. |
| `-h`, `-help` | Displays syntax, options, exit codes, and examples. |
| `-version` | Displays `psfmt 0.1.0`. |
| `--` | Ends option parsing for paths starting with a hyphen. |

The `-w`, `-d`, `-l`, and `-c` modes are mutually exclusive. With a mode and no
paths, the script selects `.`. Paths are literal; globs apply only to
`-exclude`. Supported extensions are `.ps1`, `.psm1`, and `.psd1`, including
hidden files and uppercase extensions. Normalized absolute paths are deduplicated
and sorted using ordinal, case-insensitive comparison on Windows.

Exclusions use case-insensitive PowerShell globs (`*`, `?`, `[abc]`) against
names, absolute paths, or paths relative to the working directory, normalized
with `/`. `*` can span `/`. Excluded directories are discarded before traversal.
`.git`, `.svn`, `.hg`, `node_modules`, `bin`, `obj`, and `vendor` are always
skipped, including when they are ancestors of explicitly selected files.
Symbolic links, junctions, and other reparse points are skipped, including
argument ancestors. An explicitly selected link produces a stderr diagnostic
rather than a formatting error.

| Exit code | Meaning |
| --- | --- |
| `0` | Success; in `-c` mode, no files need formatting. |
| `1` | Usage, dependency, discovery, read, syntax, formatting, or write error. |
| `2` | Only in `-c` mode: files need formatting and no errors occurred. |

Errors take precedence over code 2. Processing continues with other files after
an individual file error. Diagnostics, including installation messages, go to
stderr. `-w` and `-c` do not print success messages.

## Architecture and preservation

The script implements argument parsing, iterative discovery with deduplication,
byte reading, an Invoke-Formatter adapter, writing, and diff generation. It
checks syntax with the PowerShell parser before and after formatting without
executing the selected code. The diff uses common prefixes and suffixes and a
single block with up to three context lines. Memory and time requirements are
linear; it does not attempt to produce the smallest possible diff.

Writes preserve UTF-8 with or without a BOM and UTF-16 LE/BE with a BOM. Strict
decoders reject invalid characters instead of replacing them. The BOM, Unicode,
uniform LF/CRLF endings, and exact trailing newline sequence are preserved,
including the absence of a trailing newline. UTF-32, invalid bytes, NUL,
ambiguous UTF-16 without a BOM, bare CR, and mixed LF/CRLF endings are rejected
to avoid guessing encodings or changing multiline literals during conversion.

Each write creates a unique temporary file in the same directory, writes all
bytes, calls `Flush(true)`, reads it back for verification, and checks that the
original has not changed. It then uses `File.Replace`, which preserves
destination permissions on Windows and supports atomic replacement on
compatible file systems. There is no fallback that deletes the original first.
Read-only files produce an error. Already formatted files are not written and
retain their modification timestamps. `finally` attempts to remove temporary
files after an error or normal pipeline interruption.

## Tests

```powershell
.\tests\run-tests.ps1
Invoke-ScriptAnalyzer -Path .\psfmt.ps1
```

The runner uses PowerShell and .NET without Pester or additional dependencies.
Formatting cases use the actual installed module. Automatic installation
branches are simulated to avoid installing or uninstalling modules during
tests. Inputs are generated under `tests/work` and archived under
`tests/vendor/work`, excluded by the wrapper and the root `.gitignore`.
The runner writes `tests/results.json`; additional checks may be recorded in
`tests/self-check.json`. Generated data and reports are ignored and are not
included in the repository. No fixtures are created outside this directory.
Symbolic link creation is explicitly recorded as skipped if Windows does not
permit it; junctions are tested independently. See
[tests/README.md](tests/README.md) for details.

The previous validation reported **50 passed cases, 0 failures, and 1 skipped
case** on Windows 11 Pro (build 26300), PowerShell 7.6.6, and PSScriptAnalyzer
1.25.0. Symbolic link creation was skipped because Windows did not permit it;
junctions and their cycles were tested. Cancellation was checked using
`PowerShell.Stop()` before the write committed rather than a physical Ctrl+C
keystroke. Automatic installation used controlled simulations without modifying
the installed module.

That validation reported **0 diagnostics** from analysis of both the formatter
and runner. The sequence `-w .`, `-c .`, `-w .` returned **0, 0, 0** without
changing SHA-256 hashes or modification timestamps of already formatted scripts.
These are historical results; their generated reports have been removed from
the repository. This version was not tested on a second computer running
Windows 10 or with earlier PowerShell 7 versions.

## Limitations

- PowerShell output is a pipeline of strings. The host and `>` may add a trailing
  newline and choose the redirected file's encoding. Use `-w` to preserve the
  exact encoding, BOM, and trailing newline. Native wrapper output uses UTF-8
  and restores the console encoding when it finishes.
- Concurrent changes are checked immediately before replacement. There is no
  guarantee against another process changing a file or its ancestors during
  that interval; avoid editing the same tree concurrently. Hard links are not
  deduplicated by physical identity. Replacement affects the selected name
  rather than its other hard links.
- Forced process or system termination may leave a `.psfmt-*.tmp` file. Ctrl+C
  normally runs `finally`, but cleanup cannot be guaranteed if termination
  prevents it from running. The original is replaced only at the end.
- There is no global transaction: if one file fails, earlier files may already
  have been formatted. Standard input, combined modes, and shfmt parameters
  outside this interface are not supported.
- Contents and diffs are held in memory. The file system must support
  `File.Replace`; failures are reported without falling back to direct writes.
  Preservation of metadata beyond text, such as alternate data streams, is
  not guaranteed on every file system.

The settings API follows the [official Invoke-Formatter documentation](https://learn.microsoft.com/powershell/module/psscriptanalyzer/invoke-formatter).
