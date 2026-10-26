#!/bin/ksh

set -eu

# Log cleanup script
# - Removes *.gz files under /var/log and *.old files
#   under / (root filesystem only).
# - Supports a dry-run mode via DRY_RUN=1 or the
#   --dry-run / -n option to only list files.
# - Requires root unless the run is a dry run.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Reset PATH so base utilities are found even when the script starts from
# cron or another environment with a minimal PATH. /usr/local entries are
# included for locally installed tools.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# If DRY_RUN=1 is set in the environment, the script will only show
# what would be deleted, without actually removing files. Common truthy
# spellings are accepted; anything else means a real run.
typeset DRY_RUN
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac

# Timestamped message helpers. All output goes through ksh's print builtin;
# warnings and errors are sent to stderr, progress to stdout.
log() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}
warn() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >&2
}
error() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2
}

# Only the dry-run flag is accepted. This script has no --help; any other
# argument is an error so a mistyped option cannot be ignored silently.
parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--dry-run | -n)
			DRY_RUN=1
			warn "CLI flag detected:" \
				"using non-default options instead of standard behavior."
			shift
			;;
		*)
			error "Unknown option: $1"
			error "Try: $0 --dry-run"
			exit 1
			;;
		esac
	done
}

# Remove rotated .gz logs under /var/log. The dry-run branch lists the same
# paths that the delete branch would remove, so both use the same find
# expression. A find run that matches nothing still succeeds.
clean_gz_logs() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.gz files under /var/log"
		log "(no deletion will occur):"
		if ! find /var/log -xdev -type f -name '*.gz' -print; then
			error "Failed to list *.gz files under /var/log."
			return 1
		fi
		return
	fi

	log "Deleting *.gz files under /var/log..."
	# -xdev avoids crossing into other filesystems
	# Use -exec rm instead of -delete for better portability
	if ! find /var/log -xdev -type f -name '*.gz' \
		-print -exec rm -f {} +; then
		error "Failed while deleting *.gz files under /var/log."
		return 1
	fi
}

# Remove stale .old files from the root file system. This is the more
# invasive pass: -xdev keeps find on /, skipping separately mounted file
# systems such as /home, /tmp, /usr, and /var, but it still walks every
# directory that lives on the root file system.
clean_old_files() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.old files under /"
		log "(no deletion will occur):"
		if ! find / -xdev -type f -name '*.old' -print; then
			error "Failed to list *.old files under /."
			return 1
		fi
		return
	fi

	log "Deleting *.old files under / (use with care)..."
	# -xdev keeps us on the root filesystem only
	if ! find / -xdev -type f -name '*.old' \
		-print -exec rm -f {} +; then
		error "Failed while deleting *.old files under /."
		return 1
	fi
}

main() {
	parse_args "$@"

	# Deletion touches system log directories, so require root unless the
	# run only lists files. Both cleanup passes are attempted even when
	# one fails, and the exit status reports whether either had errors.
	if [ "$DRY_RUN" -ne 1 ] && [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root unless --dry-run is used."
		exit 1
	fi

	log "----------------------------------------"
	log "Log cleanup started"

	failed=0
	clean_gz_logs || failed=1
	clean_old_files || failed=1
	if [ "$failed" -ne 0 ]; then
		warn "Log cleanup finished with errors."
		exit 1
	fi

	log "Log cleanup finished"
	log "----------------------------------------"
}

main "$@"
