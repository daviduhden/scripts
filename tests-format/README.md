# Validation, formatting, and regression tools

Most tools use POSIX `sh`; Perl regression tests require Perl. Run them from
the repository root. Optional analyzers and formatters are discovered through
PATH. Validators check formatting by default. Use `--format` explicitly to rewrite
formatting, then review the resulting changes. The Windows installer validator runs natively in
Command Prompt without a POSIX shell or Make.

| Script | Purpose and interface |
| --- | --- |
| [clang-format-all.sh](clang-format-all.sh) | Formats C/C++ recursively under `[ROOT_DIR]`, preferring clang-format for modern C standards and knfmt otherwise. `C_FORMAT_STANDARD` overrides detection. Forces the bundled clang-format style when using clang-format. |
| [clang-tidy-all.sh](clang-tidy-all.sh) | Runs clang-tidy on C/C++ under `[ROOT_DIR]` with C23/C++23 defaults and the bundled security-focused configuration. `CLANG_TIDY_BUILD_DIR` supplies a compilation database directory. |
| [fourmolu-all.sh](fourmolu-all.sh) | Formats Haskell `.hs`, `.hsig`, and `.hs-boot` files under `[ROOT_DIR]` using the bundled Fourmolu configuration. |
| [fix-permissions.sh](fix-permissions.sh) | Classifies file contents and normalizes modes. `--check` is read-only and skips Git-ignored artifacts; `--dry-run` previews and `--verbose` explains decisions. |
| [install-knfmt-linux.sh](install-knfmt-linux.sh) | Builds and installs knfmt on Linux with optional `[PREFIX]` (default `/usr/local`). |
| [validate-agent-knowledge.py](../scripts/validate-agent-knowledge.py) | Requires substantive agent/skills documentation changes alongside project changes; checks instruction structure and relative Markdown links. Use `--scope range --base BASE_REF --head HEAD_REF` for pull request comparisons. Semantic relevance requires review. |
| [validate-correctness.sh](validate-correctness.sh) | Audits shell semantics, command portability, unsafe operations, and platform assumptions. Supports target selection, strict checks, and text/JSON output. |
| [validate-make.sh](validate-make.sh) | Checks GNU make formatting and lint where applicable, skips those GNU-only tools for detected BSD make syntax and include-only wrappers, and optionally runs `bmake` dry runs on trusted Makefiles with `--make-dry-run`. A build Makefile that requires an absent generated `config.mk` is reported as skipped until configuration exists. |
| [validate-manpages.sh](validate-manpages.sh) | Runs `mandoc` lint on manual pages under `[ROOT_DIR]`, treating warnings as errors; skips when `mandoc` is absent. |
| [validate-perl.sh](validate-perl.sh) | Checks Perl syntax, lint, and formatting; only `--format` rewrites files under `[ROOT_DIR]`. |
| [validate-python.sh](validate-python.sh) | Checks Python with cache-free Ruff invocations. `--format` applies formatting and clears Ruff caches; drift is reported as a validation issue. |
| [validate-shell.sh](validate-shell.sh) | Checks shell syntax, lint, and formatting; only `--format` rewrites files under `[ROOT_DIR]`. |
| [validate-windows-installer.bat](validate-windows-installer.bat) | Statically checks installer/launcher requirements, program manifests, and CRLF endings. Accepts optional `[ROOT_DIR]`. |
| [test-fix-permissions.sh](test-fix-permissions.sh) | Tests permission classification and check/preview/application behavior in temporary trees. |
| [test-normalize-files.pl](test-normalize-files.pl) | Tests filename normalization, collisions, encodings, line endings, binary safety, links, and idempotence. |
| [test-ssh-menu.pl](test-ssh-menu.pl) | Tests plain, hashed, and marker host-entry handling without opening a real SSH connection. |
| [test-validate-correctness.sh](test-validate-correctness.sh) | Tests platform-specific audit findings with generated scratch scripts. |

For tools accepting `[ROOT_DIR]`, the default is the current directory.
Validators accept `--check` (default), `--format`, and `--strict` before the
root. Strict mode fails on missing tools or unloadable Perl modules; expected
Make dialect/platform omissions remain skips. Logs include skipped-check
counts. `--check` neither rewrites sources nor creates or removes caches.
`validate-make.sh --make-dry-run` evaluates Makefiles and must only be used
on trusted trees; even `-n` can execute parse-time commands. `perl -c` also
executes compile-time blocks, so Perl sources must be trusted.

Examples:

```sh
sh tests-format/validate-shell.sh .
sh tests-format/validate-correctness.sh --target all .
sh tests-format/fix-permissions.sh --check .
perl tests-format/test-normalize-files.pl
```

Validators create private temporary logs; no `$$`-based predictable temporary
paths are used. JSON report validation uses the standalone
`../scripts/release-verify.pl json-validate` helper instead of inline Perl. Shell/Perl validators skip nested `.git` directories and
formatters clean up their failure lists.
`make check` runs validation; `make format` explicitly runs formatters.
`make test` completes validation before its regression targets, even under
parallel make,
including `validate-manpages.sh` (which skips when `mandoc` is absent); it does
not run every script in this directory. See the root [README](../README.md) and
[Makefile](../Makefile) for the exact sequence.
The regression target also runs `tests/test_sync_website_filters.py`, which
stages temporary trees through the Debian Bash and OpenBSD ksh synchronization
filters without invoking deployment side effects.
`make install-tests-format` installs the tools selected by the Makefile under
`${DESTDIR}${TESTS_FORMAT_DIR}` (default `${PREFIX}/libexec/scripts`), removing
`.sh` and `.py` from command names and `.yaml` from bundled configuration names.
Set `TESTS_FORMAT_LINKS=1` to add compatibility symlinks in `BINDIR`.

Run `make check-agent-knowledge` before completing repository changes. For CI,
use `python3 scripts/validate-agent-knowledge.py --scope range --base BASE_REF --head HEAD` after
fetching the target branch. The `.github/workflows/agent-knowledge-validation.yml` PR workflow runs this
check against the pull request base and head revisions. The check
requires a substantive, non-cosmetic change in an operational instruction file
when project files change. It validates required section/frontmatter structure
and relative Markdown links, but cannot decide whether the guidance is
semantically relevant; that still requires agent review.

`make test-tooling` runs offline temporary-tree regressions in
[../tests/test_tooling.py](../tests/test_tooling.py): check-mode immutability,
explicit formatting, strict missing-tool failures, make-execution opt-in,
installation paths containing spaces, and failure propagation. The platform
CI workflow exercises Linux checks, native Windows suites, and OpenBSD 7.8
regressions without invoking the system-changing scripts.

Supporting files:

- `clang-format.yaml`: shared LLVM style, installed as `clang-format-all`.
- `clang-tidy.yaml`: security-focused clang-tidy configuration based on knfmt, installed as `clang-tidy-all`.
- `fourmolu-all.yaml`: shared Haskell formatting settings, installed as `fourmolu-all`.
- [openbsd-tools.txt](openbsd-tools.txt): reference mapping of the optional analysis tools to their OpenBSD ports/packages (information only; not read by the validators).

PowerShell formatting and its tests are documented separately in
[../windows/test-format](../windows/test-format/README.md).
