#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-make-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
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
	printf '%s\n' "[ERROR] ROOT_DIR is not a directory: $ROOT_DIR" >&2
	exit 2
}

OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
IS_OPENBSD=0
if [ "$OS_NAME" = "OpenBSD" ]; then
	IS_OPENBSD=1
	printf '%s\n' "[INFO] OpenBSD detected: checkmake and mbake are not ported"
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMP_FAILS="$TMPDIR_BASE/validate-make-fails-$$.txt"
trap 'rm -f "$TMP_FAILS"' EXIT

note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

printf '%s\n' "[INFO] Formatting Makefiles with mbake..."
if [ "$IS_OPENBSD" -eq 1 ]; then
	printf '%s\n' "[INFO] OpenBSD: skipping mbake"
elif command -v mbake >/dev/null 2>&1; then
	UNFMT="$TMPDIR_BASE/unformatted-make-$$.txt"

	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name 'Makefile' -o -name 'makefile' -o -name 'GNUmakefile' -o -name '*.mk' \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! mbake format --check "$f" >/dev/null 2>&1; then
				printf "%s\n" "$f"
			fi
		done >"$UNFMT" || true

	if [ -s "$UNFMT" ]; then
		printf '%s\n' "[INFO] mbake will format the following files:"
		sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if mbake format "$file" >/dev/null 2>&1; then
				note_fail "$file"
			else
				printf '%s\n' "[WARN] mbake failed for: $file" 1>&2
				note_fail "$file"
			fi
		done <"$UNFMT"
	else
		printf '%s\n' "[INFO] All Makefiles already formatted"
	fi

	rm -f "$UNFMT"
else
	printf '%s\n' "[INFO] mbake not installed; skipping Makefile formatting"
fi

if [ "$IS_OPENBSD" -eq 1 ]; then
	printf '%s\n' "[INFO] OpenBSD: skipping checkmake"
elif command -v checkmake >/dev/null 2>&1; then
	printf '%s\n' "[INFO] Running checkmake (Makefile linter)..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name 'Makefile' -o -name 'makefile' -o -name 'GNUmakefile' -o -name '*.mk' \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! checkmake "$f" >/dev/null 2>&1; then
				printf '%s\n' "[WARN] checkmake found issues in: $f" 1>&2
			fi
		done || true
else
	printf '%s\n' "[INFO] checkmake not installed; skipping Makefile lint"
fi

# Run bmake/make dry-run to ensure BSD make compatibility
MAKE_CMD="bmake"
if [ "$IS_OPENBSD" -eq 1 ] && ! command -v bmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
	MAKE_CMD="make"
fi

if command -v "$MAKE_CMD" >/dev/null 2>&1; then
	printf '%s\n' "[INFO] Running $MAKE_CMD -n -f (bsdmake dry-run)..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name 'Makefile' -o -name 'makefile' -o -name 'GNUmakefile' -o -name '*.mk' \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! "$MAKE_CMD" -n -f "$f" >/dev/null 2>&1; then
				printf '%s\n' "[WARN] $MAKE_CMD -n -f failed on: $f" 1>&2
				printf "%s\n" "$f"
			fi
		done | while IFS= read -r bad; do
		[ -n "$bad" ] && note_fail "$bad"
	done || true
else
	printf '%s\n' "[INFO] bmake/make not installed; skipping dry-run"
fi

issues=0
if [ -f "$TMP_FAILS" ]; then
	issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
fi

if [ "${issues:-0}" -ne 0 ]; then
	printf '%s\n' "[INFO] Completed with $issues issue(s) (format changes and/or errors)"
	printf '%s\n' "[INFO] Affected files (unique, first 200):"
	sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
	exit 2
fi

printf '%s\n' "[INFO] Makefile checks passed"
exit 0
