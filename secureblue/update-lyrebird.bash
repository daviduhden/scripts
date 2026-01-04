#!/bin/bash
set -euo pipefail

# SecureBlue lyrebird update/install script
# Automated script to install or update the lyrebird Go-based Tor transport
# - Ensures Go is installed (via Homebrew if available)
# - Clones the lyrebird repository from Tor Project GitLab
# - Builds the binary with make
# - Installs the resulting binary into /usr/local/bin (requires root)

REPO_LYREBIRD="https://gitlab.torproject.org/tpo/anti-censorship/lyrebird.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="lyrebird"
INSTALL_PATH="/usr/local/bin/$BIN_NAME"
ROOT_CMD=""

# Colors
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; RESET=""
fi

log()   { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2; exit 1; }

detect_root_cmd() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        ROOT_CMD=""
        log "Running as root; no run0 needed."
    elif command -v run0 >/dev/null 2>&1; then
        ROOT_CMD="run0"
        log "Using run0 for privileged operations."
    else
        error "run0 not found. Run this script as root or install run0."
    fi
}

run_root() {
    [ -n "$ROOT_CMD" ] && "$ROOT_CMD" "$@" || "$@"
}

ensure_git() {
    command -v git >/dev/null 2>&1 || error "git is required but not installed."
}

ensure_go() {
    if command -v go >/dev/null 2>&1; then
        log "Go already installed: $(go version)"
        return
    fi

    if command -v brew >/dev/null 2>&1; then
        log "Homebrew detected, installing Go..."
        if brew list go >/dev/null 2>&1; then
            log "Go already installed via Homebrew, attempting upgrade..."
            brew upgrade go || log "brew upgrade go not needed or failed."
        else
            brew install go
        fi
    else
        error "Go is not installed and Homebrew is not available. Please install Go manually."
    fi

    command -v go >/dev/null 2>&1 || error "Go installation failed."
    log "Using Go at: $(command -v go)"
}

clone_or_update_repo() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [ ! -d "$BIN_NAME" ]; then
        log "Cloning lyrebird repository..."
        git clone "$REPO_LYREBIRD" "$BIN_NAME"
    else
        log "Updating existing lyrebird repository..."
        cd "$BIN_NAME"
        git pull --ff-only
    fi
    cd "$BIN_NAME"
}

build_lyrebird() {
    log "Building lyrebird..."
    make build

    [ -x "./$BIN_NAME" ] || error "Build failed: binary $BIN_NAME not found."
}

install_lyrebird() {
    log "Installing lyrebird to $INSTALL_PATH..."
    run_root cp "./$BIN_NAME" "$INSTALL_PATH"
    run_root chmod +x "$INSTALL_PATH"
    log "Lyrebird installed successfully."
}

main() {
    detect_root_cmd
    ensure_git
    ensure_go

    clone_or_update_repo
    build_lyrebird
    install_lyrebird

    log "Done. Make sure $INSTALL_PATH is in your PATH."
}

main "$@"
