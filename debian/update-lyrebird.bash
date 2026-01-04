#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Lyrebird Go build/install script
# Builds and installs the latest Lyrebird from source on Debian-based systems.
# - Requires Go to be installed
# - Clones or updates the Lyrebird GitLab repository
# - Builds the project using make
# - Installs the resulting binary into /usr/local/bin
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin
export PATH

REPO="tpo/anti-censorship/lyrebird"
REPO_URL="https://gitlab.torproject.org/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"

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

ensure_go() {
	require_cmd go
	log "Go version: $(go version)"
}

fetch_lyrebird_source() {
	mkdir -p "$BUILD_DIR"
	cd "$BUILD_DIR"
	if [ -d lyrebird ]; then
		log "Removing existing lyrebird directory..."
		rm -rf lyrebird
	fi
	log "Cloning lyrebird repository..."
	git clone --depth 1 "$REPO_URL" lyrebird
	cd lyrebird
}

build_lyrebird() {
	log "Building lyrebird..."
	make build
	if [ ! -x ./lyrebird ]; then
		error "Build failed: lyrebird binary not found."
	fi
}

install_lyrebird() {
	log "Installing lyrebird to /usr/local/bin..."
	cp ./lyrebird /usr/local/bin/
	chmod +x /usr/local/bin/lyrebird
	log "Lyrebird installed successfully."
}

main() {
	require_root
	require_cmd git
	ensure_go
	fetch_lyrebird_source
	build_lyrebird
	install_lyrebird
}

main "$@"
