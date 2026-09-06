#!/bin/sh

set -eu

# fix-permissions.sh
# - Recursively normalizes file modes under DIR (default: current
#   directory) based on the actual *content* of each file, as
#   classified by file(1), not merely on the executable bits that
#   are currently set.
# - Policy:
#     directories                     -> 0755
#     scripts (shell/perl/python/...) -> 0755
#     native executables (ELF, ...)   -> 0755
#     Makefiles                       -> 0755
#     everything else (text, config,
#       documentation, data,
#       non-executable binaries)      -> 0644
# - The .git directory is never touched, symlinks are never
#   followed or modified, and sockets, FIFOs, devices and other
#   special files are ignored. setuid/setgid/sticky bits found on
#   files are preserved.
# - A shebang ("#!") is used as an additional signal for files
#   that file(1) classifies as text but that are really scripts.
#   Heuristic limitation: content is authoritative, so a file that
#   *looks* like a script (script content detected by file(1), or
#   a shebang on its first line) is treated as executable even if
#   it was deliberately non-executable. To keep a script
#   non-executable by design, do not give it a shebang.
# - Usage:
#     ./fix-permissions.sh [-n|--dry-run] [-v|--verbose]
#         [-c|--check] [DIR]
#   Options:
#     -n, --dry-run  Show what would change without applying it.
#     -c, --check    Check only: never modify; exit 1 if any file
#                    has incorrect permissions, 0 otherwise.
#     -v, --verbose  Show every decision, including files whose
#                    permissions are already correct.
#     -h, --help     Show this help.
#   Exit status:
#     0  operation completed (in --check mode: all permissions
#        already correct)
#     1  real errors occurred (failed chmod, ...) or, in --check
#        mode, at least one file has incorrect permissions
#     2  usage error
#
# Notes on portability:
# - file(1) output differs between the GNU (file-5.x) and the
#   OpenBSD implementations (wording, "ASCII text executable" vs
#   "text executable", ELF descriptions, ...). This script only
#   matches stable substrings (e.g. "shell script", "perl script",
#   "elf") and is therefore usable on both.
# - Exact -perm comparisons on both GNU and OpenBSD find(1) take
#   the setuid/setgid/sticky bits into account, so those bits are
#   detected and included in the mode before comparing (they are
#   preserved, never stripped).
# - Git limitation: on filesystems that do not store the
#   executable bit (FAT/NTFS checkouts, some network mounts) or
#   when core.fileMode=false, git will not see mode changes made
#   by this script. A warning is printed at the end in that case.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' \
		"Usage: $0 [-n|--dry-run] [-v|--verbose] [-c|--check]" \
		"        [DIR]" >&2
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

# ------------------------------------------------------------------
# Classification. classify_file() sets CLASS to one of:
#   exec  -> should be 0755
#   data  -> should be 0644
# and DESC to a short human-readable description of the content.
# ------------------------------------------------------------------

classify_file() {
	# $1 = path to a regular file
	ftype=""
	ftype=$(file -b "$1" 2>/dev/null || true)
	lower=$(printf '%s' "$ftype" | tr '[:upper:]' '[:lower:]')
	CLASS='data'
	DESC="$ftype"
	[ -n "$DESC" ] || DESC='unknown content'

	# Makefiles are meant to be invoked directly (make,
	# gmake, bmake), so they get the executable bit even
	# though file(1) calls them "makefile script".
	case "$lower" in
	*makefile*)
		CLASS='exec'
		DESC='makefile'
		return
		;;
	esac

	# Scripts identified by file(1). "C shell script", "tcsh
	# script" and "zsh script" all contain "shell script" or
	# match the generic forms below, so no separate patterns
	# are needed for them.
	case "$lower" in
	*shell\ script*)
		CLASS='exec'
		DESC='shell script'
		return
		;;
	*perl\ script*)
		CLASS='exec'
		DESC='Perl script'
		return
		;;
	*python*script*)
		CLASS='exec'
		DESC='Python script'
		return
		;;
	*awk\ script*)
		CLASS='exec'
		DESC='awk script'
		return
		;;
	*expect\ script* | *tcl*script* | *ruby\ script* | \
		*node*script*)
		CLASS='exec'
		DESC='script'
		return
		;;
	esac

	# Native executables. On OpenBSD, PIE binaries are reported
	# as "shared object"; only treat those as executables when
	# they currently carry an execute bit (libraries stay 0644).
	case "$lower" in
	*elf*)
		case "$lower" in
		*executable* | *pie*)
			CLASS='exec'
			DESC='ELF executable'
			return
			;;
		*shared\ object*)
			if find "$1" -prune -perm -111 -print 2>/dev/null |
				grep -q .; then
				CLASS='exec'
				DESC='ELF executable'
			else
				CLASS='data'
				DESC='ELF shared object'
			fi
			return
			;;
		*)
			CLASS='data'
			DESC='ELF binary'
			return
			;;
		esac
		;;
	esac

	# Windows batch files are not executable on POSIX systems.
	case "$lower" in
	*batch*)
		CLASS='data'
		DESC='batch file'
		return
		;;
	esac

	# Anything else: text/config/data -> 0644, unless a shebang
	# proves it is a script that file(1) misclassified.
	CLASS='data'
}

