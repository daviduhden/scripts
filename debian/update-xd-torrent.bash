#!/bin/bash

set -euo pipefail

# XD Go build/install script
# Builds and installs the latest XD from source on Debian-based systems.
# - Requires Go to be installed
# - Clones or updates the XD GitHub repository
# - Builds the project using make
# - Installs the resulting binary into /usr/local/bin
# - Ensures "xd" system user/group and working directory exist
# - Installs/upgrades official xd.service systemd unit
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin
export PATH

REPO="majestrate/XD"
REPO_URL="https://github.com/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="XD"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com/majestrate/XD/refs/heads/master/contrib/systemd/xd.service"
SYSTEMD_UNIT_FILE="/etc/systemd/system/xd.service"
XD_USER="xd"
XD_GROUP="xd"
XD_HOME_DIR="/var/lib/XD"

# Control: set when the local copy is already on the latest tag
SKIP_BUILD=0
WAS_ACTIVE=0

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

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || error "Run as root (sudo $0)"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

ensure_go() {
	require_cmd go
	log "Go version: $(go version)"
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
	log "Installing XD..."
	make install
	log "XD installed successfully."
}

ensure_xd_user_group_and_home() {
	log "Ensuring xd system group/user and working directory exist..."

	if ! getent group "$XD_GROUP" >/dev/null 2>&1; then
		log "Creating system group '$XD_GROUP'..."
		groupadd --system "$XD_GROUP"
	fi

	if ! id -u "$XD_USER" >/dev/null 2>&1; then
		log "Creating system user '$XD_USER'..."
		useradd --system --gid "$XD_GROUP" --home-dir "$XD_HOME_DIR" --shell /usr/sbin/nologin "$XD_USER"
	fi

	mkdir -p "$XD_HOME_DIR"
	chown -R "$XD_USER:$XD_GROUP" "$XD_HOME_DIR"
}

stop_xd_if_running() {
	log "Stopping xd service if it is running..."
	if systemctl is-active --quiet xd; then
		WAS_ACTIVE=1
		systemctl stop xd
	fi
}

install_systemd_service() {
	log "Updating systemd unit: $SYSTEMD_UNIT_FILE..."
	install -d /etc/systemd/system

	local unit_tmp
	unit_tmp="$(mktemp /tmp/xd-service-XXXXXX)"
	if ! net_curl "$SYSTEMD_UNIT_URL" -o "$unit_tmp"; then
		rm -f "$unit_tmp"
		error "Failed to download systemd unit from ${SYSTEMD_UNIT_URL}"
	fi

	install -m 0644 "$unit_tmp" "$SYSTEMD_UNIT_FILE"
	rm -f "$unit_tmp"

	log "Reloading systemd daemon..."
	systemctl daemon-reload

	log "Enabling xd service at boot..."
	systemctl enable xd >/dev/null 2>&1 || true

	if [ "$WAS_ACTIVE" -eq 1 ]; then
		log "Restarting xd..."
		systemctl restart xd
	else
		log "xd was not running before."
		log "You can start it now with: systemctl start xd"
	fi
}

main() {
	require_root
	require_cmd git
	require_cmd curl
	require_cmd systemctl
	require_cmd install
	require_cmd getent
	require_cmd useradd
	require_cmd groupadd
	ensure_go
	clone_or_update_repo
	ensure_xd_user_group_and_home
	stop_xd_if_running
	if [ "$SKIP_BUILD" -eq 1 ]; then
		log "No build required. Continuing with system setup."
	else
		build_and_install_XD
	fi
	install_systemd_service
}

main "$@"
