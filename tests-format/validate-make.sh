#!/bin/sh
set -eu

# Announce the log path on descriptor 3, then send normal output to the log.
# The log remains under ${TMPDIR:-/tmp} after exit for inspection.
exec 3>&1 4>&2
TMPLOG=$(mktemp "${TMPDIR:-/tmp}/validate-make-XXXXXX")
TMP_FAILS=
UNFMT=
TMP_SKIPS=
trap '[ -z "$TMP_FAILS" ] || rm -f "$TMP_FAILS"; [ -z "$UNFMT" ] || rm -f "$UNFMT"; [ -z "$TMP_SKIPS" ] || rm -f "$TMP_SKIPS"' EXIT
trap 'exit 1' HUP INT TERM
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-make.sh
# - Recursively finds all Makefiles under ROOT_DIR
#   (default: current directory), checks formatting with
#   mbake and lints with checkmake. --make-dry-run opts into evaluating
#   trusted Makefiles with bmake/make; even -n can execute parse-time commands.
# - Usage: ./validate-make.sh [--check|--format] [--strict] [ROOT_DIR]
# - Uses: mbake, checkmake, bmake (or make) in PATH when available
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [--check|--format] [--strict] [--make-dry-run] [ROOT_DIR]" >&2
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

run_validate_make() {

	# One optional ROOT_DIR; reject option-looking paths before doing work.
	MODE=check
	STRICT=0
	MAKE_DRY_RUN=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--check) MODE=check ;;
		--format) MODE=format ;;
		--strict) STRICT=1 ;;
		--make-dry-run) MAKE_DRY_RUN=1 ;;
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
	IS_OPENBSD=0
	if [ "$OS_NAME" = "OpenBSD" ]; then
		IS_OPENBSD=1
		printf '%s\n' \
			"[INFO] OpenBSD detected: checkmake and mbake" \
			" are not ported"
	fi

	TMPDIR_BASE="${TMPDIR:-/tmp}"
	TMP_FAILS=$(mktemp "$TMPDIR_BASE/validate-make-fails-XXXXXX")
	TMP_SKIPS=$(mktemp "$TMPDIR_BASE/validate-make-skips-XXXXXX")

	# Pipelines run their loops in subshells; use a file to accumulate names.
	note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }
	note_skip() {
		printf '[SKIP] %s\n' "$1" >&2
		printf '%s\n' "$1" >>"$TMP_SKIPS"
		if [ "$STRICT" -eq 1 ] && [ "${2:-required}" = required ]; then note_fail "missing: $1"; fi
	}

	is_bsd_makefile() {
		# mbake and checkmake implement GNU make syntax. Do not feed them
		# BSD-only directory variables or the custom suffix chains used by
		# bmake; those files are checked by the native dry run below.
		grep -Eq '\$\{\.(CURDIR|OBJDIR)\}|^[[:space:]]*\.(CURDIR|OBJDIR)[[:space:]]*=|^[[:space:]]*\.SUFFIXES:.*\.[[:alnum:]_-]+-[[:alnum:]_-]+' "$1"
	}

	is_makefile_wrapper() {
		# checkmake does not follow includes, so linting a wrapper in isolation
		# can only report missing targets that are defined by the included file.
		awk '
			NF && $1 !~ /^#/ {
				lines++
				if ($1 == "include") includes++
				else if ($1 !~ /^\.(CURDIR|OBJDIR)=$/) invalid = 1
			}
			END { exit !(lines <= 3 && includes == 1 && !invalid) }
		' "$1"
	}

	printf '%s\n' "[INFO] Formatting Makefiles with mbake..."
	# mbake is unavailable on OpenBSD, and checkmake is skipped there as well.
	if [ "$IS_OPENBSD" -eq 1 ]; then
		note_skip "OpenBSD: mbake is not ported" inapplicable
	elif command -v mbake >/dev/null 2>&1; then
		UNFMT=$(mktemp "$TMPDIR_BASE/unformatted-make-XXXXXX")

		# --check reports drift without rewriting; names are collected so the
		# rewrite pass can print what it is about to change.
		find "$ROOT_DIR" \
			\( -name .git \) \
			-prune -o -type f \
			\( -name 'Makefile' -o -name 'makefile' \
			-o -name 'GNUmakefile' -o -name '*.mk' \) \
			-print |
			while IFS= read -r f; do
				[ -n "$f" ] || continue
				if [ "${f##*/}" != "GNUmakefile" ] && is_bsd_makefile "$f"; then
					note_skip "mbake unsupported BSD makefile: $f" inapplicable
					continue
				fi
				if ! mbake format --check "$f" >/dev/null 2>&1; then
					printf "%s\n" "$f"
				fi
			done >"$UNFMT" || true

		if [ -s "$UNFMT" ]; then
			printf '%s\n' "[INFO] mbake will format the following files:"
			sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'

			# A successful rewrite is still recorded as an issue so the run
			# exits nonzero and the diff is reviewed.
			while IFS= read -r file; do
				[ -n "$file" ] || continue
				if [ "$MODE" = check ]; then
					note_fail "$file"
					continue
				fi
				if mbake format "$file" >/dev/null 2>&1; then
					note_fail "$file"
				else
					printf '%s\n' "[WARN] mbake failed for: $file" 1>&2
					note_fail "$file"
				fi
			done <"$UNFMT"
		else
			printf '%s\n' "[INFO] All Makefiles already formatted"
		fi

		rm -f "$UNFMT"
	else
		note_skip "mbake not installed; skipping Makefile formatting"
	fi

	if [ "$IS_OPENBSD" -eq 1 ]; then
		note_skip "OpenBSD: checkmake is not ported" inapplicable
	elif command -v checkmake >/dev/null 2>&1; then
		printf '%s\n' "[INFO] Running checkmake (Makefile linter)..."
		find "$ROOT_DIR" \
			\( -name .git \) \
			-prune -o -type f \
			\( -name 'Makefile' -o -name 'makefile' \
			-o -name 'GNUmakefile' -o -name '*.mk' \) \
			-print |
			while IFS= read -r f; do
				[ -n "$f" ] || continue
				if is_bsd_makefile "$f" || is_makefile_wrapper "$f"; then
					note_skip "checkmake unsupported makefile dialect: $f" inapplicable
					continue
				fi
				if ! checkmake "$f" >/dev/null 2>&1; then
					printf '%s\n' "[ERROR] checkmake found issues in: $f" 1>&2
					note_fail "$f"
				fi
			done || true
	else
		note_skip "checkmake not installed; skipping Makefile lint"
	fi

	# Run bmake/make dry-run to ensure BSD make compatibility. On OpenBSD the
	# base make is bmake, so fall back to "make" there. On other systems a
	# missing bmake skips the check rather than silently testing GNU make.
	MAKE_CMD="bmake"
	if [ "$IS_OPENBSD" -eq 1 ] &&
		! command -v bmake >/dev/null 2>&1 &&
		command -v make >/dev/null 2>&1; then
		MAKE_CMD="make"
	fi

	if [ "$MAKE_DRY_RUN" -ne 1 ]; then
		note_skip "make execution disabled; use --make-dry-run only on trusted trees" inapplicable
	elif command -v "$MAKE_CMD" >/dev/null 2>&1; then
		printf '%s\n' "[INFO] Running $MAKE_CMD -n -f (bsdmake dry-run)..."
		find "$ROOT_DIR" \
			\( -name .git \) \
			-prune -o -type f \
			\( -name 'Makefile' -o -name 'makefile' \
			-o -name 'GNUmakefile' -o -name '*.mk' \) \
			-print |
			while IFS= read -r f; do
				[ -n "$f" ] || continue
				make_dir=$(dirname "$f")
				make_file=${f##*/}
				if [ "$make_file" = "GNUmakefile" ]; then
					note_skip "bmake unsupported GNU makefile: $f" inapplicable
					continue
				fi
				if [ "$make_file" = "Makefile" ] &&
					grep -Eq '^[[:space:]]*include[[:space:]]+\$\{\.CURDIR\}/config\.mk' "$f" &&
					[ ! -f "$make_dir/config.mk" ]; then
					note_skip "bmake requires generated config.mk: $f" inapplicable
					continue
				fi
				# bmake resolves relative paths against the
				# invocation directory (GNU make does not chdir
				# either), so run the dry-run from the Makefile's
				# own directory. The subshell keeps the caller here.
				if ! (cd "$make_dir" &&
					"$MAKE_CMD" -n -f "$make_file") \
					>/dev/null 2>&1; then
					printf '%s\n' "[WARN] $MAKE_CMD -n -f failed on: $f" 1>&2
					printf "%s\n" "$f"
				fi
			done | while IFS= read -r bad; do
			[ -n "$bad" ] && note_fail "$bad"
		done || true
	else
		note_skip "bmake/make not installed; skipping dry-run"
	fi

	printf '[INFO] Skipped checks: %s\n' "$(wc -l <"$TMP_SKIPS" | tr -d ' ')"
	issues=0
	if [ -f "$TMP_FAILS" ]; then
		issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
	fi

	# Rewrites and lint/dry-run failures are recorded as issues (exit 2).
	# Missing optional tools are skips, not findings.
	if [ "${issues:-0}" -ne 0 ]; then
		printf '%s\n' \
			"[INFO] Completed with $issues issue(s)" \
			" (format changes and/or errors)"
		printf '%s\n' "[INFO] Affected files (unique, first 200):"
		sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
		exit 2
	fi

	printf '%s\n' "[INFO] Makefile checks completed; inspect skipped-check summary"
	exit 0
}

main() {
	require_cmd mktemp
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	run_validate_make "$@"
}

main "$@"
