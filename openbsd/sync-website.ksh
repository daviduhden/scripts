#!/bin/ksh

set -eu
# pipefail makes any failing stage of a pipeline determine the pipeline
# status. Probe first: not every ksh version supports the option, and a
# failed `set -o` must not abort the script.
if (set -o pipefail) >/dev/null 2>&1; then
	set -o pipefail
fi

# OpenBSD website synchronization script
# Synchronizes a deployed website directory with a GitHub repository:
#  - Prefers GitHub CLI (gh repo sync) if available
#  - Falls back to plain git fetch/reset if needed
#  - Falls back to downloading a GitHub ZIP if git-based methods fail
#  - Applies safe file permissions and restarts
#    the configured web service
#  - Uses a simple lock directory to avoid concurrent
#    runs (safe for cron)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

###################
# PATH and colors #
###################
# Reset PATH for unattended runs (cron, rc.d) where the inherited
# environment may be minimal. /usr/local entries cover gh, git, and rsync.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Timestamped message helpers built on ksh's print. Progress goes to stdout;
# warnings and errors go to stderr.
log() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}
warn() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >&2
}
error() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2
}

# Decide whether a cloned tree has anything worth deploying. .git and
# .github are pruned, but any other entry at any depth counts, including
# dotfiles, so a repo whose only entries are those metadata directories is
# rejected.
has_repo_content() {
	typeset dir="$1" listing
	[ -d "$dir" ] || return 1
	# Capture the whole listing instead of piping into head/grep:
	# with pipefail (set below), an early-exiting consumer kills
	# find with SIGPIPE and the pipeline would report 141 even
	# though the tree is not empty.
	listing=$(find "$dir" \
		\( -path "$dir/.git" -o \
		-path "$dir/.git/*" -o \
		-path "$dir/.github" -o \
		-path "$dir/.github/*" \) -prune \
		-o -mindepth 1 -print 2>/dev/null)
	[ -n "$listing" ]
}

##################
# Git LFS helper #
##################
# Best-effort LFS support: without git, git-lfs, or a .git directory the
# checkout is still staged, and a failed pull only produces a warning.
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
		git -C "$dir" lfs pull >/dev/null 2>&1 ||
			warn "git lfs pull failed in $dir"
	fi
}

##########################
# GitHub CLI user/config #
##########################
# Deploy account and repository. gh runs as GH_USER (root by default)
# because that account owns the GitHub credentials in GH_CONFIG_DIR. The
# home directory is resolved from the password database when possible.
typeset GH_USER GH_HOST REPO_SLUG GH_HOME GH_CONFIG_DIR
GH_USER="${GH_USER:-root}"
GH_HOST="${GH_HOST:-github.com}"
REPO_SLUG="${REPO_SLUG:-daviduhden/cypherpunk-handbook}"

if command -v getent >/dev/null 2>&1; then
	GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
	# OpenBSD has no getent(1). Read the passwd database directly so
	# root resolves to /root instead of the /home/root guess.
	GH_HOME="$(awk -F: -v user="$GH_USER" \
		'$1 == user { print $6; exit }' /etc/passwd)"
	# If the lookup returns nothing, use the conventional /home/<user>
	# path.
	[ -n "$GH_HOME" ] || GH_HOME="/home/$GH_USER"
fi
if [ -z "$GH_HOME" ]; then
	error "Cannot determine the home directory for user '$GH_USER'."
	exit 1
fi

# gh reads its hosts.yml and token from here; the path is passed explicitly
# to every gh invocation instead of relying on the elevated user's default
# HOME.
GH_CONFIG_DIR="${GH_HOME}/.config/gh"

# Run a command as the account that owns the gh credentials. doas -u is
# preferred; without doas, su - gives a login shell and the command string is
# assembled with each argument single-quoted.
run_as_gh_user() {
	if command -v doas >/dev/null 2>&1; then
		doas -u "$GH_USER" "$@"
	else
		# OpenBSD ksh's print builtin has no printf-style %q,
		# so build the su command string with portable sed-based
		# single-quote escaping and print -r --.
		typeset i cmdstr=""
		for i in "$@"; do
			cmdstr="${cmdstr} '$(print -r -- "$i" |
				sed "s/'/'\\\\''/g")'"
		done
		su - "$GH_USER" -c "$cmdstr"
	fi
}

