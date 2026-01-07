#!/bin/ksh

set -u

# OpenBSD website synchronization script
# Synchronizes a deployed website directory with a GitHub repository:
#  - Prefers GitHub CLI (gh repo sync) if available
#  - Falls back to plain git fetch/reset if needed
#  - Falls back to downloading a GitHub ZIP if git-based methods fail
#  - Applies safe file permissions and restarts the configured web service
#  - Uses a simple lock directory to avoid concurrent runs (safe for cron)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

###################
# PATH and colors #
###################
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
	GREEN="\033[32m"
	YELLOW="\033[33m"
	RED="\033[31m"
	RESET="\033[0m"
else
	GREEN=""
	YELLOW=""
	RED=""
	RESET=""
fi

log() { print "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${RESET} ✅ $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${RESET} ⚠️ $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${RESET} ❌ $*" >&2; }

has_repo_content() {
	typeset dir="$1"
	[ -d "$dir" ] || return 1
	find "$dir" \
		\( -path "$dir/.git" -o -path "$dir/.git/*" -o -path "$dir/.github" -o -path "$dir/.github/*" \) -prune \
		-o -mindepth 1 -print | head -n 1 | grep -q .
}

##################
# Git LFS helper #
##################
fetch_lfs_files() {
	typeset dir="$1"
	if ! command -v git >/dev/null 2>&1; then
		warn "git not installed; cannot fetch LFS files."
		return 1
	fi
	if ! command -v git-lfs >/dev/null 2>&1; then
		warn "git-lfs not installed; LFS files will not be downloaded."
		return 1
	fi
	if [ -d "$dir/.git" ]; then
		log "Fetching Git LFS files in $dir..."
		git -C "$dir" lfs pull >/dev/null 2>&1 || warn "git lfs pull failed in $dir"
	fi
}

##########################
# GitHub CLI user/config #
##########################
typeset GH_USER GH_HOST REPO_SLUG GH_HOME GH_CONFIG_DIR
GH_USER="${GH_USER:-root}"
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-daviduhden/cypherpunk-handbook}"

if command -v getent >/dev/null 2>&1; then
	GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
	GH_HOME="/home/$GH_USER"
fi

GH_CONFIG_DIR="${GH_HOME}/.config/gh"

run_as_gh_user() {
	if command -v doas >/dev/null 2>&1; then
		doas -u "$GH_USER" "$@"
	else
		su - "$GH_USER" -c "$(print -f '%q ' "$@")"
	fi
}

stage_from_source() {
	typeset srcdir="$1"
	if [ -d "$WWW_DIR/.git" ]; then rm -rf "$WWW_DIR/.git"; fi
	if [ -d "$WWW_DIR/.github" ]; then rm -rf "$WWW_DIR/.github"; fi
	if [ -d "$WWW_DIR/.gitattributes" ]; then rm -rf "$WWW_DIR/.gitattributes"; fi

	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete --exclude=".git" --exclude=".github" --exclude=".gitattributes" "$srcdir"/ "$WWW_DIR"/
	else
		find "$WWW_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".github" ! -name ".gitattributes" -exec rm -rf {} +
		cp -a "$srcdir"/. "$WWW_DIR"/
	fi

	rm -rf "$WWW_DIR/.git" "$WWW_DIR/.github" "$WWW_DIR/.gitattributes"
	return 0
}

######################
# Main configuration #
######################
typeset WWW_DIR BRANCH SERVICE_NAME OWNER_USER OWNER_GROUP WWW_HOST ZIP_URL
WWW_DIR="/var/www/htdocs/cypherpunk-handbook"
WWW_HOST="handbook.uhden.dev"
BRANCH="main"
SERVICE_NAME="httpd"
OWNER_USER="root"
OWNER_GROUP="daemon"

ZIP_URL="https://${GH_HOST}/${REPO_SLUG}/archive/refs/heads/${BRANCH}.zip"

