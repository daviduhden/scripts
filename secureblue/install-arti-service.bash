#!/usr/bin/env bash
set -euo pipefail

# Install and enable the arti user service using the unit in ./systemd/arti.service.
# - Installs the unit under ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
# - Creates required arti data/config/state directories
# - Reloads systemd user units and enables + starts arti.service
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()   { printf '%b[INFO]%b 🟦 %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%b[WARN]%b ⚠️  %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%b[ERROR]%b ❌ %s\n' "$RED" "$RESET" "$*" >&2; }

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
CONFIG_URL="https://gitlab.torproject.org/tpo/core/arti/-/raw/main/crates/arti/src/arti-example-config.toml"

require_cmd systemctl
require_cmd curl

if [[ ! -f "$SERVICE_SRC" ]]; then
  error "service file not found at $SERVICE_SRC"
  exit 1
fi

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arti"
CONFIG_FILE="${CONFIG_DIR}/arti.toml"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/arti"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arti"

log "Creating systemd user dir: $SYSTEMD_USER_DIR"
install -d -m 0750 "$SYSTEMD_USER_DIR"

log "Installing arti.service to user unit directory..."
install -m 0640 "$SERVICE_SRC" "$SYSTEMD_USER_DIR/arti.service"

log "Creating arti directories (config/data/state)..."
install -d -m 0750 "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
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

log "arti.service installed, enabled, and running."
