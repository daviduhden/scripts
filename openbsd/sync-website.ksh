#!/bin/ksh
set -u

# Synchronizes a deployed website directory with a GitHub repository:
#  - Prefers GitHub CLI (gh repo sync) if available
#  - Falls back to plain git fetch/reset if needed
#  - Falls back to downloading a GitHub ZIP if git-based methods fail
#  - Applies safe file permissions and restarts the configured web service
#  - Uses a simple lock directory to avoid concurrent runs (safe for cron)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Prefer ksh93 when available for better POSIX compliance; fallback to base ksh
if [ -z "${_KSH93_EXECUTED:-}" ] && command -v ksh93 >/dev/null 2>&1; then
    _KSH93_EXECUTED=1 exec ksh93 "$0" "$@"
fi
_KSH93_EXECUTED=1

# Basic PATH (important when run from cron)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# GitHub token file for non-interactive gh usage
GH_TOKEN_FILE="/root/.config/gh_token"
GH_TOKEN=""
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-}"

if [ -r "$GH_TOKEN_FILE" ]; then
    GH_TOKEN="$(cat "$GH_TOKEN_FILE" 2>/dev/null || echo "")"
else
    GH_TOKEN=""
fi

# Configuration
REPO_DIR="/var/www/htdocs/cyberpunk-handbook"
BRANCH="main"
SERVICE_NAME="httpd"

# GitHub ZIP URL for fallback (ADJUST THIS)
# Example: https://github.com/user/repo/archive/refs/heads/main.zip
ZIP_URL="https://github.com/daviduhden/cyberpunk-handbook/archive/refs/heads/${BRANCH}.zip"

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

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
    typeset repo_slug="" attempt=1

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

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Warning: $REPO_DIR is not a git repository; GitHub CLI sync is not possible."
        return 1
    fi

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        log "Switching to branch $BRANCH (current: $CURRENT_BRANCH)"
        if ! git checkout "$BRANCH"; then
            log "Error: could not checkout branch $BRANCH before gh sync."
            return 1
        fi
    fi

    if [ -n "$REPO_SLUG" ]; then
        repo_slug="$REPO_SLUG"
    else
        repo_slug=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@|https?://)([^/:]+)[:/]([^/]+)/([^/.]+)(\.git)?#\3/\4#')
    fi

    if [ -z "$repo_slug" ]; then
        log "Warning: could not derive repo slug for gh; skipping gh sync."
        return 1
    fi

    log "Syncing repository using GitHub CLI (gh repo sync) for ${repo_slug}..."

    while [ $attempt -le 2 ]; do
        if [ -n "$GH_TOKEN" ]; then
            if env GH_TOKEN="$GH_TOKEN" GH_HOST="$GH_HOST" gh auth status --hostname "$GH_HOST" >/dev/null 2>&1 && \
               env GH_TOKEN="$GH_TOKEN" GH_HOST="$GH_HOST" gh repo sync "$repo_slug" --branch "$BRANCH" >/dev/null 2>&1; then
                break
            fi
        else
            if GH_HOST="$GH_HOST" gh auth status --hostname "$GH_HOST" >/dev/null 2>&1 && \
               GH_HOST="$GH_HOST" gh repo sync "$repo_slug" --branch "$BRANCH" >/dev/null 2>&1; then
                break
            fi
        fi
        log "gh repo sync attempt ${attempt} failed; retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ $attempt -gt 2 ]; then
        log "Error: gh repo sync failed after retries."
        return 1
    fi

    if ! git fetch origin "$BRANCH"; then
        log "Error: git fetch failed after gh sync."
        return 1
    fi

    LOCAL=$(git rev-parse @ 2>/dev/null || echo "")
    REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "")

    if [ -z "$LOCAL" ] || [ -z "$REMOTE" ]; then
        log "Error: could not determine revisions after gh sync."
        return 1
    fi

    if [ "$LOCAL" != "$REMOTE" ]; then
        log "Forcing local branch to match origin/$BRANCH after gh sync..."
        if ! git reset --hard "origin/$BRANCH"; then
            log "Error: git reset failed after gh sync."
            return 1
        fi
        if ! git clean -fd; then
            log "Error: git clean failed after gh sync."
            return 1
        fi
    fi

    log "Repository successfully updated via GitHub CLI."
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

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Warning: $REPO_DIR is not a git repository."
        return 1
    fi

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

    LOCAL=$(git rev-parse @ 2>/dev/null || echo "")
    REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "")

    if [ -z "$LOCAL" ] || [ -z "$REMOTE" ]; then
        log "Error: cannot get revisions."
        return 1
    fi

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
    if ! command -v unzip >/dev/null 2>&1; then
        log "Error: unzip is not installed; cannot extract ZIP."
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 && \
       ! command -v wget >/dev/null 2>&1 && \
       ! command -v ftp  >/dev/null 2>&1; then
        log "Error: none of curl, wget, or ftp is installed; cannot download ZIP."
        return 1
    fi

    TMPDIR=$(mktemp -d "/tmp/site-sync.XXXXXX" 2>/dev/null)
    if [ ! -d "$TMPDIR" ]; then
        log "Error: cannot create temporary directory."
        return 1
    fi

    log "Downloading ZIP from $ZIP_URL ..."
    ZIP_FILE="$TMPDIR/source.zip"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$ZIP_URL" -o "$ZIP_FILE"; then
            log "Error: curl download failed."
            rm -rf "$TMPDIR"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO "$ZIP_FILE" "$ZIP_URL"; then
            log "Error: wget download failed."
            rm -rf "$TMPDIR"
            return 1
        fi
    else
        if ! ftp -o "$ZIP_FILE" "$ZIP_URL"; then
            log "Error: ftp download failed."
            rm -rf "$TMPDIR"
            return 1
        fi
    fi

    log "Unpacking ZIP..."
    ZIP_UNPACK_DIR="$TMPDIR/unpacked"
    mkdir -p "$ZIP_UNPACK_DIR"

    if ! unzip -q "$ZIP_FILE" -d "$ZIP_UNPACK_DIR"; then
        log "Error: failed to unzip archive."
        rm -rf "$TMPDIR"
        return 1
    fi

    ZIP_SRCDIR=$(find "$ZIP_UNPACK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$ZIP_SRCDIR" ]; then
        log "Error: could not determine source directory inside ZIP."
        rm -rf "$TMPDIR"
        return 1
    fi

    log "Syncing extracted files into $REPO_DIR ..."
    if command -v rsync >/dev/null 2>&1; then
        if ! rsync -a --delete --exclude=".git" "$ZIP_SRCDIR"/ "$REPO_DIR"/; then
            log "Error: rsync failed."
            rm -rf "$TMPDIR"
            return 1
        fi
    else
        if ! find "$REPO_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} \; ; then
            log "Error: failed to clean target directory."
            rm -rf "$TMPDIR"
            return 1
        fi
        if ! cp -Rp "$ZIP_SRCDIR"/. "$REPO_DIR"/; then
            log "Error: copy from ZIP to $REPO_DIR failed."
            rm -rf "$TMPDIR"
            return 1
        fi
    fi

    rm -rf "$TMPDIR"
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

if ! post_update_steps; then
    log "ERROR: post-update steps failed."
    exit 1
fi

log "Sync completed"
echo "----------------------------------------"
