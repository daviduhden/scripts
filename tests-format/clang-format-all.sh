#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/clang-format-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# clang-format-all.sh
# - Recursively finds all C/C++ source files under ROOT_DIR
#   (default: current directory, excluding .git directories) and applies
#   formatting.
# - Prefers clang-format for C11/C17/C23 projects, otherwise knfmt.
# - Detects literal standards in build metadata in ancestor directories.
# - C_FORMAT_STANDARD overrides detection (e.g. c23 or c99).
# - Usage: ./clang-format-all.sh [ROOT_DIR]
# - Requires: knfmt or clang-format in PATH
# - clang-format always uses the bundled Openbar style, including after install.
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

# Read metadata, never execute project build files. A nearer explicit standard
# overrides an ancestor's. This is heuristic; use C_FORMAT_STANDARD for dynamic
# build settings or conflicting per-target standards.
detect_standard() {
	standard_dir=${1%/*}
	while :; do
		standard=$(
			for metadata in Makefile.inc Makefile makefile GNUmakefile BSDmakefile \
				CMakeLists.txt meson.build compile_commands.json; do
				[ -f "$standard_dir/$metadata" ] || continue
				sed 's/#.*//' "$standard_dir/$metadata"
			done | awk '
			match($0, /-std=[[:space:]]*(gnu|c)(89|90|99|11|17|18|23|2x|1x)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^-std=[[:space:]]*/, "", s)
				sub(/[^[:alnum:]].*$/, "", s)
				last = s
			}
			match($0, /C_STANDARD[[:space:]]+(90|99|11|17|18|23)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^C_STANDARD[[:space:]]+/, "", s)
				sub(/[^[:digit:]].*$/, "", s)
				last = "c" s
			}
			match($0, /c_std=(gnu|c)(89|99|11|17|18|23|2x|1x)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART + 6, RLENGTH - 6)
				sub(/[^[:alnum:]].*$/, "", s)
				last = s
			}
			END { print last }'
		)
		if [ -n "$standard" ]; then
			printf '%s\n' "$standard"
			return
		fi
		[ ! -e "$standard_dir/.git" ] || return 0
		[ "$standard_dir" != / ] || return 0
		standard_dir=${standard_dir%/*}
		[ -n "$standard_dir" ] || standard_dir=/
	done
}

run_clang_format_all() {

	[ "$#" -le 1 ] || usage
	ROOT_DIR=${1:-.}
	[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
	[ -n "$ROOT_DIR" ] || usage
	[ -d "$ROOT_DIR" ] || {
		printf '%s\n' "[ERROR] ROOT_DIR is not a directory: $ROOT_DIR" >&2
		exit 2
	}
	ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)
	SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
	STYLE_FILE="$SCRIPT_DIR/clang-format-all.yaml"
	if [ "${0##*/}" = clang-format-all.sh ]; then
		STYLE_FILE="$SCRIPT_DIR/clang-format"
	fi
	case ${C_FORMAT_STANDARD:-} in
	'' | c89 | c90 | c99 | c11 | c1x | c17 | c18 | c23 | c2x | gnu89 | gnu90 | gnu99 | gnu11 | gnu1x | gnu17 | gnu18 | gnu23 | gnu2x) ;;
	*)
		printf '%s\n' '[ERROR] Unsupported C_FORMAT_STANDARD' >&2
		exit 2
		;;
	esac

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
			printf '%s\n' \
				"[INFO] Neither knfmt nor clang-format found" \
				" (install devel/knfmt or clang-tools-extra);" \
				" skipping C/C++ formatting"
		else
			printf '%s\n' \
				"[INFO] Neither knfmt nor clang-format found in PATH;" \
				" skipping C/C++ formatting"
		fi
		exit 0
	fi

	if ! find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f \
		\( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" \
		-o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" \
		-o -name "*.hxx" \) \
		-print | sed -n '1p' | grep -q .; then
		printf '%s\n' "[INFO] No C/C++ source files found under: $ROOT_DIR"
		exit 0
	fi

	if command -v clang-format >/dev/null 2>&1; then
		[ -r "$STYLE_FILE" ] || {
			printf '[ERROR] Missing bundled style: %s\n' "$STYLE_FILE" >&2
			exit 1
		}
		# Validate before modifying any source files, including C and C++ modes.
		clang-format "-style=file:$STYLE_FILE" -assume-filename=check.c \
			-dump-config >/dev/null
		clang-format "-style=file:$STYLE_FILE" -assume-filename=check.cpp \
			-dump-config >/dev/null
	fi
	printf '%s\n' "[INFO] Applying C/C++ formatting (default: $FORMATTER)..."
	find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f \
		\( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" \
		-o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" \
		-o -name "*.hxx" \) \
		-print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			standard=${C_FORMAT_STANDARD:-$(detect_standard "$f")}
			selected=$FORMATTER
			case "$standard" in
			c11 | c1x | c17 | c18 | c23 | c2x | gnu11 | gnu1x | gnu17 | gnu18 | gnu23 | gnu2x)
				if command -v clang-format >/dev/null 2>&1; then
					selected=clang-format
				else
					printf '[WARN] %s: %s; clang-format unavailable, using knfmt\n' "$f" "$standard"
				fi
				;;
			esac
			printf '[INFO] %s: %s (standard: %s)\n' "$f" "$selected" "${standard:-unknown}"
			if [ "$selected" = "knfmt" ]; then
				knfmt -i "$f"
			else
				clang-format -i "-style=file:$STYLE_FILE" -fallback-style=none "$f"
			fi
		done
	printf '%s\n' '[INFO] C/C++ formatting applied'
	exit 0
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd awk
	require_cmd dirname
	run_clang_format_all "$@"
}

main "$@"
