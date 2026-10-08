#!/bin/bash
set -euo pipefail

# SecureBlue arti.service installation script
# Automated script to install and enable arti.service for user systemd
# - Installs arti.service systemd user unit from bundled template
# - Downloads the example arti config matching the installed Arti version
#   (release tag arti-vX.Y.Z), falling back to the main branch
# - Creates necessary config/data/state directories under XDG paths
# - Enables and starts arti.service under user systemd
# - Optionally installs arti-socks-proxy.service if socat is available
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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
ARTI_REPO_RAW="https://gitlab.torproject.org/tpo/core/arti/-/raw"
ARTI_EXAMPLE_PATH="crates/arti/src/arti-example-config.toml"

# Choose the ref whose example config matches the installed Arti. Prefer the
# release tag for the running version (arti-vX.Y.Z); fall back to main when the
# version cannot be determined.
detect_arti_ref() {
	local arti_bin version
	arti_bin="$(command -v arti 2>/dev/null || true)"
	if [[ -z $arti_bin && -x /usr/local/bin/arti ]]; then
		arti_bin=/usr/local/bin/arti
	fi
	if [[ -n $arti_bin ]]; then
		version="$("$arti_bin" --version 2>/dev/null |
			sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p')"
		if [[ -n $version ]]; then
			printf 'arti-v%s\n' "$version"
			return 0
		fi
	fi
	printf 'main\n'
}

config_url_for_ref() {
	printf '%s/%s/%s\n' "$ARTI_REPO_RAW" "$1" "$ARTI_EXAMPLE_PATH"
}

check_prereqs() {
	require_cmd systemctl
	require_cmd curl
	if [[ ! -f $SERVICE_SRC ]]; then
		error "service file not found at $SERVICE_SRC"
		exit 1
	fi
}

setup_paths() {
	SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arti"
	CONFIG_FILE="${CONFIG_DIR}/arti.toml"
	DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/arti"
	STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arti"
	CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arti"
}

install_arti_unit_and_config() {
	log "Creating systemd user dir: $SYSTEMD_USER_DIR"
	install -d -m 0750 "$SYSTEMD_USER_DIR"

	log "Installing arti.service to user unit directory..."
	install -m 0640 "$SERVICE_SRC" "$SYSTEMD_USER_DIR/arti.service"
	# Substitute the resolved XDG paths so the unit matches the directories
	# created below (which honor XDG_*_HOME overrides).
	sed -i \
		-e "s#%h/.config/arti#${CONFIG_DIR}#g" \
		-e "s#%h/.local/share/arti#${DATA_DIR}#g" \
		-e "s#%h/.local/state/arti#${STATE_DIR}#g" \
		-e "s#%h/.cache/arti#${CACHE_DIR}#g" \
		"$SYSTEMD_USER_DIR/arti.service"

	log "Creating arti directories (config/data/state/cache)..."
	install -d -m 0750 "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"

	if [[ -f $CONFIG_FILE ]]; then
		BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
		log "Config already exists; creating backup at $BACKUP_FILE"
		cp "$CONFIG_FILE" "$BACKUP_FILE"
	fi

	local arti_ref config_url
	log "Downloading example arti config from upstream..."
	arti_ref="$(detect_arti_ref)"
	config_url="$(config_url_for_ref "$arti_ref")"
	if ! net_curl "$config_url" -o "$CONFIG_FILE"; then
		warn "failed to download $config_url; falling back to main"
		arti_ref=main
		config_url="$(config_url_for_ref "$arti_ref")"
		if ! net_curl "$config_url" -o "$CONFIG_FILE"; then
			error "failed to download arti config from $config_url"
			exit 1
		fi
	fi
	log "Saved arti config ($arti_ref) to $CONFIG_FILE"
}

enable_arti_service() {
	log "Reloading systemd --user units..."
	if ! systemctl --user daemon-reload; then
		error "systemctl --user daemon-reload failed" \
			"(ensure a user systemd session is running)"
		exit 1
	fi

	log "Enabling and starting arti.service..."
	if ! systemctl --user enable --now arti.service; then
		error "failed to enable/start arti.service" \
			"(ensure user systemd is active)"
		exit 1
	fi
}

maybe_install_bridge_service() {
	if command -v socat >/dev/null 2>&1; then
		BRIDGE_UNIT="${SYSTEMD_USER_DIR}/arti-socks-proxy.service"
		if [[ -f $BRIDGE_SRC ]]; then
			log "Detected socat; installing" \
				"arti-socks-proxy.service from ${BRIDGE_SRC}"
			install -m 0644 "$BRIDGE_SRC" "$BRIDGE_UNIT"
			sed -i \
				-e "s#%h/.local/state/arti#${STATE_DIR}#g" \
				"$BRIDGE_UNIT"
		else
			warn "Bridge unit template not found at" \
				"${BRIDGE_SRC}; skipping bridge install"
			return
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
		warn "socat not found; skipping installation" \
			"of arti-socks-proxy.service"
	fi
}

run_install() {
	setup_paths
	install_arti_unit_and_config
	enable_arti_service
	maybe_install_bridge_service
	log "arti.service installed, enabled, and running."
}

main() {
	check_prereqs
	run_install
}

main "$@"
