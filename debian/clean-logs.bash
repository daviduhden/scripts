#!/bin/bash

set -euo pipefail

# Log cleanup script
# - Removes *.gz files under /var/log and *.old files
#   under / (root filesystem only).
# - Supports a dry-run mode via DRY_RUN=1 or the
#   --dry-run / -n option to only list files.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

log() {
	printf '%s [INFO] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
}

# If DRY_RUN=1 is set in the environment, the script will only show
# what would be deleted, without actually removing files.
DRY_RUN="${DRY_RUN:-0}"

parse_args() {
	case "${1:-}" in
	--dry-run | -n)
		DRY_RUN=1
		warn "CLI flag detected;" \
			"using non-default options" \
			"instead of standard behavior."
		shift
		;;
	esac
}

cleanup_gz_logs() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.gz files" \
			"under /var/log (no deletion will occur):"
		if ! find /var/log -xdev \
			-type f -name '*.gz' -print; then
			error "Failed to list *.gz" \
				"files under /var/log."
			return 1
		fi
	else
		log "Deleting *.gz files under /var/log..."
		if ! find /var/log -xdev \
			-type f -name '*.gz' -print -delete; then
			error "Failed while deleting *.gz" \
				"files under /var/log."
			return 1
		fi
	fi
}

cleanup_old_files() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.old files" \
			"under / (no deletion will occur):"
		if ! find / -xdev -type f \
			-name '*.old' -print; then
			error "Failed to list *.old" \
				"files under /."
			return 1
		fi
	else
		log "Deleting *.old files under /" \
			"(use with care)..."
		if ! find / -xdev -type f \
			-name '*.old' -print -delete; then
			error "Failed while deleting *.old" \
				"files under /."
			return 1
		fi
	fi
}

main() {
	parse_args "$@"
	require_cmd find

	log "----------------------------------------"
	log "Log cleanup started"
	cleanup_gz_logs
	cleanup_old_files
	log "Log cleanup finished"
	log "----------------------------------------"
}

#######################################
# Delete all .gz files under /var/log #
#######################################
main "$@"
