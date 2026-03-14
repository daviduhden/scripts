#!/bin/bash
set -euo pipefail

# SecureBlue XD update/install script
# Automated script to install or update the XD Go-based project
# - Ensures Go is installed (via Homebrew if available)
# - Clones the XD repository from GitHub
# - Builds the project with make
# - Installs the project using make install (requires root)
# - Installs/updates xd.service as a local user systemd unit
# - Uses user-local XD data directory under XDG paths

REPO_URL="https://github.com/majestrate/XD.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="XD"
ROOT_CMD=""
SKIP_BUILD=0
WAS_ACTIVE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/systemd/xd.service"

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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
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
	require_cmd git
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
		log "Cloning $BIN_NAME repository..."
		git clone "$REPO_URL" "$BIN_NAME"
	fi

	cd "$BUILD_DIR/$BIN_NAME"

	# Fetch tags and remote refs
	git fetch --tags --prune origin || git fetch --tags --prune

	# Determine latest tag (by tag creation date)
	latest_tag=$(git describe --tags "$(git rev-list --tags --max-count=1)" 2>/dev/null || true)

	if [ -n "$latest_tag" ]; then
		local_tag=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
		if [ "$local_tag" = "$latest_tag" ]; then
			log "Local repository is already at latest tag '$latest_tag'. Skipping build."
			SKIP_BUILD=1
			return
		fi
		log "Checking out latest tag $latest_tag..."
		git checkout "tags/$latest_tag" -q
	else
		log "No tags found; updating to latest commit on default branch..."
		git pull --ff-only
	fi
}

build_and_install_XD() {
	log "Building XD..."
	make
	# Adjust Makefile installation prefix: change $(PREFIX)/bin -> $(PREFIX)/local/bin
	if [ -f Makefile ]; then
		log "Patching Makefile install path..."
		sed -i "s|\$(PREFIX)/bin|\$(PREFIX)/local/bin|g" Makefile || true
	fi
	log "Installing XD using 'make install'..."
	run_root make install PREFIX=/usr
	log "XD installed successfully."
}

install_user_service() {
	local systemd_user_dir data_dir config_file unit_dst
	systemd_user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/XD"
	config_file="${data_dir}/xd.ini"
	unit_dst="${systemd_user_dir}/xd.service"

	log "Creating XD data directory: $data_dir"
	install -d -m 0750 "$data_dir"

	log "Creating systemd user directory: $systemd_user_dir"
	install -d -m 0750 "$systemd_user_dir"

	log "Installing xd.service to user unit directory..."
	install -m 0640 "$SERVICE_SRC" "$unit_dst"

	log "Stopping xd.service if it is running..."
	if systemctl --user is-active --quiet xd.service; then
		WAS_ACTIVE=1
		systemctl --user stop xd.service
	fi

	log "Reloading systemd --user units..."
	if ! systemctl --user daemon-reload; then
		error "systemctl --user daemon-reload failed (ensure a user systemd session is running)"
	fi

	log "Enabling xd.service at login..."
	if ! systemctl --user enable xd.service >/dev/null 2>&1; then
		error "failed to enable xd.service (ensure user systemd is active)"
	fi

	if [ "$WAS_ACTIVE" -eq 1 ]; then
		log "Restarting xd.service..."
		if ! systemctl --user restart xd.service; then
			error "failed to restart xd.service"
		fi
	else
		log "xd.service was not running before."
		log "You can start it now with: systemctl --user start xd.service"
	fi

	if [ ! -f "$config_file" ]; then
		warn "XD config not found at $config_file (create it before starting xd.service)."
	fi
}

main() {
	detect_root_cmd
	ensure_git
	ensure_go
	require_cmd systemctl
	require_cmd install

	if [ ! -f "$SERVICE_SRC" ]; then
		error "service file not found at $SERVICE_SRC"
	fi

	clone_or_update_repo
	if [ "$SKIP_BUILD" -eq 1 ]; then
		log "No build required. Continuing with user service setup."
	else
		build_and_install_XD
	fi

	install_user_service

	log "Done. Make sure /usr/local/bin is in your PATH."
}

main "$@"
