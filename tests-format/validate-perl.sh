#!/bin/sh
set -eu

# Save original stdout/stderr, create per-run log in TMPDIR and redirect
exec 3>&1 4>&2
TMPLOG="${TMPDIR:-/tmp}/validate-perl-$$.log"
printf '%s\n' "[INFO] Logging to: $TMPLOG" >&3
exec >"$TMPLOG" 2>&1

# validate-perl.sh
# - Recursively finds all Perl files under ROOT_DIR
#   (default: current directory) and checks formatting
#   with perltidy, Perl syntax and Perl::Critic.
# - Usage: ./validate-perl.sh [ROOT_DIR]
# - Requires: perltidy, perl in PATH
# - Optional: perlcritic, either in PATH or in the local::lib
#   $PERL_LOCAL_LIB (default ~/perl5). It is run at --severity 5 by
#   default; set PERLCRITIC_SEVERITY to change the threshold (lower is
#   stricter).
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

run_validate_perl() {

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
		printf '%s\n' "[INFO] OpenBSD detected: install perltidy"
	fi

	TMPDIR_BASE="${TMPDIR:-/tmp}"
	TMP_FAILS="$TMPDIR_BASE/validate-perl-fails-$$.txt"
	trap 'rm -f "$TMP_FAILS"' EXIT

	note_fail() { printf '%s\n' "$1" >>"$TMP_FAILS"; }

	printf '%s\n' "[INFO] Formatting Perl files with perltidy..."
	if command -v perltidy >/dev/null 2>&1; then
		UNFMT="$TMPDIR_BASE/unformatted-perl-$$.txt"

		# Detect files that would change formatting
		find "$ROOT_DIR" \
			\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
			-prune -o -type f \
			\( -name '*.pl' -o -name '*.pm' \
			-o -name '*.t' -o -name '*.psgi' \) \
			-print |
			while IFS= read -r f; do
				[ -n "$f" ] || continue
				if ! perltidy -ast -se -o /dev/null "$f" >/dev/null 2>&1; then
					printf "%s\n" "$f"
				fi
			done >"$UNFMT" || true

		if [ -s "$UNFMT" ]; then
			printf '%s\n' "[INFO] perltidy will format the following files:"
			sed -n '1,200p' "$UNFMT" | sed 's/^/  - /'

			while IFS= read -r file; do
				[ -n "$file" ] || continue
				# Format in-place without backups
				# (backup extension "/" disables backups)
				if perltidy --backup-and-modify-in-place \
					--backup-file-extension=/ \
					-se "$file" >/dev/null 2>&1; then
					note_fail "$file"
				else
					printf '%s\n' "[WARN] perltidy failed for: $file" 1>&2
					note_fail "$file"
				fi
			done <"$UNFMT"
		else
			printf '%s\n' "[INFO] All Perl files already formatted"
		fi

		rm -f "$UNFMT"
	else
		printf '%s\n' \
			"[INFO] perltidy not installed;" \
			" skipping Perl formatting"
	fi

	printf '%s\n' "[INFO] Running Perl syntax checks..."
	find "$ROOT_DIR" \
		\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
		-prune -o -type f \
		\( -name '*.pl' -o -name '*.pm' \
		-o -name '*.t' -o -name '*.psgi' \) \
		-print |
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			set +e
			perlc_out=$(perl -c "$f" 2>&1)
			perlc_rc=$?
			set -e
			if [ "${perlc_rc:-0}" -ne 0 ]; then
				if printf "%s" "$perlc_out" | grep -qi "Can.t locate"; then
					printf '%s\n' \
						"[WARN] Skipping syntax check for $f" \
						" due to missing modules" 1>&2
				else
					printf '%s\n' "[ERROR] Perl syntax error in: $f" 1>&2
					printf "%s\n" "$f"
				fi
			fi
		done | while IFS= read -r bad; do
		[ -n "$bad" ] && note_fail "$bad"
	done

	printf '%s\n' "[INFO] Running Perl::Critic..."

	# perlcritic may be installed in a local::lib (cpanm -l) instead of
	# PATH; fall back to $PERL_LOCAL_LIB/bin (default ~/perl5) and make
	# the matching lib visible to it.
	PERLCRITIC=""
	PERLCRITIC_PERL5LIB=${PERL5LIB:-}
	PERL_LOCAL_LIB=${PERL_LOCAL_LIB:-${HOME:-}/perl5}
	if command -v perlcritic >/dev/null 2>&1; then
		PERLCRITIC=$(command -v perlcritic)
	elif [ -x "$PERL_LOCAL_LIB/bin/perlcritic" ]; then
		PERLCRITIC="$PERL_LOCAL_LIB/bin/perlcritic"
		PERLCRITIC_PERL5LIB="$PERL_LOCAL_LIB/lib/perl5${PERLCRITIC_PERL5LIB:+:$PERLCRITIC_PERL5LIB}"
	fi

	if [ -n "$PERLCRITIC" ]; then
		PERLCRITIC_SEVERITY=${PERLCRITIC_SEVERITY:-5}
		find "$ROOT_DIR" \
			\( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.git/*" \) \
			-prune -o -type f \
			\( -name '*.pl' -o -name '*.pm' \
			-o -name '*.t' -o -name '*.psgi' \) \
			-print |
			while IFS= read -r f; do
				[ -n "$f" ] || continue
				set +e
				critic_out=$(PERL5LIB="$PERLCRITIC_PERL5LIB" \
					"$PERLCRITIC" --severity "$PERLCRITIC_SEVERITY" \
					"$f" 2>&1)
				critic_rc=$?
				set -e
				if [ "${critic_rc:-0}" -ne 0 ]; then
					printf '%s\n' \
						"[ERROR] Perl::Critic (severity $PERLCRITIC_SEVERITY) in: $f" \
						1>&2
					printf '%s\n' "$critic_out" | sed 's/^/  /' 1>&2
					note_fail "$f"
				fi
			done
	else
		printf '%s\n' \
			"[INFO] perlcritic not installed (PATH or $PERL_LOCAL_LIB/bin);" \
			" skipping Perl::Critic"
	fi

	issues=0
	if [ -f "$TMP_FAILS" ]; then
		issues=$(sort -u "$TMP_FAILS" | wc -l | tr -d ' ')
	fi

	if [ "${issues:-0}" -ne 0 ]; then
		printf '%s\n' \
			"[INFO] Completed with $issues issue(s)" \
			" (format changes, syntax or Perl::Critic errors)"
		printf '%s\n' "[INFO] Affected files (unique, first 200):"
		sort -u "$TMP_FAILS" | sed -n '1,200p' | sed 's/^/  - /'
		exit 2
	fi

	printf '%s\n' "[INFO] Perl checks passed"
	exit 0
}

main() {
	require_cmd uname
	require_cmd find
	require_cmd sed
	require_cmd grep
	require_cmd perl
	run_validate_perl "$@"
}

main "$@"
