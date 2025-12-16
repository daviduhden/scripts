#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-make-$$.log"
printf '[test] Logging to: %s\n' "$TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-make.sh
# - Recursively finds all Makefiles under ROOT_DIR (default: current directory)
#   and checks formatting with makefmt and Makefile syntax.
# - Usage: ./validate-make.sh [ROOT_DIR]
# - Requires: makefmt, gmake in PATH
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [ROOT_DIR]" >&2
	exit 2
}

ROOT_DIR=${1:-}
[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
[ -n "$ROOT_DIR" ] || usage
[ -d "$ROOT_DIR" ] || {
	printf '%s\n' "ERROR: ROOT_DIR is not a directory: $ROOT_DIR" >&2
	exit 2
}

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMP_FAILS="$TMPDIR_BASE/validate-make-fails-$$.txt"
trap 'rm -f "$TMP_FAILS"' EXIT

note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

echo "[test] Formatting Makefiles with mbake..."
if command -v mbake >/dev/null 2>&1; then
	UNFMT="$TMPDIR_BASE/unformatted-make-$$.txt"

	# shellcheck disable=SC3045
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name 'Makefile' -o -name 'makefile' -o -name 'GNUmakefile' -o -name '*.mk' \) -print0 |
		while IFS= read -r -d '' f; do
			if ! mbake format --check "$f" >/dev/null 2>&1; then
				echo "$f"
			fi
		done >"$UNFMT" || true

	if [ -s "$UNFMT" ]; then
		echo "[test] mbake will format the following files:"
		sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if mbake format "$file" >/dev/null 2>&1; then
				note_fail "$file"
			else
				echo "[WARN] mbake failed for: $file" 1>&2
				note_fail "$file"
			fi
		done <"$UNFMT"
	else
		echo "[test] All Makefiles already formatted"
	fi

	rm -f "$UNFMT"
else
	echo "[test] mbake not installed; skipping Makefile formatting"
fi

if command -v checkmake >/dev/null 2>&1; then
	echo "[test] Running checkmake (Makefile linter)..."

	# shellcheck disable=SC3045
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name 'Makefile' -o -name 'makefile' -o -name 'GNUmakefile' -o -name '*.mk' \) -print0 |
		while IFS= read -r -d '' f; do
			if ! checkmake "$f" >/dev/null 2>&1; then
				echo "[WARN] checkmake found issues in: $f" 1>&2
			fi
		done || true
else
	echo "[test] checkmake not installed; skipping Makefile lint"
fi

issues=0
if [ -f "$TMP_FAILS" ]; then
	issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
fi

if [ "${issues:-0}" -ne 0 ]; then
	echo "[test] Completed with $issues issue(s) (format changes and/or errors)"
	echo "[test] Affected files (unique, first 200):"
	sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
	exit 2
fi

echo "[test] Makefile checks passed"
exit 0
