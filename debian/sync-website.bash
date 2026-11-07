#!/bin/bash

set -euo pipefail

# Debian website synchronization script
# Synchronizes a deployed website directory with a GitHub repository:
#  - Prefers GitHub CLI (gh repo clone) if available
#  - Falls back to a plain git clone if needed
#  - Falls back to downloading a GitHub ZIP if git-based methods fail
#  - Applies safe file permissions and restarts
#    the configured web service
#  - Uses a simple lock directory to avoid
#    concurrent runs (safe for cron)
#
# Requirements: root privileges, an existing destination directory,
# and at least one working sync path. gh is preferred, then a plain git
# clone, then a direct ZIP download. curl or wget, unzip, find, and a
# running systemd service are needed for the fallback and post-update
# steps.
#
# Side effects:
#  - Replaces the contents of /var/www/daviduhden-website, except the
#    lock directory, with the repository branch contents
#  - Filters repository documentation, VCS metadata, agent instructions,
#    development configuration, tests, and caches from the public destination
#  - Sets ownership to www-data:www-data and modes 755/644
#  - Restarts apache2 and, when certbot is installed, attempts
#    certificate renewal
#
# The branch is fixed to main and the service to apache2; the GitHub
# account, host, and repository slug can be overridden with GH_USER,
# GH_HOST, and REPO_SLUG. The gh path runs as GH_USER (default admin)
# through sudo or su, using that account's gh configuration; the git
# and ZIP fallbacks run as the invoking user.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

###################
# PATH and colors #
###################
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin
PATH="${PATH}:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# Preserve the original path and arguments so require_root can re-exec the
# script through sudo without losing user-supplied options.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	SCRIPT_PATH="${BASH_SOURCE[0]}"
else
	SCRIPT_PATH="$0"
fi
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_ARGS=("$@")

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
ROOT_ENV_VARS=(GH_USER GH_HOST REPO_SLUG)

