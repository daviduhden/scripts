#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/clang-tidy-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# clang-tidy-all.sh
# - Recursively finds all C/C++ source files under ROOT_DIR
#   (default: current directory excluding .git) and runs
#   clang-tidy.
# - C files run with -std=c23; C++ files run with -std=c++23.
# - Every invocation uses the bundled security-focused configuration
#   (tests-format/clang-tidy, installed as ${BINDIR}/clang-tidy-all.yaml),
#   ignoring project-local .clang-tidy files. The configuration is based on
#   knfmt's .clang-tidy and extended for maximum safety.
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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

run_clang_tidy_all() {

	ROOT_DIR=${1:-}
	[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
	[ -n "$ROOT_DIR" ] || usage
	[ -d "$ROOT_DIR" ] || {
		printf '%s\n' "[ERROR] ROOT_DIR is not a directory: $ROOT_DIR" >&2
		exit 2
	}
	ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)
	SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
	CONFIG_FILE="$SCRIPT_DIR/clang-tidy-all.yaml"
	if [ "${0##*/}" = clang-tidy-all.sh ]; then
		CONFIG_FILE="$SCRIPT_DIR/clang-tidy"
	fi

	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	if [ "$OS_NAME" = "OpenBSD" ]; then
		printf '%s\n' "[INFO] OpenBSD detected: install clang-tools-extra"
	fi

	if ! command -v clang-tidy >/dev/null 2>&1; then
		if [ "$OS_NAME" = "OpenBSD" ]; then
			printf '%s\n' \
				"[INFO] clang-tidy not found" \
				" (install clang-tools-extra);" \
				" skipping clang-tidy checks"
		else
			printf '%s\n' \
				"[INFO] clang-tidy not found in PATH;" \
				" skipping clang-tidy checks"
		fi
		exit 0
	fi

	[ -r "$CONFIG_FILE" ] || {
		printf '%s\n' \
			"[ERROR] Missing bundled clang-tidy configuration: $CONFIG_FILE" >&2
		exit 1
	}
	# Validate the configuration before scanning any source file.
	clang-tidy "--config-file=$CONFIG_FILE" --dump-config >/dev/null
	printf '%s\n' "[INFO] Using bundled configuration: $CONFIG_FILE"

	# Prune .git and run clang-tidy safely via find
	if ! find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f \
		\( -name "*.c" -o -name "*.h" -o -name "*.cc" \
		-o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" \
		-o -name "*.hpp" -o -name "*.hxx" \) \
		-print | sed -n '1p' | grep -q .; then
		printf '%s\n' "[INFO] No C/C++ source files found under: $ROOT_DIR"
		exit 0
	fi

	TMP_FAILS="${TMPDIR:-/tmp}/clang-tidy-all-fails-$$.txt"
	trap 'rm -f "$TMP_FAILS"' EXIT HUP INT TERM
	: >"$TMP_FAILS"

	printf '%s\n' "[INFO] Running clang-tidy on C/C++ sources..."
	find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f \
		\( -name "*.c" -o -name "*.h" -o -name "*.cc" \
		-o -name "*.cpp" -o -name "*.cxx" -o -name "*.hh" \
		-o -name "*.hpp" -o -name "*.hxx" \) \
		-print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			case "$f" in
			*.c | *.h)
				if [ -n "${CLANG_TIDY_BUILD_DIR:-}" ]; then
					clang-tidy "--config-file=$CONFIG_FILE" \
						-p "$CLANG_TIDY_BUILD_DIR" \
						--extra-arg=-std=c23 "$f" ||
						printf '%s\n' "$f" >>"$TMP_FAILS"
				else
					clang-tidy "--config-file=$CONFIG_FILE" \
						--extra-arg=-std=c23 "$f" ||
						printf '%s\n' "$f" >>"$TMP_FAILS"
				fi
				;;
			*)
				if [ -n "${CLANG_TIDY_BUILD_DIR:-}" ]; then
					clang-tidy "--config-file=$CONFIG_FILE" \
						-p "$CLANG_TIDY_BUILD_DIR" \
						--extra-arg=-std=c++23 "$f" ||
						printf '%s\n' "$f" >>"$TMP_FAILS"
				else
					clang-tidy "--config-file=$CONFIG_FILE" \
						--extra-arg=-std=c++23 "$f" ||
						printf '%s\n' "$f" >>"$TMP_FAILS"
				fi
				;;
			esac
		done

	if [ -s "$TMP_FAILS" ]; then
		printf '%s\n' "[ERROR] clang-tidy reported findings in:"
		sed 's/^/  - /' "$TMP_FAILS"
		exit 1
	fi
	printf '%s\n' "[INFO] clang-tidy completed"
	exit 0
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd dirname
	run_clang_tidy_all "$@"
}

main "$@"
