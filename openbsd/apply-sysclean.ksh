#!/bin/ksh
set -eu

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

# Prefer ksh93 when available; fallback to base ksh
if [ -z "${_KSH93_EXECUTED:-}" ] && command -v ksh93 >/dev/null 2>&1; then
    _KSH93_EXECUTED=1 exec ksh93 "$0" "$@"
fi
_KSH93_EXECUTED=1

# Basic PATH (important when run from cron)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Default sysclean output file (can be overridden with SYSCLEAN_OUT env var)
typeset SYSCLEAN_OUT SYSCLEAN_BUNDLED_DIR
SYSCLEAN_OUT="${SYSCLEAN_OUT:-/tmp/sysclean.out}"
SYSCLEAN_BUNDLED_DIR="/usr/local/bin/sysclean"

# Dry-run flag: environment or first argument
typeset DRY_RUN
DRY_RUN=0
case "${1:-}" in
    --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
esac

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

log "----------------------------------------"
log "apply-sysclean started"

#####################################
# -1. Ensure we are running as root #
#####################################
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (superuser)."
    exit 1
fi

###############################################################
# 0. Check that sysclean is installed (and install if needed) #
###############################################################
typeset sysclean_path
sysclean_path="$(command -v sysclean 2>/dev/null || true)"

if [ -n "$sysclean_path" ] && [ -d "$SYSCLEAN_BUNDLED_DIR" ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ "${sysclean_path%/*}" != "$SYSCLEAN_BUNDLED_DIR" ]; then
        log "Removing unused bundled sysclean at $SYSCLEAN_BUNDLED_DIR"
        rm -rf "$SYSCLEAN_BUNDLED_DIR" || warn "failed to remove $SYSCLEAN_BUNDLED_DIR"
    fi
fi

if [ -z "$sysclean_path" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        error "sysclean is not installed and DRY RUN is enabled; not installing automatically."
        exit 1
    fi

    log "sysclean not found in PATH, attempting installation..."

    # 0.1 Try to install via pkg_add if available
    if command -v pkg_add >/dev/null 2>&1; then
        log "Trying to install sysclean with pkg_add..."
        if ! pkg_add -v sysclean; then
            warn "pkg_add sysclean failed."
        else
            log "sysclean installed via pkg_add."
        fi
    else
        log "pkg_add not found in PATH, skipping pkg_add installation."
    fi

    # 0.2 If still not installed, try bundled build: $SYSCLEAN_BUNDLED_DIR && make install
    if ! command -v sysclean >/dev/null 2>&1; then
        if [ -d "$SYSCLEAN_BUNDLED_DIR" ]; then
            log "Trying to install sysclean from $SYSCLEAN_BUNDLED_DIR via make realinstall (BINDIR=/usr/local/bin)..."
            if ! (cd "$SYSCLEAN_BUNDLED_DIR" && make BINDIR=/usr/local/bin realinstall); then
                warn "bundled sysclean make install failed."
            else
                log "sysclean installed from bundled directory."
                sysclean_path="$(command -v sysclean 2>/dev/null || true)"
            fi
        else
            log "No bundled sysclean directory found for local installation."
        fi
    fi

    # 0.3 Final check
    if ! command -v sysclean >/dev/null 2>&1; then
        error "sysclean is still not available after installation attempts; aborting."
        exit 1
    fi
fi

sysclean_path="$(command -v sysclean 2>/dev/null || true)"
if [ -n "$sysclean_path" ] && [ -d "$SYSCLEAN_BUNDLED_DIR" ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ "${sysclean_path%/*}" != "$SYSCLEAN_BUNDLED_DIR" ]; then
        log "Removing unused bundled sysclean at $SYSCLEAN_BUNDLED_DIR"
        rm -rf "$SYSCLEAN_BUNDLED_DIR" || warn "failed to remove $SYSCLEAN_BUNDLED_DIR"
    fi
fi

log "Running sysclean to generate: $SYSCLEAN_OUT"
if ! sysclean > "$SYSCLEAN_OUT" 2>/dev/null; then
    error "sysclean execution failed."
    exit 1
fi
log "sysclean output written to: $SYSCLEAN_OUT"

# Sanity check on the output file
if [ ! -s "$SYSCLEAN_OUT" ]; then
    warn "sysclean output file is empty: $SYSCLEAN_OUT"
fi

########################################
# 1. Remove obsolete files/directories #
########################################
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
        rm -rf -- "$path" || warn "failed to remove: $path"
    else
        log "Skipping non-existent path: $path"
    fi
done

############################
# 2. Remove obsolete users #
############################
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
        userdel "$user" || warn "failed to remove user: $user"
    else
        log "Skipping user (not found): $user"
    fi
done

#############################
# 3. Remove obsolete groups #
#############################
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
        groupdel "$group" || warn "failed to remove group: $group"
    else
        log "Skipping group (not found): $group"
    fi
done

log "apply-sysclean finished"
log "----------------------------------------"
