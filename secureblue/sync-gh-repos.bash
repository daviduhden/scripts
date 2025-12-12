#!/bin/bash
set -euo pipefail

# Sync or clone all repositories for a GitHub user into a local base directory.
# - Uses GitHub CLI for authenticated API access
# - If a repo directory exists, fetches and resets to origin/<default_branch>
# - Otherwise, clones the repo via SSH
# - Configurable via OWNER and BASE_DIR environment variables
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

OWNER="${OWNER:-daviduhden}"
BASE_DIR="${BASE_DIR:-/var/home/david/git}"

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing required command: $1"
    exit 1
  fi
}

main() {
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
    if [ -d "$target/.git" ]; then
      log "Syncing $name -> $target (branch: ${default_branch:-unknown})"
      git -C "$target" fetch origin
      if [ -n "$default_branch" ]; then
        git -C "$target" checkout "$default_branch" || true
        git -C "$target" reset --hard "origin/$default_branch"
      else
        warn "Default branch unknown for $name; skipping reset"
      fi
    else
      log "Cloning $name -> $target"
      git clone "$ssh_url" "$target"
      if [ -n "$default_branch" ]; then
        git -C "$target" checkout "$default_branch" || true
      fi
    fi
  done < <(gh api --paginate "users/${OWNER}/repos" --jq '.[] | [.name, .ssh_url, .default_branch] | @tsv')

  log "Sync complete"
}

main "$@"
