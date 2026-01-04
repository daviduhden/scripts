#!/bin/bash
set -euo pipefail

# SecureBlue XD update/install script
# Automated script to install or update the XD Go-based project
# - Ensures Go is installed (via Homebrew if available)
# - Clones the XD repository from GitHub
# - Builds the project with make
# - Installs the project using make install (requires root)

REPO_URL="https://github.com/majestrate/XD.git"
BUILD_DIR="${HOME}/.local/src"
ROOT_CMD=""

# Colors
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

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() {
	printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2
	exit 1
}

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
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
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

	if [ ! -d XD ]; then
		log "Cloning XD repository..."
		git clone "$REPO_URL" XD
	else
		log "Updating existing XD repository..."
		cd "$BUILD_DIR"/XD || true
		git pull --ff-only
	fi
	cd "$BUILD_DIR"/XD || true
}

build_and_install_XD() {
	log "Building XD..."
	make
	log "Installing XD using 'make install'..."
	run_root make install
	log "XD installed successfully."
}

main() {
	detect_root_cmd
	ensure_git
	ensure_go

	clone_or_update_repo
	build_and_install_XD

	log "Done. Make sure XD is in your PATH."
}

main "$@"
