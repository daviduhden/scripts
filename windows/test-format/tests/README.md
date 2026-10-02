# psfmt regression tests

[run-tests.ps1](run-tests.ps1) exercises the formatter in
[../psfmt.ps1](../psfmt.ps1). It requires PowerShell 7 and an installed
PSScriptAnalyzer module. It uses PowerShell and .NET directly rather than Pester.

From the repository root:

```powershell
pwsh -NoProfile -File .\windows\test-format\tests\run-tests.ps1
```

Cases cover help/version behavior, output and redirection, encodings and line
endings, syntax failures, exclusions, literal paths, reparse points, atomic
writes, cancellation, idempotence, and static analysis. Formatting cases use
the real module; dependency installation branches use controlled simulations.
Symbolic link tests may be skipped when Windows does not grant the required
privilege. Junction tests are independent.

The runner creates fixtures within this directory and archives them under
`vendor/work`. It writes `results.json` with passed, failed, and skipped cases,
and exits with code 1 when a case fails. `self-check.json` is reserved for
additional verification results; the runner does not generate that file.

Generated `work/`, `vendor/`, `results.json`, and `self-check.json` are excluded
by the repository's root `.gitignore`. Keep the test runner and this README
in version control; generated data and reports are recreated locally as needed.