has_shebang() {
	# $1 = path to a regular file
	first_line=
	if IFS= read -r first_line <"$1" 2>/dev/null; then
		:
	else
		first_line=
	fi
	case "$first_line" in
	'#!'*) return 0 ;;
	*) return 1 ;;
	esac
}

# ------------------------------------------------------------------
# Per-file processing. Returns 0; failures are recorded in the
# state file and never abort the run.
# ------------------------------------------------------------------

process_one() {
	f="$1"

	if [ -d "$f" ]; then
		want=755
		desc="directory"
	elif [ -f "$f" ]; then
		classify_file "$f"
		if [ "$CLASS" = "exec" ]; then
			want=755
		else
			want=644
		fi
		if [ "$CLASS" = "data" ] && has_shebang "$f"; then
			want=755
			desc="script (shebang): ${DESC}"
		else
			desc="$DESC"
		fi
	else
		# Symlinks, sockets, FIFOs, devices: never touched.
		return
	fi

	# Detect setuid/setgid/sticky bits first: they participate
	# in an exact -perm comparison on both GNU and OpenBSD
	# find(1), so the "already correct" test below must use the
	# full mode including them. The resulting mode is built as
	# an octal string (e.g. "4755"), never as decimal
	# arithmetic, so that chmod receives a proper octal mode.
	special=0
	if find "$f" -prune -perm -4000 -print 2>/dev/null |
		grep -q .; then
		special=$((special + 4))
	fi
	if find "$f" -prune -perm -2000 -print 2>/dev/null |
		grep -q .; then
		special=$((special + 2))
	fi
	if [ -d "$f" ] &&
		find "$f" -prune -perm -1000 -print \
			2>/dev/null | grep -q .; then
		special=$((special + 1))
	fi
	if [ "$special" -gt 0 ]; then
		full="${special}${want}"
	else
		full="$want"
	fi

	# Already correct (full mode, including any special bits)?
	# -prune comes first so that a directory with a wrong mode
	# can never match one of its own children.
	if find "$f" -prune -perm "$full" -print 2>/dev/null |
		grep -q .; then
		if [ "$VERBOSE" -eq 1 ]; then
			printf '%s\n' "ok ${full} $f ($desc)"
		fi
		return
	fi
	new="$full"

	# Current mode, for display only. Bit masks are kept octal
	# (leading zero makes them octal literals in the shell).
	old=0
	for bit in 4000 2000 1000 400 200 100 40 20 10 4 2 1; do
		if find "$f" -prune -perm -"$bit" -print 2>/dev/null |
			grep -q .; then
			old=$((old + 0$bit))
		fi
	done

	oldstr=$(printf '%04o' "$old")
	case ${#new} in
	3) newstr="0$new" ;;
	4) newstr="$new" ;;
	esac

	case "$MODE" in
	check)
		printf '%s\n' "${oldstr} -> ${newstr} $f ($desc)"
		printf 'c\n' >>"$STATE"
		;;
	dry)
		printf '%s\n' "would ${oldstr} -> ${newstr} $f ($desc)"
		printf 'c\n' >>"$STATE"
		;;
	fix)
		printf '%s\n' "${oldstr} -> ${newstr} $f ($desc)"
		if chmod "$new" "$f"; then
			printf 'c\n' >>"$STATE"
		else
			printf '%s\n' "[ERROR] chmod $new failed: $f" >&2
			printf 'e\n' >>"$STATE"
		fi
		;;
	esac
}

# ------------------------------------------------------------------
# Worker mode: invoked by find(1) with -exec ... {} +, which passes
# pathnames verbatim via argv (safe for spaces, tabs, newlines and
# quotes) in batches. One invocation processes many files.
# ------------------------------------------------------------------

