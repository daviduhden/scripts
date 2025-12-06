#!/bin/ksh
set -eu  # exit on error and on use of unset variables

#
# Log cleanup script
# - Removes *.gz files under /var/log and *.old files under / (root filesystem only).
# - Supports a dry-run mode via DRY_RUN=1 or the --dry-run / -n option to only list files.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# PATH for cron / non-interactive shells
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# If DRY_RUN=1 is set in the environment, the script will only show
# what would be deleted, without actually removing files.
DRY_RUN="${DRY_RUN:-0}"

# Also allow --dry-run or -n as a first argument
case "${1:-}" in
    --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
esac

log() {
    # Simple timestamped logger
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

echo "----------------------------------------"
log "Log cleanup started"

#######################################
# Delete all .gz files under /var/log #
#######################################
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: listing *.gz files under /var/log (no deletion will occur):"
    find /var/log -xdev -type f -name '*.gz' -print || true
else
    log "Deleting *.gz files under /var/log..."
    # -xdev avoids crossing into other filesystems
    # Use -exec rm instead of -delete for better portability
    find /var/log -xdev -type f -name '*.gz' -print -exec rm -f {} + || true
fi

################################################################
# Delete all .old files in the root filesystem (USE WITH CARE) #
################################################################
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: listing *.old files under / (no deletion will occur):"
    find / -xdev -type f -name '*.old' -print || true
else
    log "Deleting *.old files under / (use with care)..."
    # -xdev keeps us on the root filesystem only
    find / -xdev -type f -name '*.old' -print -exec rm -f {} + || true
fi

log "Log cleanup finished"
echo "----------------------------------------"

