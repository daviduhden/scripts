#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/clang-tidy-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# clang-tidy-all.sh
# - Recursively finds all C/C++ source files under ROOT_DIR (default: current directory
#   excluding .git) and runs clang-tidy with C23 mode.
# - Usage: ./clang-tidy-all.sh [ROOT_DIR]
# - Optional: set CLANG_TIDY_BUILD_DIR to pass -p <build-dir>
# - Requires: clang-tidy in PATH
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
	printf '%s\n' "[INFO] OpenBSD detected: install clang-tools-extra"
fi

if ! command -v clang-tidy >/dev/null 2>&1; then
	if [ "$OS_NAME" = "OpenBSD" ]; then
		printf '%s\n' "[ERROR] clang-tidy not found; install clang-tools-extra" >&2
	else
		printf '%s\n' "[ERROR] clang-tidy not found in PATH" >&2
	fi
	exit 1
fi

set -- --extra-arg=-std=c23
if [ -n "${CLANG_TIDY_BUILD_DIR:-}" ]; then
	set -- "$@" -p "$CLANG_TIDY_BUILD_DIR"
fi

# Prune .git and run clang-tidy safely via find
if ! find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" -o -name "*.hxx" \) -print | sed -n '1p' | grep -q .; then
	printf '%s\n' "[INFO] No C/C++ source files found under: $ROOT_DIR"
	exit 0
fi

printf '%s\n' "[INFO] Running clang-tidy (C23)..."
find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" -o -name "*.hxx" \) -print |
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		clang-tidy "$@" "$f"
	done
printf '%s\n' "[INFO] clang-tidy completed"
exit 0