# Replace the deployed tree with srcdir. Metadata left by an earlier sync is
# removed first; rsync -a --delete mirrors the source, and the fallback empties
# WWW_DIR before copying. The exclusions preserve the lock directory and keep
# VCS metadata out of the deployed tree.
stage_from_source() {
	typeset srcdir="$1"
	if [ -d "$WWW_DIR/.git" ]; then rm -rf "$WWW_DIR/.git"; fi
	if [ -d "$WWW_DIR/.github" ]; then rm -rf "$WWW_DIR/.github"; fi
	if [ -e "$WWW_DIR/.gitattributes" ]; then
		rm -f "$WWW_DIR/.gitattributes"
	fi

	if command -v rsync >/dev/null 2>&1; then
		if ! rsync -a --delete \
			--exclude=".git" \
			--exclude=".github" \
			--exclude=".gitattributes" \
			--exclude=".sync.lock" \
			"$srcdir"/ "$WWW_DIR"/; then
			return 1
		fi
	else
		if ! find "$WWW_DIR" -mindepth 1 -maxdepth 1 \
			! -name ".git" \
			! -name ".github" \
			! -name ".gitattributes" \
			! -name ".sync.lock" \
			-exec rm -rf {} +; then
			return 1
		fi
		if ! cp -a "$srcdir"/. "$WWW_DIR"/; then
			return 1
		fi
	fi

	if ! rm -rf "$WWW_DIR/.git" \
		"$WWW_DIR/.github" \
		"$WWW_DIR/.gitattributes"; then
		return 1
	fi
	return 0
}

######################
# Main configuration #
######################
# Deployment target. The script takes no arguments, so change these values
# here (or override GH_USER, GH_HOST, and REPO_SLUG in the environment) to
# deploy a different site or service.
typeset WWW_DIR BRANCH SERVICE_NAME OWNER_USER
typeset OWNER_GROUP WWW_HOST ZIP_URL LOCKDIR
WWW_DIR="/var/www/htdocs/cypherpunk-handbook"
WWW_HOST="handbook.uhden.dev"
BRANCH="main"
SERVICE_NAME="httpd"
OWNER_USER="root"
OWNER_GROUP="daemon"

ZIP_URL="https://${GH_HOST}/${REPO_SLUG}""\
/archive/refs/heads/${BRANCH}.zip"

