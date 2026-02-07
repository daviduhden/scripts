#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-manpages-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-manpages.sh
# - Recursively finds all man pages under ROOT_DIR (default: current directory
#   excluding .git) and runs mandoc lint on them, treating warnings as errors.
# - Usage: ./validate-manpages.sh [ROOT_DIR]
# - Requires: mandoc in PATH
#
# Note: mandoc is a BSD tool; on Linux, install it via your package manager (e.g., apt, dnf).
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
if [ "$OS_NAME" = "OpenBSD" ]; then
	printf '%s\n' "[INFO] OpenBSD detected: mandoc is in base"
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMP_FAILS="$TMPDIR_BASE/validate-manpages-fails-$$.txt"
trap 'rm -f "$TMP_FAILS"' EXIT

if ! command -v mandoc >/dev/null 2>&1; then
	printf '%s\n' "[ERROR] mandoc not found in PATH" >&2
	exit 1
fi

# Find man pages and run mandoc lint.
# - Prune .git to avoid scanning vendored stuff.
# - Use -exec ... {} + instead of xargs (portable + safe with spaces/newlines).
# - Match common man section suffixes: .1 .. .9 and variants like .1m, .3p, etc.
if ! find "$ROOT_DIR" \
	\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o \
	-type f \( \
	-name '*.[1-9]' \
	-o -name '*.[1-9][A-Za-z]' \
	-o -name '*.[1-9][A-Za-z][A-Za-z]' \
	\) -print | sed -n '1p' | grep -q .; then
	printf '%s\n' "[INFO] No man pages found under: $ROOT_DIR"
	exit 0
fi

printf '%s\n' "[INFO] Running mandoc lint (treat warnings as errors)..."
find "$ROOT_DIR" \
	\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o \
	-type f \( \
	-name '*.[1-9]' \
	-o -name '*.[1-9][A-Za-z]' \
	-o -name '*.[1-9][A-Za-z][A-Za-z]' \
	\) -print | while IFS= read -r f; do
	[ -n "$f" ] || continue
	mandoc -Tlint -Werror "$f"
done

printf '%s\n' "[INFO] mandoc lint passed"
exit 0
