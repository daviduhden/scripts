#!/bin/sh
set -eu

# Announce the log path on descriptor 3, then send normal output to the log.
# mandoc diagnostics also land there; only the initial log path is printed to
# the terminal.
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-manpages-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-manpages.sh
# - Recursively finds all man pages under ROOT_DIR
#   (default: current directory excluding .git) and runs
#   mandoc lint on them, treating warnings as errors.
# - Usage: ./validate-manpages.sh [ROOT_DIR]
# - Optional: mandoc in PATH; validation is skipped when it is absent
#
# Note: mandoc is a BSD tool; on Linux, install it via
# your package manager (e.g., apt, dnf).
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

run_validate_manpages() {

	# One optional ROOT_DIR. Reject option-looking paths before probing for
	# mandoc.
	ROOT_DIR=${1:-.}
	[ "$#" -le 1 ] || usage
	[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
	[ -d "$ROOT_DIR" ] || {
		printf '%s\n' "[ERROR] ROOT_DIR is not a directory: $ROOT_DIR" >&2
		exit 2
	}
	# Normalize so the "$ROOT_DIR/.git" prune patterns below match find's
	# output even for "./" or trailing-slash roots.
	ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)

	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	if [ "$OS_NAME" = "OpenBSD" ]; then
		printf '%s\n' "[INFO] OpenBSD detected: mandoc is in base"
	fi

	if ! command -v mandoc >/dev/null 2>&1; then
		# Optional dependency: absent mandoc is a skip with success status, so
		# the aggregate test target works on systems without it.
		printf '%s\n' "[INFO] mandoc not installed; skipping man page validation"
		exit 0
	fi

	# Find man pages and run mandoc lint.
	# - Prune .git to avoid scanning vendored stuff.
	# - Read paths with "while IFS= read -r" instead of xargs, which keeps
	#   names with spaces intact and avoids xargs option differences.
	# - Match common man section suffixes: .1 .. .9 and
	#   variants like .1m, .3p, etc.
	# - The first match check uses sed rather than head so the pipeline does
	#   not depend on SIGPIPE handling.
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

	printf '%s\n' \
		"[INFO] Running mandoc lint" \
		" (treat warnings as errors)..."
	# -Tlint selects lint mode; -Werror promotes warnings to errors. Because
	# the loop is the last stage of a pipeline under set -e, the first page
	# with a finding aborts the run with a nonzero status.
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
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	run_validate_manpages "$@"
}

main "$@"
