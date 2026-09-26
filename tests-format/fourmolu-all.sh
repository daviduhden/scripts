#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/fourmolu-all-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# fourmolu-all.sh
# - Recursively finds all Haskell source files (*.hs, *.hsig and *.hs-boot)
#   under ROOT_DIR (default: current directory, excluding .git directories)
#   and formats them in place with fourmolu.
# - fourmolu always uses the bundled fourmolu-all.yaml and ignores any
#   project-local fourmolu.yaml/.fourmolu.yaml, mirroring clang-format-all
#   and its bundled clang-format style.
# - Usage: ./fourmolu-all.sh [ROOT_DIR]
# - Requires: fourmolu in PATH
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

run_fourmolu_all() {

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
	STYLE_FILE="$SCRIPT_DIR/fourmolu-all.yaml"

	if ! command -v fourmolu >/dev/null 2>&1; then
		printf '%s\n' \
			"[INFO] fourmolu not found in PATH;" \
			" skipping Haskell formatting"
		exit 0
	fi

	if ! find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f \
		\( -name '*.hs' -o -name '*.hsig' -o -name '*.hs-boot' \) \
		-print | sed -n '1p' | grep -q .; then
		printf '%s\n' "[INFO] No Haskell source files found under: $ROOT_DIR"
		exit 0
	fi

	[ -r "$STYLE_FILE" ] || {
		printf '[ERROR] Missing bundled style: %s\n' "$STYLE_FILE" >&2
		exit 1
	}
	# Validate the bundled style before modifying any source files.
	printf 'module FourmoluAllConfigCheck where\n' |
		fourmolu --config "$STYLE_FILE" \
			--stdin-input-file FourmoluAllConfigCheck.hs >/dev/null

	printf '%s\n' \
		'[INFO] Applying Haskell formatting with the bundled fourmolu style...'
	find "$ROOT_DIR" \
		-name .git \
		-prune -o -type f \
		\( -name '*.hs' -o -name '*.hsig' -o -name '*.hs-boot' \) \
		-print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			printf '[INFO] %s\n' "$f"
			fourmolu --config "$STYLE_FILE" -i "$f"
		done
	printf '%s\n' '[INFO] Haskell formatting applied'
	exit 0
}

main() {
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd dirname
	run_fourmolu_all "$@"
}

main "$@"
