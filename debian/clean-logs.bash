#!/bin/bash

set -euo pipefail

# Log cleanup script
# - Removes *.gz files under /var/log and *.old files in a bounded set of
#   system directories (default: /var/log /var/tmp /tmp /etc).
# - Only removes *.old files older than OLDER_THAN days (default: 7).
# - Supports a dry-run mode via DRY_RUN=1 or --dry-run / -n.
# - A real deletion requires --force; this prevents an accidental cron run
#   from deleting fresh configuration backups.
#
# Requirements: find; root privileges for a real run (dry-run works as
# any user).
#
# Deletion is immediate and does not create backups. The -xdev find
# option keeps each search on the filesystem containing the starting
# path, so neither scan descends into separate mounts. A failure in
# either cleanup pass is reported and makes the script exit non-zero
# after both passes have been attempted.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Preserve the original path and arguments so require_root can re-exec the
# script through sudo without losing user-supplied options.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	SCRIPT_PATH="${BASH_SOURCE[0]}"
else
	SCRIPT_PATH="$0"
fi
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_ARGS=("$@")

log() {
	printf '%s [INFO] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
# Log an error without exiting; callers decide whether to fail.
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

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
ROOT_ENV_VARS=(DRY_RUN OLDER_THAN FORCE OLD_ROOTS)

require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
		exit 1
	fi
	local -a env_args=()
	local name
	for name in "${ROOT_ENV_VARS[@]}"; do
		if [[ -v $name ]]; then
			env_args+=("$name=${!name}")
		fi
	done
	log "Re-executing this script via sudo to gain root privileges..."
	if ((${#env_args[@]} > 0)); then
		exec sudo -- env "${env_args[@]}" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
	fi
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

# If DRY_RUN=1 is set in the environment, the script will only show
# what would be deleted, without actually removing files.
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac
OLDER_THAN="${OLDER_THAN:-7}"
FORCE="${FORCE:-0}"
OLD_ROOTS="${OLD_ROOTS:-/var/log /var/tmp /tmp /etc}"

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--dry-run | -n)
			DRY_RUN=1
			warn "CLI flag detected;" \
				"using non-default options" \
				"instead of standard behavior."
			shift
			;;
		--older-than)
			[[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || {
				error "--older-than requires a non-negative day count."
				exit 2
			}
			OLDER_THAN=$2
			shift 2
			;;
		--force)
			FORCE=1
			shift
			;;
		*)
			error "Unknown option: $1"
			error "Try: $0 --dry-run | --force [--older-than DAYS]"
			exit 1
			;;
		esac
	done
}

# Print or delete compressed logs below /var/log. -xdev stops find at
# filesystem boundaries, so logs on separately mounted filesystems
# are not touched.
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

# Print or delete *.old files on the root filesystem. -xdev prevents
# this scan from crossing into other mounts; without it, a full-root
# search would be considerably broader.
cleanup_old_files() {
	local root
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY RUN: listing *.old files older than" \
			"${OLDER_THAN} day(s) under: ${OLD_ROOTS}"
		for root in $OLD_ROOTS; do
			[ -d "$root" ] || continue
			if ! find "$root" -xdev -type f \
				-name '*.old' -mtime +"$OLDER_THAN" -print; then
				error "Failed to list *.old files under ${root}."
				return 1
			fi
		done
	else
		log "Deleting *.old files older than" \
			"${OLDER_THAN} day(s) under: ${OLD_ROOTS}"
		for root in $OLD_ROOTS; do
			[ -d "$root" ] || continue
			if ! find "$root" -xdev -type f \
				-name '*.old' -mtime +"$OLDER_THAN" -print -delete; then
				error "Failed while deleting *.old files under ${root}."
				return 1
			fi
		done
	fi
}

main() {
	parse_args "$@"
	require_cmd find

	if [[ $DRY_RUN -ne 1 && $FORCE -ne 1 ]]; then
		error "Real deletion requires --force;" \
			"use --dry-run to preview."
		exit 1
	fi
	# Dry-run only lists paths, so it is allowed without elevation.
	if [[ $DRY_RUN -ne 1 ]]; then
		require_root
	fi

	log "----------------------------------------"
	log "Log cleanup started"
	failed=0
	# Run both passes even if the first fails, then report the overall
	# result.
	cleanup_gz_logs || failed=1
	cleanup_old_files || failed=1
	if [ "$failed" -ne 0 ]; then
		warn "Log cleanup finished with errors."
		exit 1
	fi
	log "Log cleanup finished"
	log "----------------------------------------"
}

#######################################
# Run log cleanup; honors dry-run.    #
#######################################
main "$@"
