#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Source silent runner and start silent capture (prints output only on error)
if [[ -f "$(dirname "$0")/../lib/silent.bash" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname "$0")/../lib/silent.bash"
	start_silence
elif [[ -f "$(dirname "$0")/../lib/silent" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname "$0")/../lib/silent"
	start_silence
fi

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

# Basic PATH
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Simple colors for messages
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

	# Place global options before expressions; avoid GNU-specific -quit
	if find "$dir" -mindepth 1 \
		\( -path "$dir/.git" -o -path "$dir/.git/*" -o -path "$dir/.github" -o -path "$dir/.github/*" \) -prune \
		-o -print | head -n 1 | grep -q .; then
		return 0
	fi

	return 1
}

#######################################
# GitHub CLI user / config resolution #
#######################################

# GH_USER: system user whose GitHub CLI config (hosts.yml/config.yml) supplies the token.
# GH_HOST: GitHub hostname; override for GHES if needed.
# REPO_SLUG: owner/repo for gh sync fallback.
GH_USER="${GH_USER:-admin}"
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-daviduhden/daviduhden-website}"

# Try to resolve the home directory of GH_USER in a portable way.
if command -v getent >/dev/null 2>&1; then
	GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
	# Fallback: assume a standard /home/$USER layout
	GH_HOME="/home/$GH_USER"
fi

# GitHub CLI config directory (per-user)
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

	# Ensure VCS/CI metadata is absent in the target
	if [ -d "$WWW_DIR/.git" ] && ! rm -rf "$WWW_DIR/.git"; then
		error "failed to remove existing .git in target."
		return 1
	fi
	if [ -d "$WWW_DIR/.github" ] && ! rm -rf "$WWW_DIR/.github"; then
		error "failed to remove existing .github in target."
		return 1
	fi

	if command -v rsync >/dev/null 2>&1; then
		# Exclude VCS/CI metadata that should not be deployed
		if ! rsync -a --delete --exclude=".git" --exclude=".github" "$srcdir"/ "$WWW_DIR"/; then
			error "rsync failed while staging content."
			return 1
		fi
	else
		if ! find "$WWW_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".github" -exec rm -rf {} +; then
			error "failed to clean target directory before copy."
			return 1
		fi
		if ! cp -a "$srcdir"/. "$WWW_DIR"/; then
			error "copy from staging to $WWW_DIR failed."
			return 1
		fi
	fi

	# Remove CI metadata that should not ship
	rm -rf "$WWW_DIR/.git" "$WWW_DIR/.github"

	return 0
}

###############################
# Main synchronization config #
###############################

WWW_DIR="/var/www/daviduhden-website"
WWW_HOST="uhden.dev"
BRANCH="main"
SERVICE_NAME="apache2"
OWNER_USER="www-data"
OWNER_GROUP="www-data"

# GitHub ZIP URL for fallback
# Example: https://github.com/user/repo/archive/refs/heads/main.zip
ZIP_URL="https://${GH_HOST}/${REPO_SLUG}/archive/refs/heads/${BRANCH}.zip"