require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
		exit 1
	fi
	local -a env_args=()
	local name
	for name in "${ROOT_ENV_VARS[@]}"; do
		if [[ -v $name ]]; then
			env_args+=("$name=${!name}")
		fi
	done
	log "Re-executing this script via sudo to gain root privileges..."
	if ((${#env_args[@]} > 0)); then
		exec sudo -- env "${env_args[@]}" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
	fi
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

# Remove only known repository and tooling paths from a staged tree or the
# destination. Keep ordinary Markdown files below the repository root because
# a project may use them as public content.
filter_site_tree() {
	local dir="$1" name path preserve_lock=0
	[ -d "$dir" ] || return 1
	if [ "${2:-}" = "preserve-lock" ]; then
		preserve_lock=1
	fi

	for name in \
		README.md CODE_OF_CONDUCT.md CODEOFCONDUCT.md CONTRIBUTING.md \
		AGENTS.md CLAUDE.md GEMINI.md copilot-instructions.md \
		.gitignore .gitmodules .gitattributes .htmltest.yml \
		.perlcriticrc .stylelintrc.json dprint.json .editorconfig \
		.cursorrules .windsurfrules .aider.conf.yml Makefile \
		.DS_Store; do
		path="$dir/$name"
		if [ -e "$path" ] || [ -L "$path" ]; then
			rm -rf -- "$path" || return 1
		fi
	done
	if [ "$preserve_lock" -eq 0 ] &&
		{ [ -e "$dir/.sync.lock" ] || [ -L "$dir/.sync.lock" ]; }; then
		rm -rf -- "$dir/.sync.lock" || return 1
	fi

	for name in \
		.git .github .agents .claude .codex .cursor .vscode .idea \
		.devcontainer .zed .cache \
		.htmltest node_modules t tests docs tmp tmp_archive build dist; do
		path="$dir/$name"
		if [ -e "$path" ] || [ -L "$path" ]; then
			rm -rf -- "$path" || return 1
		fi
	done

	# Agent instruction files and editor/cache directories can also occur below
	# the root. Do not use a blanket hidden-file or Markdown exclusion here.
	find "$dir" -mindepth 1 \
		\( -path "$dir/.sync.lock" -o -path "$dir/.sync.lock/*" \) -prune -o \
		-type d \( -name .git -o -name .github -o -name .agents \
		-o -name .claude -o -name .codex \
		-o -name .cursor -o -name .vscode -o -name .idea \
		-o -name .devcontainer -o -name .zed -o -name .cache \
		-o -name .htmltest -o -name node_modules \) \
		-prune -exec rm -rf {} + || return 1
	find "$dir" -mindepth 1 \
		\( -path "$dir/.sync.lock" -o -path "$dir/.sync.lock/*" \) -prune -o \
		\( -type f -o -type l \) \
		\( -name .git -o -name .github -o -name .agents -o -name .claude \
		-o -name .codex -o -name .cursor -o -name .vscode -o -name .idea \
		-o -name .devcontainer -o -name .zed -o -name .cache \
		-o -name .htmltest -o -name node_modules \
		-o -name AGENTS.md -o -name CLAUDE.md -o -name GEMINI.md \
		-o -name copilot-instructions.md -o -name .gitignore \
		-o -name .gitmodules -o -name .gitattributes \
		-o -name .htmltest.yml -o -name .perlcriticrc \
		-o -name .stylelintrc.json -o -name dprint.json \
		-o -name .editorconfig -o -name .DS_Store \
		-o -name '*.swp' -o -name '*.swo' -o -name '*~' \
		-o -name '*.bak' -o -name '*.orig' -o -name '*.rej' \) \
		-exec rm -f {} + || return 1
	if [ -e "$dir/scripts/openbsd-tools.txt" ] ||
		[ -L "$dir/scripts/openbsd-tools.txt" ]; then
		rm -f -- "$dir/scripts/openbsd-tools.txt" || return 1
	fi
	if [ -e "$dir/scripts/validate-agent-knowledge.pl" ] ||
		[ -L "$dir/scripts/validate-agent-knowledge.pl" ]; then
		rm -f -- "$dir/scripts/validate-agent-knowledge.pl" || return 1
	fi
}

# Treat the staged tree as usable only when it has at least one entry
# outside the VCS metadata directories (.git, .github).
has_repo_content() {
	local dir="$1" listing
	[ -d "$dir" ] || return 1
	# Capture the whole listing instead of piping into head/grep:
	# with pipefail, an early-exiting consumer kills find with
	# SIGPIPE and the pipeline reports 141 even though the tree
	# is not empty.
	listing="$(find "$dir" \
		\( -path "$dir/.git" \
		-o -path "$dir/.git/*" \
		-o -path "$dir/.github" \
		-o -path "$dir/.github/*" \) \
		-prune -o -mindepth 1 -print -quit 2>/dev/null)"
	[ -n "$listing" ]
}

##################
# Git LFS helper #
##################
# Pull Git LFS objects when both git and git-lfs are available. LFS
# failures are warnings; the checkout may still contain pointer files.
fetch_lfs_files() {
	local dir="$1"
	if ! command -v git >/dev/null 2>&1; then
		warn "git not installed; cannot fetch LFS files."
		return 1
	fi
	if ! command -v git-lfs >/dev/null 2>&1; then
		warn "git-lfs not installed;" \
			"LFS files will not be downloaded."
		return 1
	fi
	if [ -d "$dir/.git" ]; then
		log "Fetching Git LFS files in $dir..."
		# The clone may belong to GH_USER while this process runs as root;
		# trust only this exact path instead of disabling ownership checks.
		git -c safe.directory="$dir" -C "$dir" lfs pull >/dev/null 2>&1 ||
			warn "git lfs pull failed in $dir"
	fi
}

###########################
# GitHub CLI / Git config #
###########################
GH_USER="${GH_USER:-admin}"
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-daviduhden/daviduhden-website}"

# Resolve the deployment account's home directory. getent is preferred
# because the home may differ from /home/<user>; the fallback is only
# a guess when getent is unavailable.
if command -v getent >/dev/null 2>&1; then
	if ! GH_HOME="$(getent passwd "$GH_USER" |
		awk -F: '{print $6}')"; then
		GH_HOME=""
	fi
else
	GH_HOME="/home/$GH_USER"
fi
if [ -z "$GH_HOME" ] || [ ! -d "$GH_HOME" ]; then
	error "Cannot determine a usable home directory for user '$GH_USER'."
	exit 1
fi

GH_CONFIG_DIR="${GH_HOME}/.config/gh"

# Execute a command as the deployment account. sudo is used when
# present; otherwise su -c receives a shell-quoted command string built
# with printf %q.
run_as_gh_user() {
	if command -v sudo >/dev/null 2>&1; then
		sudo -u "$GH_USER" "$@"
	else
		su - "$GH_USER" -c "$(printf '%q ' "$@")"
	fi
}

# A static site should not publish symbolic links: a symlink to a local file
# can expose that file if the web server follows links. Reject the deployment
# instead of trying to guess which links are safe.
reject_source_symlinks() {
	local dir="$1" links
	links=$(find "$dir" -type l -print 2>/dev/null)
	if [ -n "$links" ]; then
		error "Refusing to publish symbolic links from $dir:"
		printf '%s\n' "$links" >&2
		return 1
	fi
}

# Replace the deployed content with a filtered checkout. rsync and the cp
# fallback receive the same sanitized source; known excluded paths are also
# removed from the old destination before --delete can preserve stale excludes.
# The synchronization lock remains in place for the duration of this run.
copy_from_source() {
	local srcdir="$1"
	filter_site_tree "$srcdir" || return 1
	reject_source_symlinks "$srcdir" || return 1
	filter_site_tree "$WWW_DIR" preserve-lock || return 1
	if ! has_repo_content "$srcdir"; then
		warn "staged source has no publishable website files"
		return 1
	fi

	if command -v rsync >/dev/null 2>&1; then
		if ! rsync -a --delete --safe-links \
			--exclude="/.git" \
			--exclude="/.github" \
			--exclude="/.agents" \
			--exclude="/.claude" \
			--exclude="/.codex" \
			--exclude="/.cursor" \
			--exclude="/.vscode" \
			--exclude="/.idea" \
			--exclude="/.devcontainer" \
			--exclude="/.zed" \
			--exclude="/.gitignore" \
			--exclude="/.gitmodules" \
			--exclude="/.gitattributes" \
			--exclude="/README.md" \
			--exclude="/CODE_OF_CONDUCT.md" \
			--exclude="/CODEOFCONDUCT.md" \
			--exclude="/CONTRIBUTING.md" \
			--exclude="/AGENTS.md" \
			--exclude="/CLAUDE.md" \
			--exclude="/GEMINI.md" \
			--exclude="/copilot-instructions.md" \
			--exclude="/.htmltest.yml" \
			--exclude="/.perlcriticrc" \
			--exclude="/.stylelintrc.json" \
			--exclude="/dprint.json" \
			--exclude="/.editorconfig" \
			--exclude="/.cursorrules" \
			--exclude="/.windsurfrules" \
			--exclude="/.aider.conf.yml" \
			--exclude="/Makefile" \
			--exclude="/.DS_Store" \
			--exclude="*.swp" \
			--exclude="*.swo" \
			--exclude="*~" \
			--exclude="*.bak" \
			--exclude="*.orig" \
			--exclude="*.rej" \
			--exclude="/docs/" \
			--exclude="/t/" \
			--exclude="/tests/" \
			--exclude="/tmp/" \
			--exclude="/tmp_archive/" \
			--exclude="/.cache/" \
			--exclude="/.htmltest/" \
			--exclude="/node_modules/" \
			--exclude="/build/" \
			--exclude="/dist/" \
			--exclude="/scripts/openbsd-tools.txt" \
			--exclude="/scripts/validate-agent-knowledge.pl" \
			--exclude=".sync.lock" \
			"$srcdir"/ "$WWW_DIR"/; then
			return 1
		fi
	else
		if ! find "$WWW_DIR" -mindepth 1 \
			-maxdepth 1 \
			! -name ".sync.lock" \
			-exec rm -rf {} +; then
			return 1
		fi
		if ! cp -a "$srcdir"/. "$WWW_DIR"/; then
			return 1
		fi
	fi

	filter_site_tree "$WWW_DIR" preserve-lock || return 1
	return 0
}

# Atomic publication is opt-in and requires an already configured symlink
# docroot. The compatible copy path remains the default.
ATOMIC_DEPLOY=0
ATOMIC_RELEASE=""
ATOMIC_PREVIOUS=""

check_atomic_target() {
	if [ ! -L "$WWW_DIR" ] || [ ! -d "$WWW_DIR" ]; then
		error 'Atomic mode requires an existing symlink docroot.'
		return 1
	fi
}

replace_public_link() {
	local target="$1" parent linkdir
	parent="${WWW_DIR%/*}"
	linkdir=$(mktemp -d "$parent/.site-link.XXXXXX") || return 1
	if ! ln -s "$target" "$linkdir/current"; then
		rmdir "$linkdir"
		return 1
	fi
	if ! mv -Tf -- "$linkdir/current" "$WWW_DIR"; then
		rm -f "$linkdir/current"
		rmdir "$linkdir"
		return 1
	fi
	rmdir "$linkdir"
}

restart_web_service() {
	systemctl restart "$SERVICE_NAME"
}

rollback_publication() {
	if [ -n "$ATOMIC_PREVIOUS" ]; then
		if replace_public_link "$ATOMIC_PREVIOUS"; then
			ATOMIC_PREVIOUS=""
			restart_web_service || error 'Could not restart restored website'
		else
			error "Could not roll back public link to $ATOMIC_PREVIOUS"
		fi
	fi
}

stage_from_source() {
	local srcdir="$1" destination status
	if [ "${ATOMIC_DEPLOY:-0}" -eq 0 ]; then
		copy_from_source "$srcdir"
		return $?
	fi
	check_atomic_target || return 1
	destination="$WWW_DIR"
	ATOMIC_RELEASE=$(mktemp -d "${WWW_DIR%/*}/.site-release.XXXXXX") || return 1
	WWW_DIR="$ATOMIC_RELEASE"
	status=0
	copy_from_source "$srcdir" || status=$?
	WWW_DIR="$destination"
	if [ "$status" -ne 0 ]; then
		rm -rf "$ATOMIC_RELEASE"
		ATOMIC_RELEASE=""
		return "$status"
	fi
	if ! chown -R "$OWNER_USER:$OWNER_GROUP" "$ATOMIC_RELEASE" ||
		! find "$ATOMIC_RELEASE" -type d -exec chmod 755 {} + ||
		! find "$ATOMIC_RELEASE" -type f -exec chmod 644 {} +; then
		rm -rf -- "$ATOMIC_RELEASE"
		ATOMIC_RELEASE=""
		return 1
	fi
	ATOMIC_PREVIOUS=$(cd "$WWW_DIR" && pwd -P) || {
		rm -rf -- "$ATOMIC_RELEASE"
		ATOMIC_RELEASE=""
		return 1
	}
	if ! replace_public_link "$ATOMIC_RELEASE"; then
		rm -rf -- "$ATOMIC_RELEASE"
		ATOMIC_RELEASE=""
		return 1
	fi
	log "Published $ATOMIC_RELEASE; previous release retained at $ATOMIC_PREVIOUS"
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

ZIP_URL="https://${GH_HOST}/${REPO_SLUG}"
ZIP_URL="${ZIP_URL}/archive/refs/heads/${BRANCH}.zip"

###################
# GitHub CLI sync #
###################
# Preferred path: clone the branch with the deployment account's gh
# credentials, retrying up to five times. Returns non-zero when gh,
# git, or the account configuration is missing, when authentication
# fails, when the clone never succeeds, or when the checkout has no
# content. The temporary tree is created by and owned by GH_USER.
sync_with_gh_cli() {
	local repo_slug="$REPO_SLUG" attempt=1
	local tmpdir stagedir

	if ! command -v gh >/dev/null 2>&1; then return 1; fi
	if ! command -v git >/dev/null 2>&1; then return 1; fi
	[ -f "${GH_CONFIG_DIR}/hosts.yml" ] || return 1
	run_as_gh_user env \
		GH_CONFIG_DIR="$GH_CONFIG_DIR" \
		GH_HOST="$GH_HOST" \
		gh auth status --hostname "$GH_HOST" \
		>/dev/null 2>&1 || return 1

	tmpdir="$(run_as_gh_user mktemp \
		-d "/tmp/site-sync.XXXXXX")" || return 1
	stagedir="$tmpdir/src"

	while [ "$attempt" -le 5 ]; do
		if run_as_gh_user env \
			GH_CONFIG_DIR="$GH_CONFIG_DIR" \
			GH_HOST="$GH_HOST" \
			gh repo clone "$repo_slug" \
			"$stagedir" -- --branch "$BRANCH" \
			--single-branch \
			>/dev/null 2>&1; then
			break
		fi
		log "gh repo clone attempt $attempt" \
			"failed; retrying..."
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

	fetch_lfs_files "$stagedir"

	if ! stage_from_source "$stagedir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	rm -rf "$tmpdir"
	log "Repository successfully updated via GitHub CLI."
	return 0
}

############
# Git sync #
############
# Fallback path: clone with plain git. Reuse the destination's existing
# origin when it is a work tree, otherwise build an HTTPS URL from
# REPO_SLUG and GH_HOST. Unlike the gh path, this clone does not use
# GH_USER's gh configuration.
sync_with_git() {
	local origin_url="" tmpdir stagedir
	if ! command -v git >/dev/null 2>&1; then
		return 1
	fi

	if git -C "$WWW_DIR" rev-parse \
		--is-inside-work-tree >/dev/null 2>&1; then
		origin_url=$(git -C "$WWW_DIR" \
			remote get-url origin 2>/dev/null ||
			printf '')
	fi
	[ -z "$origin_url" ] &&
		[ -n "$REPO_SLUG" ] &&
		origin_url="https://${GH_HOST}/${REPO_SLUG}.git"
	[ -z "$origin_url" ] && return 1

	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || return 1
	stagedir="$tmpdir/src"

	if ! git clone --branch "$BRANCH" \
		--single-branch "$origin_url" \
		"$stagedir" >/dev/null 2>&1; then
		rm -rf "$tmpdir"
		return 1
	fi
	[ ! -d "$stagedir" ] && {
		rm -rf "$tmpdir"
		return 1
	}

	fetch_lfs_files "$stagedir"

	if ! stage_from_source "$stagedir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	rm -rf "$tmpdir"
	log "Repository successfully staged via git clone."
	return 0
}

#######################
# GitHub ZIP fallback #
#######################
# Last resort: download the branch archive from GitHub and unpack it.
# curl is preferred over wget. GitHub archives contain one top-level
# directory, which is used as the staging source.
sync_with_github_zip() {
	local tmpdir zipfile unpack_dir srcdir listfile
	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || return 1
	zipfile="$tmpdir/source.zip"

	if command -v curl >/dev/null 2>&1; then
		if ! curl -fLsS --retry 5 --proto '=https' \
			--proto-redir '=https' "$ZIP_URL" -o "$zipfile"; then
			rm -rf "$tmpdir"
			return 1
		fi
	else
		if ! wget -qO "$zipfile" "$ZIP_URL"; then
			rm -rf "$tmpdir"
			return 1
		fi
	fi

	unpack_dir="$tmpdir/unpacked"
	if ! mkdir -p "$unpack_dir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	# Reject absolute and parent-relative archive names before extraction.
	listfile="$tmpdir/entries.txt"
	if ! unzip -Z1 "$zipfile" >"$listfile"; then
		rm -rf "$tmpdir"
		return 1
	fi
	if awk 'BEGIN { bad=0 } /^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad }' \
		"$listfile" || [ "$(wc -l <"$listfile")" -gt 200000 ]; then
		error "Refusing an archive with unsafe or excessive entries."
		rm -rf "$tmpdir"
		return 1
	fi
	if ! unzip -q "$zipfile" -d "$unpack_dir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	if [ -n "$(find "$unpack_dir" -type l -print 2>/dev/null)" ]; then
		error "Refusing an archive that contains symbolic links."
		rm -rf "$tmpdir"
		return 1
	fi
	if ! du -sk "$unpack_dir" | awk '$1 > 2097152 { exit 1 }'; then
		error "Refusing an archive larger than 2 GiB."
		rm -rf "$tmpdir"
		return 1
	fi
	# sed reads the whole stream, so find never receives SIGPIPE
	# (unlike `find ... | head -n 1`, which returns 141 under
	# pipefail for large trees).
	srcdir=$(find "$unpack_dir" -mindepth 1 \
		-maxdepth 1 -type d | sed -n '1p')

	[ -d "$srcdir" ] || {
		rm -rf "$tmpdir"
		return 1
	}

	if ! stage_from_source "$srcdir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	rm -rf "$tmpdir"
	log "Repository updated via GitHub ZIP fallback."
	return 0
}

#####################
# Post-update steps #
#####################
# Normalize ownership and modes, restart the web service, then try
# certificate renewal if certbot is installed. Ownership errors are
# warnings, permission and restart errors are fatal. certbot failures
# are ignored and do not fail the sync.
post_update_steps() {
	cd "$WWW_DIR" || return 1

	log "Setting ownership to $OWNER_USER:$OWNER_GROUP..."
	chown -R "$OWNER_USER":"$OWNER_GROUP" "$WWW_DIR" ||
		{
			error "Failed to set website ownership."
			return 1
		}

	log "Setting file permissions..."
	find . -type d -exec chmod 755 {} + || return 1
	find . -type f -exec chmod 644 {} + || return 1

	log "Restarting web service ($SERVICE_NAME)..."
	if ! systemctl restart "$SERVICE_NAME"; then
		error "Error restarting $SERVICE_NAME"
		return 1
	fi

	if command -v certbot >/dev/null 2>&1; then
		log "Running certbot..."
		case "$SERVICE_NAME" in
		nginx)
			if certbot --nginx renew \
				--non-interactive \
				>/dev/null 2>&1; then
				systemctl restart "$SERVICE_NAME"
			fi
			;;
		apache2 | apache)
			if certbot --apache renew \
				--non-interactive \
				>/dev/null 2>&1; then
				systemctl restart "$SERVICE_NAME"
			fi
			;;
		*)
			if certbot certonly \
				--non-interactive \
				-d "$WWW_HOST" \
				>/dev/null 2>&1; then
				systemctl restart "$SERVICE_NAME"
			fi
			;;
		esac
	else
		warn "certbot not installed;" \
			"skipping certificate renewal"
	fi
	return 0
}

########
# Main #
########
LOCKDIR=""
# Create the lock directory atomically and record the PID. A lock with
# a recorded PID whose process no longer exists is treated as stale and
# reacquired. A lock without a PID is left in place (fail closed) and
# causes this run to skip syncing.
cleanup_lock() {
	rollback_publication
	if [ "${LOCK_OWNED:-0}" -eq 1 ] && [ ! -L "$LOCKDIR" ] &&
		[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ]; then
		rm -f "$LOCKDIR/pid"
		rmdir "$LOCKDIR" 2>/dev/null || true
		LOCK_OWNED=0
	fi
}

acquire_lock() {
	# Respect a lock left by the previous in-docroot locking scheme.
	if [ -e "$WWW_DIR/.sync.lock" ] || [ -L "$WWW_DIR/.sync.lock" ]; then
		warn 'Legacy in-docroot lock exists; verify its owner before removing it.'
		return 1
	fi
	LOCKDIR="${WWW_DIR%/*}/.${WWW_DIR##*/}.sync.lock"
	# Never steal locks automatically: PID reuse and concurrent stale-lock
	# recovery cannot be made safe with a PID file alone.
	if ! mkdir -m 0700 "$LOCKDIR" 2>/dev/null; then return 1; fi
	LOCK_OWNED=1
	if ! printf '%s\n' "$$" >"$LOCKDIR/pid"; then
		rmdir "$LOCKDIR" 2>/dev/null || true
		LOCK_OWNED=0
		return 1
	fi
	return 0
}

main() {
	case "${1:-}" in
	--atomic)
		ATOMIC_DEPLOY=1
		shift
		;;
	--check-atomic)
		check_atomic_target
		return $?
		;;
	esac
	[ "$#" -eq 0 ] || {
		error 'Usage: sync-website [--atomic|--check-atomic]'
		exit 1
	}
	if [ "$ATOMIC_DEPLOY" -eq 1 ]; then check_atomic_target || exit 1; fi
	require_root
	log "----------------------------------------"
	log "Sync started (user: $GH_USER)"

	[ -d "$WWW_DIR" ] || {
		error "$WWW_DIR does not exist."
		exit 1
	}

	if ! acquire_lock; then
		log "Another sync already running; exiting."
		exit 0
	fi
	# Always release the lock, including on interruption or failure.
	trap 'cleanup_lock' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	# Try the methods in order and stop at the first success. A sync
	# method stages content into WWW_DIR; post_update_steps then
	# finalizes ownership, modes, and the service.
	if ! sync_with_gh_cli &&
		! sync_with_git &&
		! sync_with_github_zip; then
		error "all sync methods failed."
		exit 1
	fi

	if ! post_update_steps; then
		error "post-update steps failed."
		exit 1
	fi

	ATOMIC_PREVIOUS=""
	log "Sync completed"
	log "----------------------------------------"
}

main "$@"
