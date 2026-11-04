# Python to Perl migration

This repository no longer uses Python for project-maintained tools. The
migration replaced every `.py` program and Python-based test suite with Perl
under the same functional interfaces.

## Inventory and status

| Original | Replacement | Status |
| --- | --- | --- |
| `scripts/validate-agent-knowledge.py` | `scripts/validate-agent-knowledge.pl` | migrated |
| `tests/agent_knowledge_validator/test_validator.py` | `tests/agent_knowledge_validator/test_validator.pl` | migrated |
| `secureblue/arti-config.py` | `secureblue/arti-config.pl` | migrated |
| `tests/test_delivery_transactions.py` | `tests/test_delivery_transactions.pl` | migrated |
| `tests/test_release_updates.py` | `tests/test_release_updates.pl` | migrated |
| `tests/test_sync_website_filters.py` | `tests/test_sync_website_filters.pl` | migrated |
| `tests/test_tooling.py` | `tests/test_tooling.pl` | migrated |

## Removed Python tooling

- `tests-format/validate-python.sh`
- Ruff installation and Python setup in CI
- `test-python` Makefile target
- Python-specific cache files from the working tree

## Verification

- `perl -c` and `perltidy` for every new Perl program
- `prove` for every migrated suite: 46 validator contract tests and 26
  delivery/release/website/tooling tests
- `make check` and `make test`
- `make check-agent-knowledge`

## Compatibility notes

The Perl validator and tests keep the existing exit codes, text/JSON output,
environment variables, temporary-file isolation, and platform skips. TOML
parsing is deliberately limited to the configuration subset used by this
repository; unsupported TOML features fail closed with exit code 2. The
agent validator's text and JSON output were compared with the Python
implementation before its removal.

`policycoreutils-python-utils` in `secureblue/setup-clamav.bash` is the name of
a third-party RPM package, not project Python code. `tests/test_tooling.pl`
intentionally checks that no `.py` source files remain.

## Remaining limitations

- Native Windows batch/PowerShell behavior is still tested only on Windows;
  the Perl suites skip those cases elsewhere.
- The Perl test harness uses core modules and temporary trees; it does not
  reproduce Python-only `unittest` subtest labels.
- TOML coverage is the strict subset documented by `arti-config.pl` and the
  validator, not the full TOML 1.0 grammar.
