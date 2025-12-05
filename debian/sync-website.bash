#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Configuration
REPO_DIR="/var/www/daviduhden-website"
BRANCH="main"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

echo "----------------------------------------"
log "Sync started"

# Ensure git is available
if ! command -v git >/dev/null 2>&1; then
    log "Error: git is not installed or not in PATH."
    exit 1
fi

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
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM

cd "$REPO_DIR"

# Check that this is a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Error: $REPO_DIR is not a git repository."
    exit 1
fi

# Ensure we are on the correct branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "")
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    log "Switching to branch $BRANCH (current: $CURRENT_BRANCH)"
    git checkout "$BRANCH"
fi

log "Fetching latest changes..."
git fetch origin "$BRANCH"

LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
    log "No new changes in the repository."
else
    log "New changes found. Updating..."
    git reset --hard "origin/$BRANCH"
    git clean -fd
    log "Repository successfully updated."

    # Permissions (excluding .git):
    #  - directories: 755
    #  - files:       644
    log "Setting file permissions..."
    find . -path "./.git" -prune -o -type d -exec chmod 755 {} +
    find . -path "./.git" -prune -o -type f -exec chmod 644 {} +

    # Restrict .git to the owner only
    if [ -d .git ]; then
        chmod -R 700 .git
    fi

    # Restart web service
    log "Restarting web service (apache2)..."
    if systemctl restart apache2; then
        log "apache2 restarted successfully."
    else
        log "Error restarting apache2."
        exit 1
    fi
fi

log "Sync completed"
echo "----------------------------------------"
