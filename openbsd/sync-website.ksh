#!/bin/ksh
set -u

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
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Optional: GitHub token file for non-interactive gh usage
GH_TOKEN_FILE="/root/.config/gh_token"
GH_TOKEN=""

if [ -r "$GH_TOKEN_FILE" ]; then
    # Populate GH_TOKEN from a protected file
    GH_TOKEN="$(cat "$GH_TOKEN_FILE" 2>/dev/null || echo "")"
else
    # Not fatal: gh can still work if already authenticated in hosts.yml
    GH_TOKEN=""
fi

# Configuration
REPO_DIR="/var/www/htdocs/cyberpunk-handbook"
BRANCH="main"
SERVICE_NAME="httpd"

# GitHub ZIP URL for fallback (ADJUST THIS)
# Example: https://github.com/user/repo/archive/refs/heads/main.zip
ZIP_URL="https://github.com/daviduhden/cyberpunk-handbook/archive/refs/heads/${BRANCH}.zip"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

echo "----------------------------------------"
log "Sync started"

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
    rmdir "$LOCKDIR" 2>/dev/null || :
}
trap 'cleanup' EXIT INT TERM

###################################
# Function: sync using GitHub CLI #
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

    log "Syncing repository using GitHub CLI (gh repo sync)..."

    # Use GH_TOKEN if we have it; otherwise rely on existing gh authentication
    if [ -n "$GH_TOKEN" ]; then
        if ! env GH_TOKEN="$GH_TOKEN" gh repo sync --branch "$BRANCH" >/dev/null 2>&1; then
            log "Error: gh repo sync failed (with GH_TOKEN)."
            return 1
        fi
    else
        log "Warning: GH_TOKEN is empty; relying on existing gh authentication."
        if ! gh repo sync --branch "$BRANCH" >/dev/null 2>&1; then
            log "Error: gh repo sync failed."
            return 1
        fi
    fi

    # After gh sync, ensure local matches origin/$BRANCH and clean up
    GH_LOCAL_REV=$(git rev-parse @ 2>/dev/null)
    if [ -z "$GH_LOCAL_REV" ]; then
        log "Error: cannot get local revision after gh sync."
        return 1
    fi

    GH_REMOTE_REV=$(git rev-parse "origin/$BRANCH" 2>/dev/null)
    if [ -z "$GH_REMOTE_REV" ]; then
        log "Error: cannot get remote revision after gh sync."
        return 1
    fi

    if [ "$GH_LOCAL_REV" = "$GH_REMOTE_REV" ]; then
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

    GIT_LOCAL_REV=$(git rev-parse @ 2>/dev/null)
    if [ -z "$GIT_LOCAL_REV" ]; then
        log "Error: cannot get local revision."
        return 1
    fi

    GIT_REMOTE_REV=$(git rev-parse "origin/$BRANCH" 2>/dev/null)
    if [ -z "$GIT_REMOTE_REV" ]; then
        log "Error: cannot get remote revision."
        return 1
    fi

    if [ "$GIT_LOCAL_REV" = "$GIT_REMOTE_REV" ]; then
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
    # Check for unzip (required)
    if ! command -v unzip >/dev/null 2>&1; then
        log "Error: unzip is not installed; cannot extract ZIP."
        return 1
    fi

    # Check download tools (curl / wget / ftp on OpenBSD)
    if ! command -v curl >/dev/null 2>&1 && \
       ! command -v wget >/dev/null 2>&1 && \
       ! command -v ftp  >/dev/null 2>&1; then
        log "Error: none of curl, wget, or ftp is installed; cannot download ZIP."
        return 1
    fi

    ZIP_TMPDIR=$(mktemp -d "/tmp/site-sync.XXXXXX" 2>/dev/null)
    if [ ! -d "$ZIP_TMPDIR" ]; then
        log "Error: cannot create temporary directory."
        return 1
    fi

    log "Downloading ZIP from $ZIP_URL ..."
    ZIP_FILE="$ZIP_TMPDIR/source.zip"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$ZIP_URL" -o "$ZIP_FILE"; then
            log "Error: curl download failed."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO "$ZIP_FILE" "$ZIP_URL"; then
            log "Error: wget download failed."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
    else
        # OpenBSD base: ftp
        if ! ftp -o "$ZIP_FILE" "$ZIP_URL"; then
            log "Error: ftp download failed."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
    fi

    log "Unpacking ZIP..."
    ZIP_UNPACK_DIR="$ZIP_TMPDIR/unpacked"
    mkdir -p "$ZIP_UNPACK_DIR"

    if ! unzip -q "$ZIP_FILE" -d "$ZIP_UNPACK_DIR"; then
        log "Error: failed to unzip archive."
        rm -rf "$ZIP_TMPDIR"
        return 1
    fi

    # A GitHub ZIP usually contains a single top-level directory
    ZIP_SRCDIR=$(find "$ZIP_UNPACK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$ZIP_SRCDIR" ]; then
        log "Error: could not determine source directory inside ZIP."
        rm -rf "$ZIP_TMPDIR"
        return 1
    fi

    log "Syncing extracted files into $REPO_DIR ..."
    if command -v rsync >/dev/null 2>&1; then
        # Keep .git if it exists; only sync content from ZIP
        if ! rsync -a --delete --exclude=".git" "$ZIP_SRCDIR"/ "$REPO_DIR"/; then
            log "Error: rsync failed."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
    else
        # Without rsync: delete everything except .git and copy manually
        if ! find "$REPO_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} \; ; then
            log "Error: failed to clean target directory."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
        if ! cp -Rp "$ZIP_SRCDIR"/. "$REPO_DIR"/; then
            log "Error: copy from ZIP to $REPO_DIR failed."
            rm -rf "$ZIP_TMPDIR"
            return 1
        fi
    fi

    rm -rf "$ZIP_TMPDIR"
    log "Repository successfully updated via GitHub ZIP fallback."
    return 0
}

#############################################
# Function: permissions and service restart #
#############################################
post_update_steps() {
    cd "$REPO_DIR" || {
        log "Error: cannot cd to $REPO_DIR for post-update steps."
        return 1
    }

    log "Setting file permissions (excluding .git)..."
    if ! find . -path "./.git" -prune -o -type d -exec chmod 755 {} \; ; then
        log "Error: failed setting directory permissions."
        return 1
    fi
    if ! find . -path "./.git" -prune -o -type f -exec chmod 644 {} \; ; then
        log "Error: failed setting file permissions."
        return 1
    fi

    # Restrict .git to owner only
    if [ -d .git ]; then
        if ! chmod -R 700 .git; then
            log "Warning: could not restrict .git permissions."
        fi
    fi

    log "Restarting web service ($SERVICE_NAME)..."
    if rcctl restart "$SERVICE_NAME"; then
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

# 1) Prefer GitHub CLI if available
if ! sync_with_gh_cli; then
    log "GitHub CLI sync not available or failed. Falling back to plain git..."
    if ! sync_with_git; then
        log "Git sync failed or was not possible. Trying GitHub ZIP fallback..."
        if ! sync_with_github_zip; then
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
