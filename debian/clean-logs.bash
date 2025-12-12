#!/bin/bash
set -euo pipefail

# Log cleanup script
# - Removes *.gz files under /var/log and *.old files under / (root filesystem only).
# - Supports a dry-run mode via DRY_RUN=1 or the --dry-run / -n option to only list files.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# PATH for cron / non-interactive shells
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

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
log "----------------------------------------"
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
    find /var/log -xdev -type f -name '*.gz' -print -delete || true
fi

################################################################
# Delete all .old files in the root filesystem (USE WITH CARE) #
################################################################
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: listing *.old files under / (no deletion will occur):"
    find / -xdev -type f -name '*.old' -print || true
else
    log "Deleting *.old files under / (use with care)..."
    # -xdev keeps us on the root filesystem only, so we skip /proc, /sys, etc.
    find / -xdev -type f -name '*.old' -print -delete || true
fi

log "Log cleanup finished"
log "----------------------------------------"
