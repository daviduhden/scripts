# Validation, formatting, and regression tools

Most tools use POSIX `sh`; Perl regression tests require Perl. Run them from
the repository root. Optional analyzers and formatters are discovered through
PATH. Some validators rewrite formatting when a formatter is available, so
review resulting changes. The Windows installer validator runs natively in
Command Prompt without a POSIX shell or Make.

| Script | Purpose and interface |
| --- | --- |
| [clang-format-all.sh](clang-format-all.sh) | Formats C/C++ recursively under `[ROOT_DIR]`, preferring clang-format for modern C standards and knfmt otherwise. `C_FORMAT_STANDARD` overrides detection. Forces the bundled clang-format style when using clang-format. |
| [clang-tidy-all.sh](clang-tidy-all.sh) | Runs clang-tidy on C/C++ under `[ROOT_DIR]` with C23/C++23 defaults and the bundled security-focused configuration. `CLANG_TIDY_BUILD_DIR` supplies a compilation database directory. |
| [fourmolu-all.sh](fourmolu-all.sh) | Formats Haskell `.hs`, `.hsig`, and `.hs-boot` files under `[ROOT_DIR]` using the bundled Fourmolu configuration. |
| [fix-permissions.sh](fix-permissions.sh) | Classifies file contents and normalizes modes. `--check` is read-only; `--dry-run` previews and `--verbose` explains decisions. |
| [install-knfmt-linux.sh](install-knfmt-linux.sh) | Builds and installs knfmt on Linux with optional `[PREFIX]` (default `/usr/local`). |
| [validate-correctness.sh](validate-correctness.sh) | Audits shell semantics, command portability, unsafe operations, and platform assumptions. Supports target selection, strict checks, and text/JSON output. |
| [validate-make.sh](validate-make.sh) | Checks Makefile syntax and formatting under `[ROOT_DIR]` using GNU Make (`gmake`) and `makefmt`. |
| [validate-manpages.sh](validate-manpages.sh) | Runs `mandoc` lint on manual pages under `[ROOT_DIR]`, treating warnings as errors. |
| [validate-perl.sh](validate-perl.sh) | Checks Perl syntax and applies available Perl linting/formatting under `[ROOT_DIR]`. |
| [validate-shell.sh](validate-shell.sh) | Checks shell syntax and applies available shell analysis/formatting under `[ROOT_DIR]`. |
| [validate-windows-installer.bat](validate-windows-installer.bat) | Statically checks installer/launcher requirements, program manifests, and CRLF endings. Accepts optional `[ROOT_DIR]`. |
| [test-fix-permissions.sh](test-fix-permissions.sh) | Tests permission classification and check/preview/application behavior in temporary trees. |
| [test-normalize-files.pl](test-normalize-files.pl) | Tests filename normalization, collisions, encodings, line endings, binary safety, links, and idempotence. |
| [test-ssh-menu.pl](test-ssh-menu.pl) | Tests plain, hashed, and marker host-entry handling without opening a real SSH connection. |
| [test-validate-correctness.sh](test-validate-correctness.sh) | Tests platform-specific audit findings with generated scratch scripts. |

For tools accepting `[ROOT_DIR]`, the default is the current directory.
Examples:

```sh
sh tests-format/validate-shell.sh .
sh tests-format/validate-correctness.sh --target all .
sh tests-format/fix-permissions.sh --check .
perl tests-format/test-normalize-files.pl
```

`make test` runs the repository's configured validation and regression targets;
it does not run every script in this directory. See the root
[README](../README.md) and [Makefile](../Makefile) for the exact sequence.
`make install-tests-format` installs the tools selected by the Makefile,
removing `.sh` from shell command names.

Supporting files:

- [clang-format](clang-format): shared LLVM style, installed as `clang-format-all.yaml`.
- [clang-tidy](clang-tidy): security-focused clang-tidy configuration based on knfmt's, installed as `clang-tidy-all.yaml`.
- [fourmolu-all.yaml](fourmolu-all.yaml): shared Haskell formatting settings.
- [openbsd-tools.txt](openbsd-tools.txt): command allowlist for OpenBSD auditing.

PowerShell formatting and its tests are documented separately in
[../windows/test-format](../windows/test-format/README.md).
