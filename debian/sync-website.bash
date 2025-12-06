#!/bin/bash
set -uo pipefail

#
# Synchronizes a deployed website directory with a GitHub repository:
#  - Prefers GitHub CLI (gh repo sync) if available
#  - Falls back to plain git fetch/reset if needed
#  - Falls back to downloading a GitHub ZIP if git-based methods fail
#  - Applies safe file permissions and restarts the configured web service
#  - Uses a simple lock directory to avoid concurrent runs (safe for cron)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

#######################################
# GitHub CLI user / config resolution #
#######################################

# GH_USER: system user that owns the GitHub CLI configuration (~/.config/gh/hosts.yml)
# You can override this via environment (e.g. GH_USER="david")
GH_USER="${GH_USER:-admin}"

# Try to resolve the home directory of GH_USER in a portable way.
if command -v getent >/dev/null 2>&1; then
    GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
    # Fallback: assume a standard /home/$USER layout
    GH_HOME="/home/$GH_USER"
fi

# GitHub CLI config directory (per-user)
GH_CONFIG_DIR="${GH_HOME}/.config/gh"

###############################
# Main synchronization config #
###############################

REPO_DIR="/var/www/daviduhden-website"
BRANCH="main"
SERVICE_NAME="apache2"

# GitHub ZIP URL for fallback (ADJUST THIS)
# Example: https://github.com/user/repo/archive/refs/heads/main.zip
ZIP_URL="https://github.com/daviduhden/daviduhden-website/archive/refs/heads/${BRANCH}.zip"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

echo "----------------------------------------"
log "Sync started (using GitHub CLI config for user: $GH_USER, home: $GH_HOME)"

# Ensure repository directory exists
if [ ! -d "$REPO_DIR" ]; then
    log "Error: directory $REPO_DIR does not exist."
    exit 1
fi

# Simple lock to avoid concurrent runs
LOCKDIR="$REPO_DIR/.sync.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "Another sync is already running (lock: $LOCKDIR). Exiting."
    exit 0
fi

