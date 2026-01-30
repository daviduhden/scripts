#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-perl-$$.log"
printf '[INFO] Logging to: %s\n' "$TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-perl.sh
# - Recursively finds all Perl files under ROOT_DIR (default: current directory)
#   and checks formatting with perltidy and Perl syntax.
# - Usage: ./validate-perl.sh [ROOT_DIR]
# - Requires: perltidy, perl in PATH
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
	printf '%s\n' "[INFO] OpenBSD detected: install perltidy"
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMP_FAILS="$TMPDIR_BASE/validate-perl-fails-$$.txt"
trap 'rm -f "$TMP_FAILS"' EXIT

note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

echo "[INFO] Formatting Perl files with perltidy..."
if command -v perltidy >/dev/null 2>&1; then
	UNFMT="$TMPDIR_BASE/unformatted-perl-$$.txt"

	# Detect files that would change formatting
	find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name '*.pl' -o -name '*.pm' -o -name '*.t' -o -name '*.psgi' \) -exec sh -c '
		for f do
			if ! perltidy -ast -se -o /dev/null "$f" >/dev/null 2>&1; then
				printf "%s\n" "$f"
			fi
		done
	' sh {} + >"$UNFMT" || true

	if [ -s "$UNFMT" ]; then
		echo "[INFO] perltidy will format the following files:"
		sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			# Format in-place without backups (backup extension "/" disables backups)
			if perltidy --backup-and-modify-in-place --backup-file-extension=/ -se "$file" >/dev/null 2>&1; then
				note_fail "$file"
			else
				echo "[WARN] perltidy failed for: $file" 1>&2
				note_fail "$file"
			fi
		done <"$UNFMT"
	else
		echo "[INFO] All Perl files already formatted"
	fi

	rm -f "$UNFMT"
else
	echo "[INFO] perltidy not installed; skipping Perl formatting"
fi

echo "[INFO] Running Perl syntax checks..."
find "$ROOT_DIR" \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) -prune -o -type f \( -name '*.pl' -o -name '*.pm' -o -name '*.t' -o -name '*.psgi' \) -exec sh -c '
	for f do
		set +e
		perlc_out=$(perl -c "$f" 2>&1)
		perlc_rc=$?
		set -e
		if [ "${perlc_rc:-0}" -ne 0 ]; then
			if printf "%s" "$perlc_out" | grep -qi "Can.t locate"; then
				printf "%s\n" "[WARN] Skipping syntax check for $f due to missing modules" 1>&2
			else
				printf "%s\n" "[ERROR] Perl syntax error in: $f" 1>&2
				printf "%s\n" "$f"
			fi
		fi
	done
' sh {} + | while IFS= read -r bad; do
	[ -n "$bad" ] && note_fail "$bad"
done

issues=0
if [ -f "$TMP_FAILS" ]; then
	issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
fi

if [ "${issues:-0}" -ne 0 ]; then
	echo "[INFO] Completed with $issues issue(s) (format changes and/or errors)"
	echo "[INFO] Affected files (unique, first 200):"
	sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
	exit 2
fi

echo "[INFO] Perl checks passed"
exit 0
