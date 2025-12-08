#!/bin/bash
set -euo pipefail

# Build and install the latest btop++ from source on Debian-based systems.
# - Fetches the latest release tag from GitHub
# - Installs build dependencies if missing
# - Clones the repo at that tag, builds, and installs
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="aristocratos/btop"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
REPO_URL="https://github.com/${REPO}.git"

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

# Helpers
net_curl() {
    curl -fLsS --retry 5 "$@"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This script must be run as root. Try: sudo $0"
    fi
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

get_latest_tag() {
    local tag json

    if has_cmd gh; then
        if tag="$(gh api "repos/${REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)" && [[ -n "$tag" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi

    if has_cmd git; then
        tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null \
            | awk '{print $2}' \
            | sed 's#refs/tags/##' \
            | sed 's/\^{}//' \
            | sort -Vr \
            | head -n1)"
        if [[ -n "$tag" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi

    if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
        return 1
    fi
    awk -F '"' '"tag_name":/ {print $4; exit}' <<<"$json"
}

get_current_version() {
    if command -v btop >/dev/null 2>&1; then
        btop --version 2>/dev/null | awk 'match($0,/v[0-9]+\.[0-9]+\.[0-9]+/){print substr($0,RSTART+1,RLENGTH-1); exit}'
    fi
}

install_build_deps() {
    local apt_cmd
    if command -v apt-get >/dev/null 2>&1; then
        apt_cmd="apt-get"
    elif command -v apt >/dev/null 2>&1; then
        apt_cmd="apt"
    else
        error "neither 'apt-get' nor 'apt' is available."
    fi

    log "Installing build dependencies (git build-essential cmake libncursesw5-dev)..."
    "$apt_cmd" update
    "$apt_cmd" install -y git build-essential cmake libncursesw5-dev
}

fetch_source() {
    local tag="$1" dest="$2" src_dir="" tarball_url tarball

    if has_cmd gh; then
        log "Cloning btop tag ${tag} with GitHub CLI..." >&2
        if gh repo clone "$REPO" "$dest/btop" -- --branch "$tag" --depth 1 >/dev/null 2>&1; then
            printf '%s\n' "$dest/btop"
            return 0
        fi
        warn "gh repo clone failed; falling back to git/curl." >&2
    fi

    if has_cmd git; then
        log "Cloning btop tag ${tag} with git..." >&2
        if git clone --depth 1 --branch "$tag" "$REPO_URL" "$dest/btop"; then
            printf '%s\n' "$dest/btop"
            return 0
        fi
        warn "git clone failed; falling back to tarball download." >&2
    fi

    tarball_url="https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"
    tarball="$dest/btop.tar.gz"

    log "Downloading tarball ${tarball_url} as last resort..." >&2
    if net_curl "$tarball_url" -o "$tarball" && tar -xzf "$tarball" -C "$dest"; then
        src_dir="$(find "$dest" -maxdepth 1 -type d -name 'btop*' | head -n1)"
        if [[ -n "$src_dir" ]]; then
            printf '%s\n' "$src_dir"
            return 0
        fi
    fi

    return 1
}

build_and_install() {
    local tag="$1"
    local tmpdir src_dir

    tmpdir=$(mktemp -d /tmp/btop-src-XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT

    src_dir="$(fetch_source "$tag" "$tmpdir")" || error "could not fetch source via gh/git/curl."
    if [[ -z "$src_dir" ]]; then
        error "source directory path was empty after fetch."
    fi

    log "Building btop..."
    cd "$src_dir"
    make -j"$(nproc)"

    log "Installing btop..."
    make install

    log "btop ${tag} installed successfully."
}

main() {
    require_root
    require_cmd curl
    require_cmd awk
    require_cmd tar

    install_build_deps

    log "Fetching latest btop release tag..."
    local latest_tag
    latest_tag="$(get_latest_tag || true)"
    if [[ -z "$latest_tag" ]]; then
        error "could not determine latest release tag from GitHub."
    fi

    log "Latest release tag: ${latest_tag}"

    local current
    current="$(get_current_version)"
    if [[ -n "$current" ]]; then
        log "Currently installed btop version: ${current}"
        if [[ "$current" == "${latest_tag#v}" || "$current" == "$latest_tag" ]]; then
            log "btop is already up to date. Nothing to do."
            exit 0
        fi
    else
        log "btop is not currently installed."
    fi

    build_and_install "$latest_tag"
}

main "$@"