###################
# GitHub CLI sync #
###################
sync_with_gh_cli() {
	typeset repo_slug="$REPO_SLUG" attempt=1 tmpdir stagedir

	if ! command -v gh >/dev/null 2>&1; then return 1; fi
	if ! command -v git >/dev/null 2>&1; then return 1; fi
	[ -f "${GH_CONFIG_DIR}/hosts.yml" ] || return 1
	run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh auth status --hostname "$GH_HOST" >/dev/null 2>&1 || return 1

	tmpdir="$(run_as_gh_user mktemp -d "/tmp/site-sync.XXXXXX")"
	stagedir="$tmpdir/src"

	while [ "$attempt" -le 5 ]; do
		if run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" \
			gh repo clone "$repo_slug" "$stagedir" -- --branch "$BRANCH" --single-branch >/dev/null 2>&1; then
			break
		fi
		log "gh repo clone attempt $attempt failed; retrying..."
		attempt=$((attempt + 1))
	done
	if [ $attempt -gt 5 ]; then
		error "gh repo clone failed"
		rm -rf "$tmpdir"
		return 1
	fi

	if ! has_repo_content "$stagedir"; then
		rm -rf "$tmpdir"
		return 1
	fi

	# Fetch LFS
	fetch_lfs_files "$stagedir"

	stage_from_source "$stagedir"
	rm -rf "$tmpdir"
	log "Repository successfully updated via GitHub CLI."
	return 0
}

############
# Git sync #
############
sync_with_git() {
	typeset origin_url tmpdir stagedir
	if ! command -v git >/dev/null 2>&1; then return 1; fi

	if git -C "$WWW_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		origin_url=$(git -C "$WWW_DIR" remote get-url origin 2>/dev/null || printf '')
	fi
	[ -z "$origin_url" ] && [ -n "$REPO_SLUG" ] && origin_url="https://${GH_HOST}/${REPO_SLUG}.git"
	[ -z "$origin_url" ] && return 1

	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX")
	stagedir="$tmpdir/src"

	git clone --branch "$BRANCH" --single-branch "$origin_url" "$stagedir" >/dev/null 2>&1
	[ ! -d "$stagedir" ] && return 1
	[ ! -d "$stagedir" ] && return 1

	# Fetch LFS
	fetch_lfs_files "$stagedir"

	stage_from_source "$stagedir"
	rm -rf "$tmpdir"
	log "Repository successfully staged via git clone."
	return 0
}

#######################
# GitHub ZIP fallback #
#######################
sync_with_github_zip() {
	typeset tmpdir zipfile unpack_dir srcdir
	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX")
	zipfile="$tmpdir/source.zip"

	if command -v curl >/dev/null 2>&1; then
		curl -fLsS --retry 5 "$ZIP_URL" -o "$zipfile"
	else
		wget -qO "$zipfile" "$ZIP_URL"
	fi

	unpack_dir="$tmpdir/unpacked"
	mkdir -p "$unpack_dir"
	unzip -q "$zipfile" -d "$unpack_dir"
	srcdir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)

	[ -d "$srcdir" ] || return 1

	stage_from_source "$srcdir"
	rm -rf "$tmpdir"
	log "Repository updated via GitHub ZIP fallback."
	return 0
}

#####################
# Post-update steps #
#####################
post_update_steps() {
	cd "$WWW_DIR" || return 1

	log "Setting ownership to ${OWNER_USER}:${OWNER_GROUP}..."
	chown -R "$OWNER_USER":"$OWNER_GROUP" "$WWW_DIR" || warn "ownership failed"

	log "Setting file permissions..."
	find . -type d -exec chmod 755 {} +
	find . -type f -exec chmod 644 {} +

	log "Restarting web service ($SERVICE_NAME)..."
	if ! rcctl -q restart "$SERVICE_NAME"; then
		error "Error restarting $SERVICE_NAME"
		return 1
	fi

	# ACME certificate renewal
	if command -v acme-client >/dev/null 2>&1; then
		log "Running acme-client for ${WWW_HOST}..."
		if acme-client "${WWW_HOST}"; then
			log "acme-client completed, restarting ${SERVICE_NAME}..."
			rcctl -q restart "$SERVICE_NAME" || warn "service restart failed after acme-client"
		else
			warn "acme-client failed for ${WWW_HOST}"
		fi
	else
		warn "acme-client not found; skipping certificate renewal"
	fi
}

########
# Main #
########
main() {
	typeset LOCKDIR

	log "----------------------------------------"
	log "Sync started (user: $GH_USER)"

	[ -d "$WWW_DIR" ] || {
		error "$WWW_DIR does not exist"
		exit 1
	}

	LOCKDIR="$WWW_DIR/.sync.lock"
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		log "Another sync running. Exiting."
		exit 0
	fi

	trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM

	if ! sync_with_gh_cli && ! sync_with_git && ! sync_with_github_zip; then
		error "all sync methods failed."
		exit 1
	fi

	if ! post_update_steps; then
		error "post-update steps failed."
		exit 1
	fi

	log "Sync completed"
	log "----------------------------------------"
}

main "$@"
