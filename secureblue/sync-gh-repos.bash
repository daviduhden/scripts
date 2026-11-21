#!/bin/bash
set -euo pipefail

# GitHub repository sync helper.
#
# Clones every repository returned for OWNER into BASE_DIR, or refreshes
# existing checkouts, using gh for authenticated API access and SSH URLs for
# cloning. Requires an authenticated gh session and SSH access to GitHub.
#
# A fresh clone is staged with the previous working tree, then published.
# Old Git metadata and working files remain in a private sibling backup.
#
# BASE_DIR must already exist and is not created here. It defaults to
# ${HOME}/git, prompting first when stdin is a terminal unless
# --non-interactive is given. No elevation is used.
#
# Environment variables:
#   OWNER     GitHub username to sync (default: daviduhden)
#   BASE_DIR  Local directory to clone into (default: ${HOME}/git)
# Flags:
#   -n, --non-interactive  Do not question
#                          (use default BASE_DIR if unset)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

OWNER="${OWNER:-daviduhden}"

DEFAULT_BASE_DIR="${HOME}/git"
NON_INTERACTIVE=0

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "Missing required command: $1"
		exit 1
	fi
}

# Reduce a fresh clone to its Git metadata and repository automation files.
remove_all_except_git_and_github() {
	local dir="$1"
	find "$dir" -mindepth 1 -maxdepth 1 \
		! -name '.git' \
		! -name '.github' \
		-exec rm -rf -- {} +
}

copy_from_backup_excluding_git() {
	local backup_dir="$1"
	local target_dir="$2"

	# Copy everything (including dotfiles) except .git from backup into the
	# target. Using tar keeps permissions reasonably intact and avoids
	# requiring rsync. Only .git is excluded, so a backup .github directory
	# overlays the fresh clone's copy rather than replacing it wholesale.
	tar --exclude='./.git' -C "$backup_dir" -cf - . |
		tar -C "$target_dir" -xf -
}

