#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-shell-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-shell.sh
# - Recursively finds all shell scripts under ROOT_DIR (default: current directory)
#   and checks formatting with shfmt, shell syntax, bash syntax,
#   ksh syntax (if ksh is available), and runs shellcheck (if available
#   treating warnings as errors).
# - Usage: ./validate-shell.sh [ROOT_DIR]
# - Requires: shfmt, shellcheck, ksh (optional) in PATH
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
	printf '%s\n' "[INFO] OpenBSD detected: install shfmt, shellcheck and bash (if needed)"
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMP_FAILS="$TMPDIR_BASE/validate-shell-fails-$$.txt"
trap 'rm -f "$TMP_FAILS"' EXIT

note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

printf '%s\n' "[INFO] Formatting shell scripts with shfmt..."
if command -v shfmt >/dev/null 2>&1; then
	UNFMT_SH="$TMPDIR_BASE/unformatted-sh-$$.txt"

	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.ksh' \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			shfmt -l "$f"
		done 2>/dev/null >"$UNFMT_SH" || true

	if [ -s "$UNFMT_SH" ]; then
		printf '%s\n' "[INFO] shfmt will format the following files:"
		sed -n '1,200p' "$UNFMT_SH" | sed 's/^/  - /'

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if shfmt -w -s "$file" 2>/dev/null; then
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
	printf '%s\n' "[INFO] shfmt not installed; skipping shell formatting"
fi

printf '%s\n' "[INFO] Running shell syntax checks..."

find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f -name '*.sh' -print |
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if ! sh -n "$f" 2>/dev/null; then
			printf '%s\n' "[ERROR] sh syntax error in: $f" 1>&2
			printf "%s\n" "$f"
		fi
	done | while IFS= read -r bad; do
	[ -n "$bad" ] && note_fail "$bad"
done

if command -v bash >/dev/null 2>&1; then
	printf '%s\n' "[INFO] Running bash syntax checks..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f -name '*.bash' -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! bash -n "$f" 2>/dev/null; then
				printf '%s\n' "[ERROR] bash syntax error in: $f" 1>&2
				printf "%s\n" "$f"
			fi
		done | while IFS= read -r bad; do
		[ -n "$bad" ] && note_fail "$bad"
	done
else
	printf '%s\n' "[INFO] bash not found; skipping bash syntax checks"
fi

if command -v ksh >/dev/null 2>&1; then
	printf '%s\n' "[INFO] Running ksh syntax checks..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f -name '*.ksh' -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! ksh -n "$f" 2>/dev/null; then
				printf '%s\n' "[ERROR] ksh syntax error in: $f" 1>&2
				printf "%s\n" "$f"
			fi
		done | while IFS= read -r bad; do
		[ -n "$bad" ] && note_fail "$bad"
	done
else
	printf '%s\n' "[INFO] ksh not found; skipping ksh syntax checks"
fi

if command -v shellcheck >/dev/null 2>&1; then
	printf '%s\n' "[INFO] Running shellcheck..."
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name '*.bash' -o -name '*.ksh' -o -name '*.sh' \) -print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if ! shellcheck -x "$f"; then
				printf '%s\n' "[ERROR] shellcheck found issues in: $f" 1>&2
				printf "%s\n" "$f"
			fi
		done | while IFS= read -r bad; do
		[ -n "$bad" ] && note_fail "$bad"
	done
else
	printf '%s\n' "[INFO] shellcheck not installed; skipping shellcheck"
fi

issues=0
if [ -f "$TMP_FAILS" ]; then
	issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
fi

if [ "${issues:-0}" -ne 0 ]; then
	printf '%s\n' "[INFO] Completed with $issues issue(s) (format changes and/or errors)"
	printf '%s\n' "[INFO] Affected files (unique, first 200):"
	sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
	exit 2
fi

printf '%s\n' "[INFO] Shell checks passed"
exit 0