###################
# GitHub CLI sync #
###################
# Preferred method: clone the branch into a temporary directory with gh.
# Return 1 when gh, git, saved credentials, or usable content are missing, so
# main can fall back to the next method.
sync_with_gh_cli() {
	typeset repo_slug="$REPO_SLUG" attempt=1 tmpdir stagedir

	if ! command -v gh >/dev/null 2>&1; then return 1; fi
	if ! command -v git >/dev/null 2>&1; then return 1; fi
	[ -f "${GH_CONFIG_DIR}/hosts.yml" ] || return 1
	run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" \
		GH_HOST="$GH_HOST" \
		gh auth status --hostname "$GH_HOST" \
		>/dev/null 2>&1 || return 1

	tmpdir="$(run_as_gh_user mktemp -d \
		"/tmp/site-sync.XXXXXX")" || return 1
	stagedir="$tmpdir/src"

	# Retry a failed clone up to five times before giving up.
	while [ "$attempt" -le 5 ]; do
		if run_as_gh_user env \
			GH_CONFIG_DIR="$GH_CONFIG_DIR" \
			GH_HOST="$GH_HOST" \
			gh repo clone "$repo_slug" "$stagedir" \
			-- --branch "$BRANCH" --single-branch \
			>/dev/null 2>&1; then
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
# Plain git fallback: reuse the origin of an existing checkout when there is
# one, otherwise derive the URL from REPO_SLUG and GH_HOST.
sync_with_git() {
	typeset origin_url="" tmpdir stagedir
	if ! command -v git >/dev/null 2>&1; then return 1; fi

	if git -C "$WWW_DIR" rev-parse --is-inside-work-tree \
		>/dev/null 2>&1; then
		origin_url=$(git -C "$WWW_DIR" remote get-url origin \
			2>/dev/null || printf '')
	fi
	[ -z "$origin_url" ] && [ -n "$REPO_SLUG" ] &&
		origin_url="https://${GH_HOST}/${REPO_SLUG}.git"
	[ -z "$origin_url" ] && return 1

	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || return 1
	stagedir="$tmpdir/src"

	if ! git clone --branch "$BRANCH" --single-branch \
		"$origin_url" "$stagedir" >/dev/null 2>&1; then
		rm -rf "$tmpdir"
		return 1
	fi
	[ ! -d "$stagedir" ] && {
		rm -rf "$tmpdir"
		return 1
	}

	# Fetch LFS
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
# Last resort: download the branch archive and unpack it. GitHub puts the
# tree inside a single top-level directory, which becomes the staging source.
# This needs unzip plus at least one downloader.
sync_with_github_zip() {
	typeset tmpdir zipfile unpack_dir srcdir
	tmpdir=$(mktemp -d "/tmp/site-sync.XXXXXX") || return 1
	zipfile="$tmpdir/source.zip"

	if command -v curl >/dev/null 2>&1; then
		if ! curl -fLsS --retry 5 "$ZIP_URL" -o "$zipfile"; then
			rm -rf "$tmpdir"
			return 1
		fi
	elif command -v wget >/dev/null 2>&1; then
		if ! wget -qO "$zipfile" "$ZIP_URL"; then
			rm -rf "$tmpdir"
			return 1
		fi
	elif command -v ftp >/dev/null 2>&1; then
		# On stock OpenBSD the base HTTP client is ftp(1).
		if ! ftp -o "$zipfile" "$ZIP_URL"; then
			rm -rf "$tmpdir"
			return 1
		fi
	else
		error "no downloader found (curl, wget or ftp)."
		rm -rf "$tmpdir"
		return 1
	fi

	unpack_dir="$tmpdir/unpacked"
	if ! mkdir -p "$unpack_dir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	if ! unzip -q "$zipfile" -d "$unpack_dir"; then
		rm -rf "$tmpdir"
		return 1
	fi
	# sed reads the whole stream, so find never receives SIGPIPE
	# (unlike `find ... | head -n 1`, which returns 141 under
	# pipefail for large trees).
	srcdir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d |
		sed -n '1p')

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
# Make the staged tree readable by the web server, restart the service, then
# attempt certificate renewal when acme-client is installed. An ownership
# failure is only a warning; a failed restart aborts the run.
post_update_steps() {
	cd "$WWW_DIR" || return 1

	log "Setting ownership to ${OWNER_USER}:${OWNER_GROUP}..."
	chown -R "$OWNER_USER":"$OWNER_GROUP" "$WWW_DIR" ||
		warn "ownership failed"

	log "Setting file permissions..."
	find . -type d -exec chmod 755 {} +
	find . -type f -exec chmod 644 {} +

	log "Restarting web service ($SERVICE_NAME)..."
	if ! rcctl -q restart "$SERVICE_NAME"; then
		error "Error restarting $SERVICE_NAME"
		return 1
	fi

	# ACME certificate renewal. This is opportunistic: a missing client or
	# a failed renewal only warns, so it does not undo a good deployment.
	if command -v acme-client >/dev/null 2>&1; then
		log "Running acme-client for ${WWW_HOST}..."
		if acme-client "${WWW_HOST}"; then
			log "acme-client completed," \
				"restarting ${SERVICE_NAME}..."
			rcctl -q restart "$SERVICE_NAME" ||
				warn "service restart failed" \
					"after acme-client"
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
# Remove this run's PID file and then the lock directory. rmdir only succeeds
# when the directory is empty, so a directory with unexpected contents is left
# in place. Called from the EXIT, INT, and TERM traps below.
cleanup_lock() {
	if [ -n "${LOCKDIR:-}" ]; then
		rm -f "${LOCKDIR}/pid"
		rmdir "${LOCKDIR}" 2>/dev/null || true
	fi
}

# mkdir is atomic, so creating the lock directory doubles as the mutex. The
# PID inside identifies the owner for the stale-lock check.
acquire_lock() {
	typeset lock_pid

	LOCKDIR="$WWW_DIR/.sync.lock"
	if mkdir "$LOCKDIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCKDIR/pid" 2>/dev/null || true
		return 0
	fi

	# An old lock without a PID is left alone (fail closed). A lock
	# whose recorded process is gone is removed and reacquired.
	lock_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
	if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
		warn "Removing stale sync lock from PID $lock_pid."
		rm -f "$LOCKDIR/pid"
		rmdir "$LOCKDIR" 2>/dev/null || true
		if mkdir "$LOCKDIR" 2>/dev/null; then
			printf '%s\n' "$$" >"$LOCKDIR/pid" 2>/dev/null || true
			return 0
		fi
	fi

	return 1
}

main() {
	log "----------------------------------------"
	log "Sync started (user: $GH_USER)"

	# Deployment writes under /var/www, changes ownership, and restarts
	# httpd, so it must run as root.
	if [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root."
		exit 1
	fi

	# Check the target before taking the lock, which lives inside WWW_DIR.
	[ -d "$WWW_DIR" ] || {
		error "$WWW_DIR does not exist"
		exit 1
	}

	# A held lock means another sync is already running; exit successfully
	# rather than reporting a collision as an error.
	if ! acquire_lock; then
		log "Another sync running. Exiting."
		exit 0
	fi

	# Release the lock on normal exit, interrupt, and termination.
	trap 'cleanup_lock' EXIT
	trap 'cleanup_lock; exit 130' INT
	trap 'cleanup_lock; exit 143' TERM

	# Try GitHub CLI, then plain git, then the ZIP archive; stop at the
	# first method that stages the site successfully.
	if ! sync_with_gh_cli && ! sync_with_git &&
		! sync_with_github_zip; then
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
