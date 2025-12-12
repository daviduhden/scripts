#!/bin/bash
set -euo pipefail

# Sync or clone all repositories for a GitHub user into a local base directory.
# - Uses GitHub CLI for authenticated API access
# - If a repo directory exists, renames it, fresh-clones via SSH, keeps only
#   .git and .github from the clone, then copies the previous working tree over
# - Otherwise, clones the repo via SSH
# - Configurable via OWNER and BASE_DIR environment variables
# - If BASE_DIR is not set, prompts interactively (unless --non-interactive)
#
# Flags:
#   -n, --non-interactive   Do not prompt (use default BASE_DIR if unset)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

OWNER="${OWNER:-daviduhden}"

DEFAULT_BASE_DIR="/var/home/david/git"
NON_INTERACTIVE=0

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing required command: $1"
    exit 1
  fi
}

make_backup_dir() {
  # Generates a non-existing backup directory path.
  # Example: /path/repo.backup.2025-12-12_10-00-00.12345
  local target_dir="$1"
  local ts
  local candidate
  ts="$(date '+%Y-%m-%d_%H-%M-%S')"
  candidate="${target_dir}.backup.${ts}.$$"
  printf '%s\n' "$candidate"
}

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

  # Copy everything (including dotfiles) except .git from backup into target.
  # Using tar keeps permissions reasonably intact and avoids requiring rsync.
  tar --exclude='./.git' -C "$backup_dir" -cf - . | tar -C "$target_dir" -xf -
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage: sync-gh-repos.bash [--non-interactive]

Environment variables:
  OWNER     GitHub username to sync (default: daviduhden)
  BASE_DIR  Local directory to clone into (default: /var/home/david/git)

Options:
  -n, --non-interactive  Do not prompt for BASE_DIR
  -h, --help             Show this help
EOF
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        exit 1
        ;;
    esac
  done

  if [ -z "${BASE_DIR+x}" ]; then
    if [ $NON_INTERACTIVE -eq 0 ] && [ -t 0 ]; then
      read -r -p "BASE_DIR [${DEFAULT_BASE_DIR}]: " BASE_DIR || true
      BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
    else
      BASE_DIR="$DEFAULT_BASE_DIR"
    fi
  fi

  require_bin gh
  require_bin git

  if [ ! -d "$BASE_DIR" ]; then
    error "Base directory $BASE_DIR does not exist"
    exit 1
  fi

  # Ensure gh is authenticated
  if ! gh auth status >/dev/null 2>&1; then
    error "GitHub CLI is not authenticated; run 'gh auth login' first."
    exit 1
  fi

  log "Listing repositories for $OWNER"
  # name, ssh_url, default_branch
  while IFS=$'\t' read -r name ssh_url default_branch; do
    [ -n "$name" ] || continue
    target="$BASE_DIR/$name"

    backup_dir=""
    restored=0
    cleanup_on_error() {
      # If something failed mid-flight, try to restore the previous directory.
      if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ] && [ $restored -eq 0 ]; then
        warn "Restoring previous directory for $name from $backup_dir"
        rm -rf -- "$target" 2>/dev/null || true
        mv -- "$backup_dir" "$target" 2>/dev/null || true
        restored=1
      fi
    }

    if [ -e "$target" ]; then
      backup_dir="$(make_backup_dir "$target")"
      log "Directory exists; renaming $target -> $backup_dir"
      mv -- "$target" "$backup_dir"
      trap cleanup_on_error ERR
    fi

    log "Cloning $name -> $target"
    git clone "$ssh_url" "$target"
    if [ -n "${default_branch:-}" ]; then
      git -C "$target" checkout "$default_branch" || true
    fi

    if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ]; then
      log "Pruning fresh clone (keep only .git and .github): $target"
      remove_all_except_git_and_github "$target"

      log "Copying files from $backup_dir into $target"
      copy_from_backup_excluding_git "$backup_dir" "$target"

      log "Removing backup directory: $backup_dir"
      rm -rf -- "$backup_dir"
    fi

    trap - ERR
  done < <(gh api --paginate "users/${OWNER}/repos" --jq '.[] | [.name, .ssh_url, .default_branch] | @tsv')

  log "Sync complete"
}

main "$@"
