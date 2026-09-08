#!/bin/bash
set -euo pipefail

# Debian openrsync install/update script.
# Builds openrsync from source and installs it to /usr/local.
# Build dependencies are installed via apt and
# privileged steps use sudo.
#
# Upstream release tags are stale; this tracks the latest
# master branch commit instead.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO="https://github.com/kristapsdz/openrsync.git"
PREFIX="/usr/local"
INSTALL_PATH="/usr/local/bin/openrsync"
BUILD_DIR="${HOME}/.local/src/openrsync-build"
ROOT_CMD=""
LATEST_COMMIT=""
SOURCE_CHANGED=0

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_sudo_or_root() {
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
		log "Running as root; no sudo needed."
	elif have_cmd sudo; then
		ROOT_CMD="sudo"
		log "Using sudo for privileged operations."
	else
		error "sudo is required to install into /usr/local"
	fi
}

run_root() {
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
}

ensure_debian() {
	if [ -f /etc/os-release ]; then
		# shellcheck source=/dev/null
		. /etc/os-release
		case "${ID:-}:${VERSION_ID:-}" in
		debian:13) return 0 ;;
		esac
	fi

	error "This script targets Debian 13."
}

install_build_deps() {
	local missing=()
	local pkg

	for pkg in git bmake build-essential zlib1g-dev; do
		if ! dpkg -s "$pkg" >/dev/null 2>&1; then
			missing+=("$pkg")
		fi
	done

	if [ "${#missing[@]}" -eq 0 ]; then
		return
	fi

	log "Installing build dependencies via apt"
	run_root apt-get update -qq >/dev/null
	run_root apt-get install -y -qq "${missing[@]}" >/dev/null
}

get_latest_commit() {
	git ls-remote --heads "$REPO" refs/heads/master 2>/dev/null |
		awk '{print $1}'
}

prepare_source() {
	if [ ! -d "$BUILD_DIR/.git" ]; then
		log "Cloning openrsync repository"
		rm -rf "$BUILD_DIR"
		mkdir -p "$(dirname "$BUILD_DIR")"
		git clone --quiet "$REPO" "$BUILD_DIR"
	fi

	cd "$BUILD_DIR"
	log "Fetching latest upstream changes"
	git fetch --quiet --prune origin

	LATEST_COMMIT="$(get_latest_commit)"
	[ -n "$LATEST_COMMIT" ] || error "Could not determine latest openrsync commit"

	local current_commit
	current_commit="$(git rev-parse HEAD)"

	if [ "$current_commit" = "$LATEST_COMMIT" ]; then
		log "Source already at latest commit '$LATEST_COMMIT'"
		SOURCE_CHANGED=0
		return 0
	fi

	log "Checking out latest commit '$LATEST_COMMIT'"
	git checkout --quiet "$LATEST_COMMIT"
	SOURCE_CHANGED=1
	return 0
}

build_and_install() {
	cd "$BUILD_DIR"

	log "Configuring openrsync"
	if ! env -u LD_PRELOAD ./configure PREFIX="$PREFIX"; then
		error "openrsync configure failed"
	fi

	log "Building openrsync from source"
	if ! env -u LD_PRELOAD bmake -s -C "$BUILD_DIR"; then
		error "openrsync build failed"
	fi

	log "Installing to $PREFIX"
	run_root bmake -s -C "$BUILD_DIR" install
}

verify_install() {
	if [ -x "$INSTALL_PATH" ]; then
		log "openrsync installed successfully at $INSTALL_PATH"
	else
		error "Installation failed: $INSTALL_PATH not found or not executable"
	fi
}

main() {
	ensure_debian
	require_sudo_or_root
	install_build_deps
	prepare_source
	if [ "$SOURCE_CHANGED" -eq 1 ] || [ ! -x "$INSTALL_PATH" ]; then
		build_and_install
		verify_install
		if [ "$SOURCE_CHANGED" -eq 1 ]; then
			log "Done - openrsync updated to $LATEST_COMMIT"
			log "and is available at $INSTALL_PATH"
		else
			log "Done - openrsync installed at $INSTALL_PATH"
		fi
	else
		verify_install
		log "Done - openrsync already at latest source commit"
		log "($LATEST_COMMIT)"
	fi
}

main "$@"