repo_has_content() {
	local dir="$1" listing

	[ -d "$dir" ] || return 1

	# Capture the listing instead of piping into grep -q: the consumer
	# would exit early and the producer could die of SIGPIPE under
	# pipefail, reporting 141 even when content exists.
	listing="$(find "$dir" \
		\( -path "$dir/.git" \
		-o -path "$dir/.git/*" \
		-o -path "$dir/.github" \
		-o -path "$dir/.github/*" \) -prune \
		-o -mindepth 1 -print -quit)"

	[ -n "$listing" ]
}

usage() {
	cat <<'EOF'
Usage: sync-gh-repos.bash [--non-interactive]

Environment variables:
  OWNER     GitHub username to sync (default: daviduhden)
  BASE_DIR  Local directory to clone into (default: ${HOME}/git)

Options:
  -n, --non-interactive  Do not question for BASE_DIR
  -h, --help             Show this help
EOF
}

parse_args() {
	local flag_used=0
	while [ $# -gt 0 ]; do
		case "$1" in
		-n | --non-interactive)
			flag_used=1
			NON_INTERACTIVE=1
			shift
			;;
		-h | --help)
			flag_used=1
			warn "CLI flag detected; using non-default" \
				"options instead of standard behavior."
			usage
			exit 0
			;;
		*)
			error "Unknown argument: $1"
			exit 1
			;;
		esac
	done
	if [ "$flag_used" -eq 1 ]; then
		warn "CLI flag detected; using non-default" \
			"options instead of standard behavior."
	fi
}

# An explicitly set BASE_DIR wins even if empty (which then fails the directory
# check). Otherwise prompt only for an interactive terminal, and fall back to
# the default when input is unavailable.
resolve_base_dir() {
	if [ -z "${BASE_DIR+x}" ]; then
		if [ $NON_INTERACTIVE -eq 0 ] && [ -t 0 ]; then
			if ! read -r -p "BASE_DIR [${DEFAULT_BASE_DIR}]: " BASE_DIR; then
				warn "Could not read BASE_DIR from" \
					"input; using default:" \
					"$DEFAULT_BASE_DIR"
				BASE_DIR="$DEFAULT_BASE_DIR"
			fi
			BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
		else
			BASE_DIR="$DEFAULT_BASE_DIR"
		fi
	fi
}

check_prereqs() {
	require_cmd gh
	require_cmd git
	require_cmd mktemp

	if [ ! -d "$BASE_DIR" ]; then
		error "Base directory $BASE_DIR does not exist"
		exit 1
	fi

	if ! gh auth status >/dev/null 2>&1; then
		error "GitHub CLI is not authenticated; run 'gh auth login' first."
		exit 1
	fi
}

# Prepare the replacement on the same filesystem before touching the checkout.
sync_single_repo() (
	local name="$1" ssh_url="$2" default_branch="$3"
	local target="$BASE_DIR/$1" stage="" backup_dir="" lock="$BASE_DIR/.$1.sync.lock"

	if [[ ! $name =~ ^[a-zA-Z0-9._-]+$ || $name == . || $name == .. ]]; then
		error "Invalid repository directory name: $name"
		return 1
	fi
	mkdir -- "$lock" || {
		error "Cannot acquire sync lock: $lock"
		return 1
	}
	trap '
		if [ -n "$backup_dir" ] && [ -d "$backup_dir/checkout" ] &&
			[ ! -e "$target" ] && [ ! -L "$target" ]; then
			mv -T -- "$backup_dir/checkout" "$target" ||
				error "Restore failed. Previous checkout: $backup_dir/checkout"
		fi
		[ -z "$stage" ] || rm -rf -- "$stage"
		[ -z "$backup_dir" ] || rmdir -- "$backup_dir" 2>/dev/null || true
		rmdir -- "$lock" || warn "Could not remove sync lock: $lock"
	' EXIT
	trap 'exit 1' HUP INT TERM
	stage=$(mktemp -d "$BASE_DIR/.$name.stage.XXXXXX") || return 1

	log "Cloning $name into staging"
	if [ -n "$default_branch" ]; then
		git clone --branch "$default_branch" -- "$ssh_url" "$stage/checkout" ||
			return 1
	else
		git clone -- "$ssh_url" "$stage/checkout" || return 1
	fi
	if ! repo_has_content "$stage/checkout"; then
		warn "Repository $name appears empty; skipping sync."
		return 0
	fi

	if [ -e "$target" ] || [ -L "$target" ]; then
		if [ ! -d "$target" ] || [ -L "$target" ]; then
			error "Refusing to replace a non-directory or symlink: $target"
			return 1
		fi
		remove_all_except_git_and_github "$stage/checkout" || return 1
		copy_from_backup_excluding_git "$target" "$stage/checkout" || return 1
		backup_dir=$(mktemp -d "$BASE_DIR/.$name.backup.XXXXXX") || return 1
		mv -T -- "$target" "$backup_dir/checkout" || return 1
		log "Previous checkout retained at $backup_dir/checkout"
	fi
	mv -T -- "$stage/checkout" "$target"
)

sync_repositories() {
	local listing
	log "Listing repositories for $OWNER"
	# Capture the complete listing first. Process substitution does not
	# propagate the producer's failure, so a rate limit or expired token
	# would otherwise look like a successful empty run.
	if ! listing=$(gh api --paginate \
		"users/${OWNER}/repos" \
		--jq '.[] | [.name, .ssh_url, .default_branch] | @tsv'); then
		error "could not list repositories for ${OWNER}; refusing to continue."
		return 1
	fi
	if [ -z "$listing" ]; then
		error "GitHub returned no repositories for ${OWNER}."
		return 1
	fi
	while IFS=$'\t' read -r name ssh_url default_branch; do
		[ -n "$name" ] || continue
		sync_single_repo "$name" "$ssh_url" "$default_branch"
	done <<<"$listing"

	log "Sync complete"
}

main() {
	parse_args "$@"
	resolve_base_dir
	check_prereqs
	sync_repositories
}

main "$@"
