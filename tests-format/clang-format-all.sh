#!/bin/sh
set -eu

# Keep the original streams on descriptors 3 and 4. Everything below is
# redirected to a per-run log, so progress messages land in the log while
# descriptor 3 can still bypass it (for example, to announce the log path).
# The log is left in ${TMPDIR:-/tmp} for inspection after the run.
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/clang-format-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# clang-format-all.sh
# - Recursively finds all C/C++ and Java source files under ROOT_DIR
#   (default: current directory, excluding .git directories) and applies
#   formatting.
# - Prefers clang-format for C++11/14/17/20/23 and C11/C17/C23 projects,
#   otherwise knfmt.
# - Detects literal C and C++ standards in build metadata in ancestor
#   directories.
# - C_FORMAT_STANDARD overrides detection (e.g. c++23, cxx23, c23 or c99).
# - Java sources are always formatted with clang-format; knfmt is never used
#   for Java.
# - Uses a project-root .clang-format when present; otherwise uses the bundled
#   Openbar style.
# - Usage: ./clang-format-all.sh [ROOT_DIR]
# - Requires: knfmt or clang-format in PATH.
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

# Print the effective C/C++ standard for the file in $1, or nothing when no
# literal standard is found. Metadata from the file's own directory is
# preferred over ancestors; the search stops at a .git entry or the filesystem
# root. Only stable -std=, CMake CXX_STANDARD/C_STANDARD/cxx_std_*, and Meson
# c_std= spellings are recognized. Build files are read, never executed, so
# computed or per-target standards need C_FORMAT_STANDARD instead.
detect_standard() {
	standard_dir=${1%/*}
	while :; do
		# Concatenate every recognized metadata file in this directory so
		# one awk pass can report the last literal match. Stripping #
		# comments is a line-based heuristic, not a parser.
		standard=$(
			for metadata in Makefile.inc Makefile makefile GNUmakefile BSDmakefile \
				CMakeLists.txt build/CMakeLists.txt meson.build compile_commands.json; do
				[ -f "$standard_dir/$metadata" ] || continue
				sed 's/#.*//' "$standard_dir/$metadata"
			done | awk '
			match($0, /-std=[[:space:]]*(gnu\+\+|c\+\+)(11|14|17|20|23)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^-std=[[:space:]]*/, "", s)
				sub(/[^[:alnum:]+].*$/, "", s)
				last = s
			}
			match($0, /-std=[[:space:]]*(gnu|c)(89|90|99|11|17|18|23|2x|1x)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^-std=[[:space:]]*/, "", s)
				sub(/[^[:alnum:]].*$/, "", s)
				last = s
			}
			match($0, /CXX_STANDARD[[:space:]]+(11|14|17|20|23)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^CXX_STANDARD[[:space:]]+/, "", s)
				sub(/[^[:digit:]].*$/, "", s)
				last = "c++" s
			}
			match($0, /cxx_std_(11|14|17|20|23)([^[:alnum:]_]|$)/) {
				s = substr($0, RSTART, RLENGTH)
				sub(/^cxx_std_/, "", s)
				sub(/[^[:digit:]].*$/, "", s)
				last = "c++" s
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
		# Do not read metadata outside the project or above the root.
		[ ! -e "$standard_dir/.git" ] || return 0
		[ "$standard_dir" != / ] || return 0
		standard_dir=${standard_dir%/*}
		[ -n "$standard_dir" ] || standard_dir=/
	done
}

run_clang_format_all() {

	# Accept zero or one operand. Reject option-looking roots so a mistyped
	# flag is not formatted as a directory name. Exit 2 is reserved for
	# usage/path errors; exit 1 reports missing tools or configurations.
	[ "$#" -le 1 ] || usage
	ROOT_DIR=${1:-.}
	[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
	[ -n "$ROOT_DIR" ] || usage
	[ -d "$ROOT_DIR" ] || {
		printf '%s\n' "[ERROR] ROOT_DIR is not a directory: $ROOT_DIR" >&2
		exit 2
	}
	# Resolve symlinks and relative components once so find output and the
	# .git pruning below use a stable absolute prefix.
	ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)
	SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
	# Prefer a project-local style. The in-tree script uses the repository
	# copy (clang-format); the installed command uses the installed file
	# (clang-format-all.yaml).
	if [ -r "$ROOT_DIR/.clang-format" ]; then
		STYLE_FILE="$ROOT_DIR/.clang-format"
	else
		STYLE_FILE="$SCRIPT_DIR/clang-format-all.yaml"
		if [ "${0##*/}" = clang-format-all.sh ]; then
			STYLE_FILE="$SCRIPT_DIR/clang-format"
		fi
	fi
	case ${C_FORMAT_STANDARD:-} in
	# Empty means "detect per file"; anything else must be one of the
	# spellings accepted by clang-format and knfmt.
	'' | c89 | c90 | c99 | c11 | c1x | c17 | c18 | c23 | c2x | gnu89 | gnu90 | gnu99 | gnu11 | gnu1x | gnu17 | gnu18 | gnu23 | gnu2x | c++11 | c++14 | c++17 | c++20 | c++23 | cxx11 | cxx14 | cxx17 | cxx20 | cxx23 | gnu++11 | gnu++14 | gnu++17 | gnu++20 | gnu++23) ;;
	*)
		printf '%s\n' '[ERROR] Unsupported C_FORMAT_STANDARD' >&2
		exit 2
		;;
	esac

	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	if [ "$OS_NAME" = "OpenBSD" ]; then
		printf '%s\n' "[INFO] OpenBSD detected: install clang-tools-extra"
	fi

	# A missing formatter is a skip, not a failure, so mixed toolchains can
	# still run the rest of the test suite.
	# knfmt is the project formatter when both tools exist; modern-language
	# files below are still handed to clang-format when it is available.
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

	# Stop early when there is nothing to format. Reading one line through
	# sed avoids SIGPIPE-prone early-exit consumers such as head.
	if ! find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f \
		\( -name "*.[ch]" -o -name "*.cc" -o -name "*.cpp" \
		-o -name "*.cxx" -o -name "*.hh" -o -name "*.hpp" \
		-o -name "*.hxx" -o -name "*.java" \) \
		-print | sed -n '1p' | grep -q .; then
		printf '%s\n' "[INFO] No C/C++/Java source files found under: $ROOT_DIR"
		exit 0
	fi

	if command -v clang-format >/dev/null 2>&1; then
		[ -r "$STYLE_FILE" ] || {
			printf '[ERROR] Missing bundled style: %s\n' "$STYLE_FILE" >&2
			exit 1
		}
		# Validate the style for both languages before modifying any source
		# files. -assume-filename selects the C or C++ language mapping.
		clang-format "-style=file:$STYLE_FILE" -assume-filename=check.c \
			-dump-config >/dev/null
		clang-format "-style=file:$STYLE_FILE" -assume-filename=check.cpp \
			-dump-config >/dev/null
	fi
	printf '%s\n' '[INFO] Applying C/C++ formatting (standard-aware selection)...'
	# The pipeline runs in a subshell; formatting happens in place. A failing
	# formatter exits that subshell and, under set -e, aborts the run.
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
			c11 | c1x | c17 | c18 | c23 | c2x | gnu11 | gnu1x | gnu17 | gnu18 | gnu23 | gnu2x | c++11 | c++14 | c++17 | c++20 | c++23 | cxx11 | cxx14 | cxx17 | cxx20 | cxx23 | gnu++11 | gnu++14 | gnu++17 | gnu++20 | gnu++23)
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
	# Java is handled in a second pass because knfmt cannot format it and the
	# detection loop above deliberately excludes .java. A missing clang-format
	# is reported as an error but does not change the final exit status.
	if find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f -name "*.java" \
		-print | sed -n '1p' | grep -q .; then
		if ! command -v clang-format >/dev/null 2>&1; then
			printf '%s\n' '[ERROR] Java sources found but clang-format is unavailable; Java formatting skipped' >&2
		else
			printf '%s\n' '[INFO] Applying Java formatting with clang-format...'
			find "$ROOT_DIR" \
				-name .git \
				-prune -o -type f -name "*.java" \
				-print |
				while IFS= read -r f; do
					[ -n "$f" ] || continue
					printf '[INFO] %s: clang-format (Java)\n' "$f"
					clang-format -i "-style=file:$STYLE_FILE" -fallback-style=none "$f"
				done
			printf '%s\n' '[INFO] Java formatting applied'
		fi
	fi
	printf '%s\n' '[INFO] C/C++/Java formatting applied'
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