worker_mode() {
	for f in "$@"; do
		process_one "$f"
	done
	exit 0
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

main() {
	MODE=fix
	VERBOSE=0
	ROOT_DIR=

	while [ $# -gt 0 ]; do
		case "$1" in
		-n | --dry-run) MODE=dry ;;
		-c | --check) MODE=check ;;
		-v | --verbose) VERBOSE=1 ;;
		-h | --help) usage ;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	ROOT_DIR=${1:-.}
	if [ $# -gt 1 ]; then
		printf '%s\n' "[ERROR] too many arguments" >&2
		usage
	fi
	[ -d "$ROOT_DIR" ] || {
		printf '%s\n' \
			"[ERROR] not a directory: $ROOT_DIR" >&2
		exit 2
	}

	require_cmd file
	require_cmd find
	require_cmd chmod
	require_cmd tr
	require_cmd grep
	require_cmd printf

	# The worker self-invocation below must be reachable even
	# when the script was started through a bare relative name.
	SELF=$(command -v "$0" 2>/dev/null || printf '%s' "$0")
	case "$SELF" in
	/*) : ;;
	*) SELF=$(pwd)/$SELF ;;
	esac

	# Trim trailing slashes so that displayed paths stay clean.
	while [ "$ROOT_DIR" != "/" ] &&
		[ "${ROOT_DIR%/}" != "$ROOT_DIR" ]; do
		ROOT_DIR=${ROOT_DIR%/}
	done
	[ -n "$ROOT_DIR" ] || ROOT_DIR=.

	STATE="${TMPDIR:-/tmp}/fix-permissions-$$.txt"
	: >"$STATE"
	trap 'rm -f "$STATE"' EXIT HUP INT TERM

	export MODE VERBOSE STATE

	case "$MODE" in
	check) printf '%s\n' "[INFO] Checking permissions under: $ROOT_DIR" ;;
	dry) printf '%s\n' "[INFO] Dry run under: $ROOT_DIR" ;;
	fix) printf '%s\n' "[INFO] Fixing permissions under: $ROOT_DIR" ;;
	esac

	# The worker self-invocation is driven by find's -exec + so
	# that pathnames are passed through argv; no eval, no
	# word-splitting, no NUL parsing required. .git directories
	# are pruned; only regular files and directories are visited
	# (symlinks and special files are skipped by construction).
	find "$ROOT_DIR" \( -name .git -type d \) -prune -o \
		\( -type d -o -type f \) \
		-exec "$SELF" --worker {} +

	changed=$(grep -c '^c$' "$STATE" 2>/dev/null || true)
	errors=$(grep -c '^e$' "$STATE" 2>/dev/null || true)
	[ -n "$changed" ] || changed=0
	[ -n "$errors" ] || errors=0

	case "$MODE" in
	check)
		printf '%s\n' \
			"[INFO] Permission check completed:" \
			" $changed file(s) with incorrect permissions."
		;;
	dry)
		printf '%s\n' \
			"[INFO] Dry run completed:" \
			" $changed file(s) would change."
		;;
	fix)
		printf '%s\n' \
			"[INFO] Completed: $changed file(s) changed," \
			" $errors error(s)."
		;;
	esac

	# After fixing, show the mode changes git detects. Never run
	# in check/dry-run mode (nothing was modified).
	if [ "$MODE" = "fix" ] &&
		command -v git >/dev/null 2>&1; then
		if git -C "$ROOT_DIR" rev-parse \
			--is-inside-work-tree >/dev/null 2>&1; then
			filemode=$(git -C "$ROOT_DIR" config --get \
				core.fileMode 2>/dev/null || printf 'true')
			if [ "$filemode" = "false" ]; then
				printf '%s\n' \
					"[WARN] core.fileMode is false;" \
					" git will NOT detect mode changes" \
					" in this repository."
			fi
			printf '%s\n' "[INFO] Mode changes visible to git:"
			git -C "$ROOT_DIR" diff --summary
		fi
	fi

	if [ "$MODE" = "check" ]; then
		if [ "$changed" -ne 0 ] || [ "$errors" -ne 0 ]; then
			exit 1
		fi
		exit 0
	fi

	if [ "$errors" -ne 0 ]; then
		exit 1
	fi
	exit 0
}

case "${1:-}" in
--worker)
	shift
	worker_mode "$@"
	;;
esac

main "$@"
