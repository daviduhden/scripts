#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
    exec zsh "$0" "$@"
fi

set -euo pipefail

# XD Go build/install script
# Builds and installs the latest XD from source on Debian-based systems.
# - Requires Go to be installed
# - Clones or updates the XD GitHub repository
# - Builds the project using make
# - Installs the resulting binary into /usr/local/bin
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO="majestrate/XD"
REPO_URL="https://github.com/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"

# Colors
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; RESET=""
fi

log()   { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || error "Run as root (sudo $0)"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
}

ensure_go() {
    require_cmd go
    log "Go version: $(go version)"
}

fetch_XD_source() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    if [ ! -d XD ]; then
        log "Cloning XD repository..."
        git clone "$REPO_URL"
    else
        log "Updating existing XD repository..."
        cd XD
        git pull --ff-only
    fi
    cd XD
}

build_and_install_XD() {
    log "Building XD..."
    make
    log "Installing XD..."
    make install
    log "XD installed successfully."
}

main() {
    require_root
    require_cmd git
    ensure_go
    fetch_XD_source
    build_and_install_XD
}

main "$@"
