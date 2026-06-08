#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/clang-format-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# clang-format-all.sh
# - Recursively finds all C/C++ source files under ROOT_DIR (default: current
#   directory excluding .git) and applies formatting.
# - Prefers knfmt when available; otherwise falls back to clang-format.
# - Usage: ./clang-format-all.sh [ROOT_DIR]
# - Requires: knfmt or clang-format in PATH
# - clang-format mode uses .clang-format in the tree
#   (-style=file with -fallback-style=none).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [ROOT_DIR]" >&2
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

run_clang_format_all() {

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

	if command -v knfmt >/dev/null 2>&1; then
		FORMATTER="knfmt"
	elif command -v clang-format >/dev/null 2>&1; then
		FORMATTER="clang-format"
	else
		if [ "$OS_NAME" = "OpenBSD" ]; then
			printf '%s\n' "[INFO] Neither knfmt nor clang-format found (install devel/knfmt or clang-tools-extra); skipping C/C++ formatting"
		else
			printf '%s\n' "[INFO] Neither knfmt nor clang-format found in PATH; skipping C/C++ formatting"
		fi
		exit 0
	fi

	if ! find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" -o -name "*.hxx" \) -print | sed -n '1p' | grep -q .; then
		printf '%s\n' "[INFO] No C/C++ source files found under: $ROOT_DIR"
		exit 0
	fi

	printf '%s\n' "[INFO] Applying C/C++ formatting with $FORMATTER..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" -o -name "*.hxx" \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if [ "$FORMATTER" = "knfmt" ]; then
				knfmt -i "$f"
			else
				clang-format -i -style=file -fallback-style=none "$f"
			fi
		done
	printf '%s\n' "[INFO] C/C++ formatting applied with $FORMATTER"
	exit 0
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	run_clang_format_all "$@"
}

main "$@"
