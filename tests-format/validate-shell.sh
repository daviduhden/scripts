#!/bin/sh
set -eu

# Announce the log path on descriptor 3, then redirect normal output to the
# log. The trap removes the temporary failure and format lists on exit or
# signal; the log itself is kept for inspection. The helper variables start
# empty so the trap can safely test them before they are assigned.
exec 3>&1 4>&2
TMPDIR_BASE="${TMPDIR:-/tmp}"
TMPLOG=$(mktemp "$TMPDIR_BASE/validate-shell-XXXXXX")
TMP_FAILS=
UNFMT_SH=
TMP_SKIPS=
INVENTORY=
trap '[ -z "$INVENTORY" ] || rm -f "$INVENTORY"; [ -z "$TMP_FAILS" ] || rm -f "$TMP_FAILS"; [ -z "$UNFMT_SH" ] || rm -f "$UNFMT_SH"; [ -z "$TMP_SKIPS" ] || rm -f "$TMP_SKIPS"' 0
trap 'exit 1' HUP INT TERM
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-shell.sh
# - Recursively finds all shell scripts under ROOT_DIR
#   (default: current directory) and checks formatting
#   with shfmt, shell syntax, bash syntax, ksh syntax and
#   checkbashisms for POSIX sh scripts. It also runs the
#   ShellCheck linter (if available, treating warnings as errors).
# - Usage: ./validate-shell.sh [--check|--format] [--strict] [ROOT_DIR]
# - Requires: shfmt, shellcheck, checkbashisms and ksh
#   (all optional) in PATH
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [--check|--format] [--strict] [ROOT_DIR]" >&2
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

run_validate_shell() {

	# One optional ROOT_DIR. Reject option-looking paths and verify the
	# directory before creating any temporary files.
	MODE=check
	STRICT=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--check) MODE=check ;;
		--format) MODE=format ;;
		--strict) STRICT=1 ;;
		--)
			shift
			break
			;;
		-*) usage ;;
		*) break ;;
		esac
		shift
	done
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
		printf '%s\n' \
			"[INFO] OpenBSD detected: install shfmt," \
			" shellcheck and bash (if needed)"
	fi

	TMP_FAILS=$(mktemp "$TMPDIR_BASE/validate-shell-fails-XXXXXX")
	TMP_SKIPS=$(mktemp "$TMPDIR_BASE/validate-shell-skips-XXXXXX")

	INVENTORY=$(mktemp "$TMPDIR_BASE/validate-shell-files-XXXXXX")
	if ! find "$ROOT_DIR" -name .git -type d -prune -o -type f \
		\( -name '*.sh' -o -name '*.bash' -o -name '*.ksh' \) -print >"$INVENTORY"; then
		printf '[ERROR] Cannot inventory shell scripts in %s\n' "$ROOT_DIR"
		exit 2
	fi

	note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }
	note_skip() {
		printf '[SKIP] %s\n' "$1" >&2
		printf '%s\n' "$1" >>"$TMP_SKIPS"
		if [ "$STRICT" -eq 1 ]; then note_fail "missing: $1"; fi
	}

	printf '%s\n' "[INFO] Formatting shell scripts with shfmt..."
	if command -v shfmt >/dev/null 2>&1; then
		UNFMT_SH=$(mktemp "$TMPDIR_BASE/unformatted-sh-XXXXXX")

		while IFS= read -r file; do
			status=0
			unformatted=$(shfmt -l -s "$file") || status=$?
			if [ "$unformatted" = "$file" ] && [ "$status" -le 1 ]; then
				printf '%s\n' "$file" >>"$UNFMT_SH"
			elif [ "$status" -ne 0 ] || [ -n "$unformatted" ]; then
				printf '[ERROR] shfmt could not check %s\n' "$file"
				note_fail "$file"
			fi
		done <"$INVENTORY"

		if [ -s "$UNFMT_SH" ]; then
			printf '%s\n' "[INFO] shfmt will format the following files:"
			sed -n '1,200p' "$UNFMT_SH" | sed 's/^/  - /'

			# Rewrite in place with the same -s simplification mode used for
			# detection. Both success and failure are recorded, so a run that
			# changed files still exits nonzero and forces a diff review.
			while IFS= read -r file; do
				[ -n "$file" ] || continue
				if [ "$MODE" = check ]; then
					note_fail "$file"
					continue
				fi
				if shfmt -w -s "$file"; then
					note_fail "$file"
				else
					printf '%s\n' "[WARN] shfmt failed for: $file" 1>&2
					note_fail "$file"
				fi
			done <"$UNFMT_SH"
		else
			printf '%s\n' "[INFO] All shell scripts already formatted"
		fi

		rm -f "$UNFMT_SH"
	else
		note_skip "shfmt not installed; skipping shell formatting"
	fi

	printf '%s\n' "[INFO] Running shell syntax checks..."

	SYNTAX_BASH=$(command -v bash || true)
	KSH_CMD=
	if [ "$OS_NAME" = Linux ] && command -v oksh >/dev/null 2>&1; then
		KSH_CMD=$(command -v oksh)
	else
		KSH_CMD=$(command -v ksh || true)
	fi
	CHECKBASHISMS=$(command -v checkbashisms || true)
	SHELLCHECK=$(command -v shellcheck || true)
	[ -n "$SYNTAX_BASH" ] || note_skip "bash not found; skipping bash syntax checks"
	[ -n "$KSH_CMD" ] || note_skip "ksh not found; skipping ksh syntax checks"
	[ -n "$CHECKBASHISMS" ] || note_skip "checkbashisms not installed; skipping POSIX sh checks"
	[ -n "$SHELLCHECK" ] || note_skip "shellcheck not installed; skipping shellcheck"

	while IFS= read -r file; do
		case "$file" in
		*.sh) interpreter='sh' ;;
		*.bash) interpreter=$SYNTAX_BASH ;;
		*.ksh) interpreter=$KSH_CMD ;;
		esac
		if [ -n "$interpreter" ] && ! "$interpreter" -n "$file"; then
			printf '[ERROR] Shell syntax error in %s\n' "$file"
			note_fail "$file"
		fi
		if [ -n "$CHECKBASHISMS" ] && [ "${file##*.}" = sh ]; then
			if command -v perl >/dev/null 2>&1; then
				perl -T "$CHECKBASHISMS" "$file" || note_fail "$file"
			else
				"$CHECKBASHISMS" "$file" || note_fail "$file"
			fi
		fi
		if [ -n "$SHELLCHECK" ]; then
			"$SHELLCHECK" -x "$file" || note_fail "$file"
		fi
	done <"$INVENTORY"

	printf '[INFO] Skipped checks: %s\n' "$(wc -l <"$TMP_SKIPS" | tr -d ' ')"
	issues=0
	if [ -f "$TMP_FAILS" ]; then
		issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
	fi

	# Findings and rewrites exit 2; usage errors also exit 2, but usage exits
	# before any checks run. Duplicate file names from different checks are
	# collapsed by sort -u. Missing optional tools are skips, not findings.
	if [ "${issues:-0}" -ne 0 ]; then
		printf '%s\n' \
			"[INFO] Completed with $issues issue(s)" \
			" (format changes and/or errors)"
		printf '%s\n' "[INFO] Affected files (unique, first 200):"
		sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
		exit 2
	fi

	printf '%s\n' "[INFO] Shell checks completed; inspect skipped-check summary"
	exit 0
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd mktemp
	run_validate_shell "$@"
}

main "$@"