###################################
# Function: Sync using GitHub CLI #
###################################
sync_with_gh_cli() {
	local repo_slug="" attempt=1 tmpdir stagedir

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
		warn "${GH_CONFIG_DIR}/hosts.yml not found; GitHub CLI is not authenticated for user '$GH_USER'. Skipping gh sync."
		return 1
	fi

	if ! run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh auth status --hostname "$GH_HOST" >/dev/null 2>&1; then
		warn "gh auth status failed for host ${GH_HOST} (config user: ${GH_USER}); skipping gh sync."
		return 1
	fi

	# Determine repo slug from env or fallback
	if [ -n "$REPO_SLUG" ]; then
		repo_slug="$REPO_SLUG"
	else
		repo_slug=$(git -C "$WWW_DIR" remote get-url origin 2>/dev/null | sed -E 's#(git@|https?://)([^/:]+)[:/]([^/]+)/([^/.]+)(\.git)?#\3/\4#')
	fi

	if [ -z "$repo_slug" ]; then
		warn "could not derive repo slug for gh; skipping gh sync."
		return 1
	fi

	tmpdir="$(run_as_gh_user mktemp -d "/tmp/site-sync.XXXXXX")" || {
		error "cannot create temporary directory for gh clone."
		return 1
	}
	stagedir="$tmpdir/src"

	log "Cloning repository via GitHub CLI into staging: ${repo_slug} (branch $BRANCH)..."

	while [ "$attempt" -le 5 ]; do
		if [ "$attempt" -lt 5 ]; then
			if run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh repo clone "$repo_slug" "$stagedir" -- --branch "$BRANCH" --single-branch >/dev/null 2>&1; then
				break
			fi
			log "gh repo clone attempt ${attempt} failed; retrying..."
			continue
		else
			local clone_err_file=""
			clone_err_file=$(mktemp "/tmp/gh-clone-err.XXXXXX") || {
				error "unable to create temporary file for gh clone diagnostics."
				break
			}
			if run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh repo clone "$repo_slug" "$stagedir" -- --branch "$BRANCH" --single-branch 1>/dev/null 2>"$clone_err_file"; then
				rm -f "$clone_err_file"
				break
			fi
			log "gh repo clone attempt ${attempt} failed; error output:"
			while IFS= read -r line; do
				log "    $line"
			done <"$clone_err_file"
			rm -f "$clone_err_file"
		fi
		attempt=$((attempt + 1))
	done

	if [ $attempt -gt 5 ]; then
		error "gh repo clone failed after retries."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! has_repo_content "$stagedir"; then
		warn "Staged repository appears empty; skipping sync."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! stage_from_source "$stagedir"; then
		rm -rf "$tmpdir"
		return 1
	fi

	rm -rf "$tmpdir"
	log "Repository successfully updated via GitHub CLI staging."
	return 0
}

############################
# Function: Sync using GIT #
############################
sync_with_git() {
	local origin_url="" tmpdir="" stagedir=""

	if ! command -v git >/dev/null 2>&1; then
		log "git is not installed or not in PATH. Skipping git sync."
		return 1
	fi

	if git -C "$WWW_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		origin_url=$(git -C "$WWW_DIR" remote get-url origin 2>/dev/null || printf '')
	fi

	if [ -z "$origin_url" ] && [ -n "$REPO_SLUG" ]; then
		origin_url="https://${GH_HOST}/${REPO_SLUG}.git"
	fi

	if [ -z "$origin_url" ]; then
		warn "could not determine git origin URL; skipping git sync."
		return 1
	fi

	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || {
		error "cannot create temporary directory for git sync."
		return 1
	}
	stagedir="$tmpdir/src"

	log "Cloning repository via git into staging directory..."
	if ! git clone --branch "$BRANCH" --single-branch "$origin_url" "$stagedir" >/dev/null 2>&1; then
		error "git clone failed from $origin_url."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! has_repo_content "$stagedir"; then
		warn "Staged repository appears empty; skipping sync."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! stage_from_source "$stagedir"; then
		error "staging from git clone failed."
		rm -rf "$tmpdir"
		return 1
	fi

	rm -rf "$tmpdir"
	log "Repository successfully staged via git clone."
	return 0
}

#######################################
# Function: fallback using GitHub ZIP #
#######################################
sync_with_github_zip() {
	# Check required tools
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		error "neither curl nor wget is installed; cannot download ZIP."
		return 1
	fi
	if ! command -v unzip >/dev/null 2>&1; then
		error "unzip is not installed; cannot extract ZIP."
		return 1
	fi

	local tmpdir
	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || {
		error "cannot create temporary directory."
		return 1
	}

	log "Downloading ZIP from $ZIP_URL ..."
	local zipfile="$tmpdir/source.zip"

	if command -v curl >/dev/null 2>&1; then
		if ! curl -fLsS --retry 5 "$ZIP_URL" -o "$zipfile"; then
			error "curl download failed."
			rm -rf "$tmpdir"
			return 1
		fi
	else
		# Use wget instead of curl
		if ! wget -qO "$zipfile" "$ZIP_URL"; then
			error "wget download failed."
			rm -rf "$tmpdir"
			return 1
		fi
	fi

	log "Unpacking ZIP..."
	local unpack_dir="$tmpdir/unpacked"
	mkdir -p "$unpack_dir"

	if ! unzip -q "$zipfile" -d "$unpack_dir"; then
		error "failed to unzip archive."
		rm -rf "$tmpdir"
		return 1
	fi

	# A GitHub ZIP usually contains a single top-level directory
	local srcdir
	srcdir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
	if [ -z "$srcdir" ]; then
		error "could not determine source directory inside ZIP."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! has_repo_content "$srcdir"; then
		warn "Downloaded repository appears empty; skipping sync."
		rm -rf "$tmpdir"
		return 1
	fi

	if ! stage_from_source "$srcdir"; then
		rm -rf "$tmpdir"
		return 1
	fi

	rm -rf "$tmpdir"
	log "Repository successfully updated via GitHub ZIP fallback."
	return 0
}