cleanup() {
    rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

###################################
# Function: Sync using GitHub CLI #
###################################
sync_with_gh_cli() {
    if ! command -v gh >/dev/null 2>&1; then
        log "GitHub CLI (gh) is not installed; skipping gh sync."
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log "git is not installed; GitHub CLI sync is not possible."
        return 1
    fi

    # Ensure GitHub CLI config exists for GH_USER
    if [ ! -f "${GH_CONFIG_DIR}/hosts.yml" ]; then
        log "Warning: ${GH_CONFIG_DIR}/hosts.yml not found; GitHub CLI is not authenticated for user '$GH_USER'. Skipping gh sync."
        return 1
    fi

    cd "$REPO_DIR" || {
        log "Error: cannot cd to $REPO_DIR."
        return 1
    }

    # Ensure this is a git repository
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Warning: $REPO_DIR is not a git repository; GitHub CLI sync is not possible."
        return 1
    fi

    # Ensure we are on the correct branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        log "Switching to branch $BRANCH (current: $CURRENT_BRANCH)"
        if ! git checkout "$BRANCH"; then
            log "Error: could not checkout branch $BRANCH before gh sync."
            return 1
        fi
    fi

    log "Syncing repository using GitHub CLI (gh repo sync) with config of user '$GH_USER'..."

    # Force gh to use GH_USER's config directory
    if ! GH_CONFIG_DIR="$GH_CONFIG_DIR" gh repo sync --branch "$BRANCH" >/dev/null 2>&1; then
        log "Error: gh repo sync failed."
        return 1
    fi

    # After gh sync, force local to match origin/$BRANCH and clean up
    LOCAL=$(git rev-parse @ 2>/dev/null) || {
        log "Error: cannot get local revision after gh sync."
        return 1
    }
    REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || {
        log "Error: cannot get remote revision after gh sync."
        return 1
    }

    if [ "$LOCAL" = "$REMOTE" ]; then
        log "Repository is up to date after GitHub CLI sync."
    else
        log "Forcing local branch to match origin/$BRANCH after GitHub CLI sync..."
        if ! git reset --hard "origin/$BRANCH"; then
            log "Error: git reset failed after gh sync."
            return 1
        fi
        if ! git clean -fd; then
            log "Error: git clean failed after gh sync."
            return 1
        fi
        log "Repository successfully updated via GitHub CLI."
    fi

    return 0
}

############################
# Function: Sync using GIT #
############################
sync_with_git() {
    if ! command -v git >/dev/null 2>&1; then
        log "git is not installed or not in PATH. Skipping git sync."
        return 1
    fi

    cd "$REPO_DIR" || {
        log "Error: cannot cd to $REPO_DIR."
        return 1
    }

    # Check that this is a git repository
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Warning: $REPO_DIR is not a git repository."
        return 1
    fi

    # Ensure we are on the correct branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        log "Switching to branch $BRANCH (current: $CURRENT_BRANCH)"
        if ! git checkout "$BRANCH"; then
            log "Error: could not checkout branch $BRANCH."
            return 1
        fi
    fi

    log "Fetching latest changes via git..."
    if ! git fetch origin "$BRANCH"; then
        log "Error: git fetch failed."
        return 1
    fi

    LOCAL=$(git rev-parse @ 2>/dev/null)                 || { log "Error: cannot get local revision.";  return 1; }
    REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || { log "Error: cannot get remote revision."; return 1; }

    if [ "$LOCAL" = "$REMOTE" ]; then
        log "No new changes in the repository."
        return 0
    fi

    log "New changes found. Updating via git..."
    if ! git reset --hard "origin/$BRANCH"; then
        log "Error: git reset failed."
        return 1
    fi
    if ! git clean -fd; then
        log "Error: git clean failed."
        return 1
    fi

    log "Repository successfully updated via git."
    return 0
}

#######################################
# Function: fallback using GitHub ZIP #
#######################################
sync_with_github_zip() {
    # Check required tools
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log "Error: neither curl nor wget is installed; cannot download ZIP."
        return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        log "Error: unzip is not installed; cannot extract ZIP."
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || {
        log "Error: cannot create temporary directory."
        return 1
    }

    log "Downloading ZIP from $ZIP_URL ..."
    local zipfile="$tmpdir/source.zip"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$ZIP_URL" -o "$zipfile"; then
            log "Error: curl download failed."
            rm -rf "$tmpdir"
            return 1
        fi
    else
        # Use wget instead of curl
        if ! wget -qO "$zipfile" "$ZIP_URL"; then
            log "Error: wget download failed."
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    log "Unpacking ZIP..."
    local unpack_dir="$tmpdir/unpacked"
    mkdir -p "$unpack_dir"

    if ! unzip -q "$zipfile" -d "$unpack_dir"; then
        log "Error: failed to unzip archive."
        rm -rf "$tmpdir"
        return 1
    fi

    # A GitHub ZIP usually contains a single top-level directory
    local srcdir
    srcdir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$srcdir" ]; then
        log "Error: could not determine source directory inside ZIP."
        rm -rf "$tmpdir"
        return 1
    fi

    log "Syncing extracted files into $REPO_DIR ..."
    # Prefer rsync if available
    if command -v rsync >/dev/null 2>&1; then
        # Keep .git if it exists; only sync content from ZIP
        if ! rsync -a --delete --exclude=".git" "$srcdir"/ "$REPO_DIR"/; then
            log "Error: rsync failed."
            rm -rf "$tmpdir"
            return 1
        fi
    else
        # Without rsync: delete everything except .git and copy manually
        if ! find "$REPO_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +; then
            log "Error: failed to clean target directory."
            rm -rf "$tmpdir"
            return 1
        fi
        if ! cp -a "$srcdir"/. "$REPO_DIR"/; then
            log "Error: copy from ZIP to $REPO_DIR failed."
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    rm -rf "$tmpdir"
    log "Repository successfully updated via GitHub ZIP fallback."
    return 0
}

#############################################
# Function: Permissions and service restart #
#############################################
post_update_steps() {
    cd "$REPO_DIR" || {
        log "Error: cannot cd to $REPO_DIR for post-update steps."
        return 1
    }

    log "Setting file permissions (excluding .git)..."
    find . -path "./.git" -prune -o -type d -exec chmod 755 {} + || {
        log "Error: failed setting directory permissions."
        return 1
    }
    find . -path "./.git" -prune -o -type f -exec chmod 644 {} + || {
        log "Error: failed setting file permissions."
        return 1
    }

    # Restrict .git to owner only
    if [ -d .git ]; then
        chmod -R 700 .git || {
            log "Warning: could not restrict .git permissions."
        }
    fi

    log "Restarting web service ($SERVICE_NAME)..."
    if systemctl restart "$SERVICE_NAME"; then
        log "$SERVICE_NAME restarted successfully."
    else
        log "Error restarting $SERVICE_NAME."
        return 1
    fi

    return 0
}

#############
# MAIN FLOW #
#############

SYNC_OK=0

# 1) Prefer GitHub CLI if available
if sync_with_gh_cli; then
    SYNC_OK=1
else
    log "GitHub CLI sync not available or failed. Falling back to plain git..."
    if sync_with_git; then
        SYNC_OK=1
    else
        log "Git sync failed or was not possible. Trying GitHub ZIP fallback..."
        if sync_with_github_zip; then
            SYNC_OK=1
        else
            log "ERROR: all sync methods (gh, git, ZIP) failed. Aborting."
            exit 1
        fi
    fi
fi

# 2) Permissions and service restart
if ! post_update_steps; then
    log "ERROR: post-update steps failed."
    exit 1
fi

log "Sync completed"
echo "----------------------------------------"
