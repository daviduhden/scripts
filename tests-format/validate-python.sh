#!/bin/sh
set -eu

# Keep the original streams on descriptors 3 and 4. The log is retained for
# inspection; temporary result lists are removed on exit or signal.
exec 3>&1 4>&2
TMPDIR_BASE=${TMPDIR:-/tmp}
TMPLOG=$(mktemp "$TMPDIR_BASE/validate-python-XXXXXX.log")
TMP_FAILS=$(mktemp "$TMPDIR_BASE/validate-python-fails-XXXXXX")
UNFMT=$(mktemp "$TMPDIR_BASE/unformatted-python-XXXXXX")
trap 'rm -f "$TMP_FAILS" "$UNFMT"' EXIT HUP INT TERM
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-python.sh
# - Recursively checks Python files under ROOT_DIR (default: current directory)
#   with Ruff formatting and lint checks, excluding .git directories.
# - Ruff formatting is applied in place; changed files make validation fail
#   so the resulting diff can be reviewed before validation is rerun.
# - Usage: ./validate-python.sh [ROOT_DIR]
# - Requires: find, sed, grep and ruff in PATH when Python files are present.
# See the LICENSE file at the top of this project tree for copyright and
# license details.

usage() {
	printf '%s\n' "Usage: $0 [ROOT_DIR]" >&2
	exit 2
}

ROOT_DIR=${1:-.}
[ "$#" -le 1 ] || usage
[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
[ -d "$ROOT_DIR" ] || {
	printf '[ERROR] ROOT_DIR is not a directory: %s\n' "$ROOT_DIR" >&2
	exit 2
}
ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)

command -v find >/dev/null 2>&1 || {
	printf '%s\n' '[ERROR] find not found in PATH' >&2
	exit 1
}

# No Python source means Ruff is unnecessary, which keeps this validator
# usable in repositories that only use the shared test/format tools.
if ! find "$ROOT_DIR" \
	\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
	-prune -o -type f -name '*.py' -print |
	sed -n '1p' | grep -q .; then
	printf '[INFO] No Python files found under: %s\n' "$ROOT_DIR"
	exit 0
fi

command -v ruff >/dev/null 2>&1 || {
	printf '%s\n' '[ERROR] Python files found but ruff not found in PATH' >&2
	exit 1
}

note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

printf '%s\n' '[INFO] Checking Python formatting with Ruff...'
# The find loop runs in a subshell; save the list so formatting can happen in
# a second pass and every changed file can be recorded in TMP_FAILS.
find "$ROOT_DIR" \
	\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
	-prune -o -type f -name '*.py' -print |
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if ! ruff format --check --quiet "$file" >/dev/null 2>&1; then
			printf '%s\n' "$file"
		fi
	done >"$UNFMT" || true

if [ -s "$UNFMT" ]; then
	printf '%s\n' '[INFO] Ruff will format the following files:'
	sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'
	# Reformatting is successful work, but still an issue for this validation
	# run. Record failures as well so they are shown in the final summary.
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if ruff format "$file"; then
			note_fail "$file"
		else
			printf '[ERROR] Ruff formatting failed for: %s\n' "$file" >&2
			note_fail "$file"
		fi
	done <"$UNFMT"
else
	printf '%s\n' '[INFO] All Python files already formatted'
fi

printf '%s\n' '[INFO] Running Ruff lint checks...'
# Run files individually so .git pruning and per-file failure reporting are
# consistent with the formatter pass.
find "$ROOT_DIR" \
	\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
	-prune -o -type f -name '*.py' -print |
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if ! ruff check "$file"; then
			note_fail "$file"
		fi
	done

issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
if [ "${issues:-0}" -ne 0 ]; then
	printf '[INFO] Completed with %s issue(s) (format changes or Ruff lint errors)\n' "$issues"
	printf '%s\n' '[INFO] Affected files (unique, first 200):'
	sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
	exit 2
fi

printf '%s\n' '[INFO] Python checks passed'
