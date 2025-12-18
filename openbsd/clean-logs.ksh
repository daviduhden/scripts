#!/bin/ksh

# If we are NOT already running under ksh93, try to re-exec with ksh93.
# If ksh93 is not available, fall back to the base ksh (OpenBSD /bin/ksh).
case "${KSH_VERSION-}" in
*93*) : ;; # already ksh93
*)
	if command -v ksh93 >/dev/null 2>&1; then
		exec ksh93 "$0" "$@"
	elif [ -x /usr/local/bin/ksh93 ]; then
		exec /usr/local/bin/ksh93 "$0" "$@"
	elif command -v ksh >/dev/null 2>&1; then
		exec ksh "$0" "$@"
	elif [ -x /bin/ksh ]; then
		exec /bin/ksh "$0" "$@"
	fi
	;;
esac

set -eu

# Log cleanup script
# - Removes *.gz files under /var/log and *.old files under / (root filesystem only).
# - Supports a dry-run mode via DRY_RUN=1 or the --dry-run / -n option to only list files.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# If DRY_RUN=1 is set in the environment, the script will only show
# what would be deleted, without actually removing files.
typeset DRY_RUN
DRY_RUN="${DRY_RUN:-0}"

if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
	GREEN="\033[32m"
	YELLOW="\033[33m"
	RED="\033[31m"
	RESET="\033[0m"
else
	GREEN=""
	YELLOW=""
	RED=""
	RESET=""
fi

log() { print "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${RESET} ✅ $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${RESET} ⚠️ $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${RESET} ❌ $*" >&2; }

parse_args() {
	case "${1:-}" in
	--dry-run | -n)
		DRY_RUN=1
		shift
		;;
	esac
	set -- "$@"
}

clean_gz_logs() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.gz files under /var/log (no deletion will occur):"
		find /var/log -xdev -type f -name '*.gz' -print || true
		return
	fi

	log "Deleting *.gz files under /var/log..."
	# -xdev avoids crossing into other filesystems
	# Use -exec rm instead of -delete for better portability
	find /var/log -xdev -type f -name '*.gz' -print -exec rm -f {} + || true
}

clean_old_files() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.old files under / (no deletion will occur):"
		find / -xdev -type f -name '*.old' -print || true
		return
	fi

	log "Deleting *.old files under / (use with care)..."
	# -xdev keeps us on the root filesystem only
	find / -xdev -type f -name '*.old' -print -exec rm -f {} + || true
}

main() {
	parse_args "$@"

	log "----------------------------------------"
	log "Log cleanup started"

	clean_gz_logs
	clean_old_files

	log "Log cleanup finished"
	log "----------------------------------------"
}

main "$@"
