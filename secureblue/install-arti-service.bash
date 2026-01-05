#!/bin/bash
set -euo pipefail

# SecureBlue arti.service installation script
# Automated script to install and enable arti.service for user systemd
# - Installs arti.service systemd user unit from bundled template
# - Downloads example arti config.toml from upstream Tor repository
# - Creates necessary config/data/state directories under XDG paths
# - Enables and starts arti.service under user systemd
# - Optionally installs arti-socks-proxy.service if socat is available
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not available"
		exit 1
	fi
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/systemd/arti.service"
BRIDGE_SRC="${SCRIPT_DIR}/systemd/arti-socks-proxy.service"
CONFIG_URL="https://gitlab.torproject.org/tpo/core/arti/-/raw/main/crates/arti/src/arti-example-config.toml"

require_cmd systemctl
require_cmd curl

if [[ ! -f $SERVICE_SRC ]]; then
	error "service file not found at $SERVICE_SRC"
	exit 1
fi

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arti"
CONFIG_FILE="${CONFIG_DIR}/arti.toml"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/arti"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arti"

log "Creating systemd user dir: $SYSTEMD_USER_DIR"
install -d -m 0755 "$SYSTEMD_USER_DIR"

log "Installing arti.service to user unit directory..."
install -m 0644 "$SERVICE_SRC" "$SYSTEMD_USER_DIR/arti.service"

log "Creating arti directories (config/data/state)..."
install -d -m 0755 "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"

if [[ -f $CONFIG_FILE ]]; then
	BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
	log "Config already exists; creating backup at $BACKUP_FILE"
	cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

log "Downloading example arti config from upstream..."
if ! net_curl "$CONFIG_URL" -o "$CONFIG_FILE"; then
	error "failed to download arti config from $CONFIG_URL"
	exit 1
fi
log "Saved arti config to $CONFIG_FILE"

log "Reloading systemd --user units..."
if ! systemctl --user daemon-reload; then
	error "systemctl --user daemon-reload failed (ensure a user systemd session is running)"
	exit 1
fi

log "Enabling and starting arti.service..."
if ! systemctl --user enable --now arti.service; then
	error "failed to enable/start arti.service (ensure user systemd is active)"
	exit 1
fi

# Optional: install a SOCKS bridge on 127.0.0.1:9050 using socat, if available
if command -v socat >/dev/null 2>&1; then
	BRIDGE_UNIT="${SYSTEMD_USER_DIR}/arti-socks-proxy.service"
	if [[ -f $BRIDGE_SRC ]]; then
		log "Detected socat; installing arti-socks-proxy.service from ${BRIDGE_SRC}"
		install -m 0644 "$BRIDGE_SRC" "$BRIDGE_UNIT"
	else
		warn "Bridge unit template not found at ${BRIDGE_SRC}; skipping bridge install"
	fi

	log "Reloading systemd --user units (bridge)..."
	if ! systemctl --user daemon-reload; then
		warn "systemctl --user daemon-reload failed for bridge unit"
	fi

	log "Enabling and starting arti-socks-proxy.service..."
	if ! systemctl --user enable --now arti-socks-proxy.service; then
		warn "failed to enable/start arti-socks-proxy.service"
	else
		log "arti-socks-proxy.service enabled and running."
	fi
else
	warn "socat not found; skipping installation of arti-socks-proxy.service"
fi

# Clean up bundled systemd templates after use to keep ${SCRIPT_DIR} tidy when installed under /usr/local/bin
if [[ -d "${SCRIPT_DIR}/systemd" ]]; then
	log "Removing bundled systemd templates from ${SCRIPT_DIR}/systemd"
	rm -rf "${SCRIPT_DIR}/systemd" || warn "failed to remove ${SCRIPT_DIR}/systemd"
fi

log "arti.service installed, enabled, and running."
