#!/bin/ksh
set -eu  # exit on error and on use of unset variables

# PATH for cron / non-interactive shells
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Default sysclean output file (can be overridden with SYSCLEAN_OUT env var)
SYSCLEAN_OUT="${SYSCLEAN_OUT:-/tmp/sysclean.out}"

# Dry-run flag: environment or first argument
DRY_RUN=0
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
log "apply-sysclean started"

###############################################################################
# 0. Check that sysclean is installed and generate the output file
###############################################################################
if ! command -v sysclean >/dev/null 2>&1; then
    log "Error: sysclean is not installed or not in PATH."
    exit 1
fi

log "Running sysclean to generate: $SYSCLEAN_OUT"
if ! sysclean > "$SYSCLEAN_OUT" 2>/dev/null; then
    log "Error: sysclean execution failed."
    exit 1
fi
log "sysclean output written to: $SYSCLEAN_OUT"

# Sanity check on the output file
if [ ! -s "$SYSCLEAN_OUT" ]; then
    log "Warning: sysclean output file is empty: $SYSCLEAN_OUT"
fi

###############################################################################
# 1. Remove obsolete files/directories
###############################################################################
log "Parsing obsolete paths from: $SYSCLEAN_OUT"

# We only consider lines whose first field begins with '/'
# (this also works with 'sysclean -p' output: it uses '/path  pkg').
# We de-duplicate and process each path once.
awk 'NF && $1 ~ /^\// {print $1}' "$SYSCLEAN_OUT" | sort -u | \
while IFS= read -r path; do
    [ -n "$path" ] || continue

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would remove file or directory: $path"
        continue
    fi

    if [ -e "$path" ] || [ -L "$path" ]; then
        log "Removing file or directory: $path"
        rm -rf -- "$path" || log "WARNING: failed to remove: $path"
    else
        log "Skipping non-existent path: $path"
    fi
done

###############################################################################
# 2. Remove obsolete users
###############################################################################
log "Parsing obsolete users from: $SYSCLEAN_OUT"

awk '$1=="@user" {
        sub(/^@user[[:space:]]+/, "", $0);
        split($0, a, ":");
        print a[1];
    }' "$SYSCLEAN_OUT" | sort -u | \
while IFS= read -r user; do
    [ -n "$user" ] || continue

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would remove user: $user"
        continue
    fi

    if id "$user" >/dev/null 2>&1; then
        log "Removing user: $user"
        # Just remove the account; data for daemon users is usually small.
        userdel "$user" || log "WARNING: failed to remove user: $user"
    else
        log "Skipping user (not found): $user"
    fi
done

###############################################################################
# 3. Remove obsolete groups
###############################################################################
log "Parsing obsolete groups from: $SYSCLEAN_OUT"

awk '$1=="@group" {
        sub(/^@group[[:space:]]+/, "", $0);
        split($0, a, ":");
        print a[1];
    }' "$SYSCLEAN_OUT" | sort -u | \
while IFS= read -r group; do
    [ -n "$group" ] || continue

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would remove group: $group"
        continue
    fi

    if getent group "$group" >/dev/null 2>&1; then
        log "Removing group: $group"
        groupdel "$group" || log "WARNING: failed to remove group: $group"
    else
        log "Skipping group (not found): $group"
    fi
done

log "apply-sysclean finished"
echo "----------------------------------------"
