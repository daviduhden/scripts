#!/bin/sh
set -eu

# validate-python.sh
# - Recursively checks Python files under ROOT_DIR (default: current directory)
#   with Ruff formatting and lint checks, excluding .git directories.
# - Ruff formatting is applied in place; changed files make validation fail
#   so the resulting diff can be reviewed before validation is rerun.
# - Usage: ./validate-python.sh [ROOT_DIR]
# - Requires: find, sed, grep, sort, wc, tr and ruff in PATH when Python files
#   are present; mktemp and rm are always required.
# See the LICENSE file at the top of this project tree for copyright and
# license details.

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

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	[ -z "${TMP_FAILS:-}" ] || rm -f "$TMP_FAILS"
	[ -z "${UNFMT:-}" ] || rm -f "$UNFMT"
	if [ "${RUFF_USED:-0}" -eq 1 ]; then
		if ! (CDPATH='' cd "$ROOT_DIR" && ruff clean); then
			printf '%s\n' '[ERROR] Failed to clear Ruff cache' >&2
			status=1
		else
			printf '%s\n' '[INFO] Ruff cache cleared'
		fi
	fi
	exit "$status"
}

run_validate_python() {
	# Announce the log path on descriptor 3, then send normal output to the log.
	exec 3>&1 4>&2
	TMPDIR_BASE=${TMPDIR:-/tmp}
	TMP_FAILS=
	UNFMT=
	RUFF_USED=0
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM
	TMPLOG=$(mktemp "$TMPDIR_BASE/validate-python-XXXXXX.log")
	TMP_FAILS=$(mktemp "$TMPDIR_BASE/validate-python-fails-XXXXXX")
	UNFMT=$(mktemp "$TMPDIR_BASE/unformatted-python-XXXXXX")
	printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
	exec >"$TMPLOG" 2>&1

	ROOT_DIR=${1:-.}
	[ "$#" -le 1 ] || usage
	[ "${ROOT_DIR#-}" = "$ROOT_DIR" ] || usage
	[ -d "$ROOT_DIR" ] || {
		printf '[ERROR] ROOT_DIR is not a directory: %s\n' "$ROOT_DIR" >&2
		exit 2
	}
	ROOT_DIR=$(CDPATH='' cd "$ROOT_DIR" && pwd -P)
	# No Python source means Ruff and its result-reporting tools are unnecessary.
	if ! find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f -name '*.py' -print |
		sed -n '1p' | grep -q .; then
		printf '[INFO] No Python files found under: %s\n' "$ROOT_DIR"
		exit 0
	fi

	require_cmd ruff
	require_cmd sort
	require_cmd wc
	require_cmd tr
	RUFF_USED=1
	note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

	printf '%s\n' '[INFO] Checking Python formatting with Ruff...'
	find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f -name '*.py' -print |
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if ! ruff format --check --quiet "$file" >/dev/null 2>&1; then
				printf '%s\n' "$file"
			fi
		done >"$UNFMT" || true

	if [ -s "$UNFMT" ]; then
		printf '%s\n' '[INFO] Ruff will format the following files:'
		sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if ruff format "$file"; then
				note_fail "$file"
			else
				printf '[ERROR] Ruff formatting failed for: %s\n' "$file" >&2
				note_fail "$file"
			fi
		done <"$UNFMT"
	else
		printf '%s\n' '[INFO] All Python files already formatted'
	fi

	printf '%s\n' '[INFO] Running Ruff lint checks...'
	find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f -name '*.py' -print |
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if ! ruff check "$file"; then
				note_fail "$file"
			fi
		done

	issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
	if [ "${issues:-0}" -ne 0 ]; then
		printf '[INFO] Completed with %s issue(s) (format changes or Ruff lint errors)\n' "$issues"
		printf '%s\n' '[INFO] Affected files (unique, first 200):'
		sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
		exit 2
	fi

	printf '%s\n' '[INFO] Python checks passed'
}

main() {
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd mktemp
	require_cmd rm
	run_validate_python "$@"
}

main "$@"
