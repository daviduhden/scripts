#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Debian website synchronization script
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
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

has_repo_content() {
	local dir="$1"
	[ -d "$dir" ] || return 1
	if find "$dir" -mindepth 1 \
		\( -path "$dir/.git" -o -path "$dir/.git/*" -o -path "$dir/.github" -o -path "$dir/.github/*" \) -prune \
		-o -print | head -n 1 | grep -q .; then
		return 0
	fi
	return 1
}

##################
# Git LFS helper #
##################
fetch_lfs_files() {
	local dir="$1"
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

###########################
# GitHub CLI / Git config #
###########################
GH_USER="${GH_USER:-admin}"
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-daviduhden/daviduhden-website}"

if command -v getent >/dev/null 2>&1; then
	GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
	GH_HOME="/home/$GH_USER"
fi

GH_CONFIG_DIR="${GH_HOME}/.config/gh"

run_as_gh_user() {
	if command -v sudo >/dev/null 2>&1; then
		sudo -u "$GH_USER" "$@"
	else
		su - "$GH_USER" -c "$(printf '%q ' "$@")"
	fi
}

stage_from_source() {
	local srcdir="$1"
	[ -d "$WWW_DIR/.git" ] && rm -rf "$WWW_DIR/.git"
	[ -d "$WWW_DIR/.github" ] && rm -rf "$WWW_DIR/.github"

	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete --exclude=".git" --exclude=".github" "$srcdir"/ "$WWW_DIR"/
	else
		find "$WWW_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".github" -exec rm -rf {} +
		cp -a "$srcdir"/. "$WWW_DIR"/
	fi

	rm -rf "$WWW_DIR/.git" "$WWW_DIR/.github"
	return 0
}

######################
# Main configuration #
######################
WWW_DIR="/var/www/daviduhden-website"
WWW_HOST="uhden.dev"
BRANCH="main"
SERVICE_NAME="apache2"
OWNER_USER="www-data"
OWNER_GROUP="www-data"

ZIP_URL="https://${GH_HOST}/${REPO_SLUG}/archive/refs/heads/${BRANCH}.zip"

###################
# GitHub CLI sync #
###################
sync_with_gh_cli() {
	local repo_slug="$REPO_SLUG" attempt=1 tmpdir stagedir

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
	local origin_url tmpdir stagedir
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
	local tmpdir zipfile unpack_dir srcdir
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

	log "Setting ownership to $OWNER_USER:$OWNER_GROUP..."
	chown -R "$OWNER_USER":"$OWNER_GROUP" "$WWW_DIR" || warn "failed ownership"

	log "Setting permissions..."
	find . -path "./.git" -prune -o -type d -exec chmod 755 {} + || warn "dir perms failed"
	find . -path "./.git" -prune -o -type f -exec chmod 644 {} + || warn "file perms failed"
	if [ -d .git ]; then
		if ! chmod -R 700 .git; then
			warn "git perms failed"
		fi
	fi

	log "Restarting web service ($SERVICE_NAME)..."
	systemctl restart "$SERVICE_NAME" || error "service restart failed"

	# Certbot renewal
	if command -v certbot >/dev/null 2>&1; then
		case "$SERVICE_NAME" in
		nginx)
			if certbot --nginx renew --non-interactive >/dev/null 2>&1; then systemctl restart "$SERVICE_NAME"; fi
			;;
		apache2 | apache)
			if certbot --apache renew --non-interactive >/dev/null 2>&1; then systemctl restart "$SERVICE_NAME"; fi
			;;
		*)
			if certbot certonly --non-interactive -d "$WWW_HOST" >/dev/null 2>&1; then systemctl restart "$SERVICE_NAME"; fi
			;;
		esac
	fi
	return 0
}

########
# Main #
########
LOCKDIR=""
main() {
	log "----------------------------------------"
	log "Sync started (user: $GH_USER)"

	[ -d "$WWW_DIR" ] || {
		error "$WWW_DIR does not exist."
		exit 1
	}

	LOCKDIR="$WWW_DIR/.sync.lock"
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		log "Another sync already running; exiting."
		exit 0
	fi
	trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

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
