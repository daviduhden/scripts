#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Debian btop++ build/install script
# Builds and installs the latest btop++ from source on Debian-based systems.
# - Fetches the latest release tag from GitHub
# - Installs build dependencies if missing
# - Clones the repo at that tag, builds, and installs
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

BUILD_DIR="${HOME}/.local/src"
REPO="aristocratos/btop"
REPO_URL="https://github.com/${REPO}.git"
INSTALL_PREFIX="/usr/local"

# Colors
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
	GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
else
	GREEN=""; YELLOW=""; RED=""; RESET=""
fi

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2; exit 1; }

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || error "This script must be run as root. Try: sudo $0"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
}

get_latest_tag() {
	# Use git only
	local tag
	tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s/\^{}//' |
		sort -Vr |
		head -n1)"
	[[ -n $tag ]] && printf '%s\n' "$tag"
}

get_current_version() {
	if command -v btop >/dev/null 2>&1; then
		btop --version 2>/dev/null | awk 'match($0,/v?[0-9]+\.[0-9]+\.[0-9]+/){ver=substr($0,RSTART,RLENGTH); sub(/^v/,"",ver); print ver; exit}'
	fi
}

install_build_deps() {
	local apt_cmd
	if command -v apt-get >/dev/null 2>&1; then
		apt_cmd="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		apt_cmd="apt"
	else
		error "Neither 'apt-get' nor 'apt' is available."
	fi

	log "Installing build dependencies (git build-essential cmake libncurses-dev)..."
	"$apt_cmd" update
	"$apt_cmd" install -y git build-essential cmake libncurses-dev
}

fetch_source() {
	local tag="$1" dest="$2" src_dir=""
	mkdir -p "$dest"

	log "Cloning btop tag ${tag} with git..."
	if git clone --depth 1 --branch "$tag" "$REPO_URL" "$dest/btop"; then
		src_dir="$dest/btop"
		printf '%s\n' "$src_dir"
		return 0
	fi

	# Fallback to tarball download
	local tarball_url="https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"
	local tarball="$dest/btop.tar.gz"
	log "Git clone failed, downloading tarball ${tarball_url}..."
	curl -fLsS --retry 5 "$tarball_url" -o "$tarball"
	tar -xzf "$tarball" -C "$dest"
	src_dir="$(find "$dest" -maxdepth 1 -type d -name 'btop*' | head -n1)"
	[[ -n $src_dir ]] && printf '%s\n' "$src_dir"
}

build_and_install() {
	local tag="$1"
	local src_dir

	src_dir="$(fetch_source "$tag" "$BUILD_DIR")" || error "Could not fetch source."
	cd "$src_dir"

	log "Building btop..."
	make -j"$(nproc)"

	log "Installing btop..."
	make PREFIX="$INSTALL_PREFIX" install

	log "btop ${tag} installed successfully."
}

main() {
	require_root
	require_cmd git
	require_cmd make
	require_cmd cmake

	install_build_deps

	log "Fetching latest btop release tag..."
	local latest_tag
	latest_tag="$(get_latest_tag || true)"
	[[ -n $latest_tag ]] || error "Could not determine latest release tag."

	log "Latest release tag: ${latest_tag}"
	local latest_stripped="${latest_tag#v}"

	local current
	current="$(get_current_version)"
	if [[ -n $current ]]; then
		log "Currently installed btop version: ${current}"
		if [[ $current == "$latest_stripped" || $current == "$latest_tag" ]]; then
			log "btop is already up to date. Nothing to do."
			exit 0
		fi
	else
		log "btop is not currently installed."
	fi

	build_and_install "$latest_tag"
}

main "$@"