#############################################
# Function: Permissions and service restart #
#############################################
post_update_steps() {
	cd "$WWW_DIR" || {
		error "cannot cd to $WWW_DIR for post-update steps."
		return 1
	}

	log "Setting ownership to $OWNER_USER:$OWNER_GROUP..."
	if ! chown -R "$OWNER_USER":"$OWNER_GROUP" "$WWW_DIR"; then
		warn "failed to set ownership to $OWNER_USER:$OWNER_GROUP."
	fi

	log "Setting file permissions (excluding .git)..."
	find . -path "./.git" -prune -o -type d -exec chmod 755 {} + || {
		error "failed setting directory permissions."
		return 1
	}
	find . -path "./.git" -prune -o -type f -exec chmod 644 {} + || {
		error "failed setting file permissions."
		return 1
	}

	# Restrict .git to owner only
	if [ -d .git ]; then
		chmod -R 700 .git || {
			warn "could not restrict .git permissions."
		}
	fi

	log "Restarting web service ($SERVICE_NAME) via systemctl..."
	if systemctl restart "$SERVICE_NAME"; then
		log "$SERVICE_NAME restarted successfully."
	else
		error "Error restarting $SERVICE_NAME."
		return 1
	fi

	return 0
}

LOCKDIR="" # global to ensure cleanup sees it under zsh
main() {
	local SYNC_OK

	log "----------------------------------------"
	log "Sync started (using GitHub CLI config for user: $GH_USER, home: $GH_HOME)"

	if [ ! -d "$WWW_DIR" ]; then
		error "directory $WWW_DIR does not exist."
		exit 1
	fi

	LOCKDIR="$WWW_DIR/.sync.lock"
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		log "Another sync is already running (lock: $LOCKDIR). Exiting."
		exit 0
	fi

	cleanup() {
		if [ -n "${LOCKDIR:-}" ] && [ -d "$LOCKDIR" ]; then
			rmdir "$LOCKDIR" 2>/dev/null || true
		fi
	}
	trap cleanup EXIT INT TERM

	SYNC_OK=0

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
				error "all sync methods (gh, git, ZIP) failed. Aborting."
				exit 1
			fi
		fi
	fi

	# Mark SYNC_OK as used to satisfy static analysis (intentionally referenced)
	: "${SYNC_OK:-}"

	if ! post_update_steps; then
		error "post-update steps failed."
		exit 1
	fi

	if command -v certbot >/dev/null 2>&1; then
		case "$SERVICE_NAME" in
		nginx)
			log "Running certbot for ${WWW_HOST}..."
			if certbot --nginx renew --non-interactive >/dev/null 2>&1; then
				log "certbot completed for ${WWW_HOST}."
				systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || warn "service ${SERVICE_NAME} restart failed after certbot."
			else
				warn "certbot failed for ${WWW_HOST}."
			fi
			;;
		apache2 | apache)
			log "Running certbot for ${WWW_HOST}..."
			if certbot --apache renew --non-interactive >/dev/null 2>&1; then
				log "certbot completed for ${WWW_HOST}."
				systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || warn "service ${SERVICE_NAME} restart failed after certbot."
			else
				warn "certbot failed for ${WWW_HOST}."
			fi
			;;
		*)
			log "Running certbot for ${WWW_HOST}..."
			if certbot certonly --non-interactive -d "${WWW_HOST}" >/dev/null 2>&1; then
				log "certbot completed for ${WWW_HOST}."
				systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || warn "service ${SERVICE_NAME} restart failed after certbot."
			else
				warn "certbot failed for ${WWW_HOST}."
			fi
			;;
		esac
	else
		warn "certbot not found; skipping certificate renewal for ${WWW_HOST}."
	fi

	log "Sync completed"
	log "----------------------------------------"
}

main "$@"
