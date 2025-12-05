#!/bin/ksh
set -eu  # exit on error and on use of unset variables

#
# apply-sysclean – automate OpenBSD sysclean(8) findings
#
# This script runs sysclean(8), parses its report, and applies the suggested
# cleanup actions to remove obsolete files, users, and groups left behind
# after system or package updates.
#
# Behavior:
#   - Requires root privileges (must be run as UID 0).
#   - Ensures sysclean(8) is available, installing it via pkg_add(1) or
#     ./sysclean && make install if necessary (unless in dry-run mode).
#   - Generates a sysclean report into $SYSCLEAN_OUT (default: /tmp/sysclean.out).
#   - Removes obsolete paths, users, and groups based on that report.
#
# Options:
#   --dry-run | -n   Show what would be removed without making any changes.
#
# Environment:
#   SYSCLEAN_OUT     Path to the sysclean output file (optional override).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

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
# -1. Ensure we are running as root
###############################################################################
if [ "$(id -u)" -ne 0 ]; then
    log "Error: this script must be run as root (superuser)."
    exit 1
fi

###############################################################################
# 0. Check that sysclean is installed (and install if needed)
###############################################################################
if ! command -v sysclean >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Error: sysclean is not installed and DRY RUN is enabled; not installing automatically."
        exit 1
    fi

    log "sysclean not found in PATH, attempting installation..."

    # 0.1 Try to install via pkg_add if available
    if command -v pkg_add >/dev/null 2>&1; then
        log "Trying to install sysclean with pkg_add..."
        if ! pkg_add -v sysclean; then
            log "WARNING: pkg_add sysclean failed."
        else
            log "sysclean installed via pkg_add."
        fi
    else
        log "pkg_add not found in PATH, skipping pkg_add installation."
    fi

    # 0.2 If still not installed, try local build: ./sysclean && make install
    if ! command -v sysclean >/dev/null 2>&1; then
        if [ -d ./sysclean ]; then
            log "Trying to install sysclean from ./sysclean via make install..."
            if ! (cd ./sysclean && make install); then
                log "WARNING: local sysclean make install failed."
            else
                log "sysclean installed from ./sysclean."
            fi
        else
            log "No ./sysclean directory found for local installation."
        fi
    fi

    # 0.3 Final check
    if ! command -v sysclean >/dev/null 2>&1; then
        log "Error: sysclean is still not available after installation attempts; aborting."
        exit 1
    fi
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
