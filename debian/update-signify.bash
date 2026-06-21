#!/bin/bash
set -euo pipefail

# Debian signify install/update script.
# Builds OpenBSD signify from source and installs it to /usr/local/bin.
# Build dependencies are installed via apt and privileged steps use sudo.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO="https://codeberg.org/aperezdc/signify.git"
INSTALL_PATH="/usr/local/bin/signify"
BUILD_DIR="${HOME}/.local/src/signify-build"
ROOT_CMD=""
LATEST_TAG=""
SOURCE_CHANGED=0
BUILD_LOG=""

################
# Color helpers #
################
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

log() { printf '%s %b[INFO]%b  %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b  %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*" >&2; }
error() {
	printf '%s %b[ERROR]%b %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2
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
		error "sudo is required to install into /usr/local/bin"
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

	for pkg in git clang libbsd-dev; do
		if ! dpkg -s "$pkg" >/dev/null 2>&1; then
			missing+=("$pkg")
		fi
	done

	if [ "${#missing[@]}" -eq 0 ]; then
		return
	fi

	log "Installing build dependencies via apt"
	run_root apt-get update -qq >/dev/null
	run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

get_latest_tag() {
	git ls-remote --tags --sort='version:refname' "$REPO" 'refs/tags/v*' 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s#\^{}##' |
		uniq |
		tail -n1
}

prepare_source() {
	if [ ! -d "$BUILD_DIR/.git" ]; then
		log "Cloning signify repository"
		rm -rf "$BUILD_DIR"
		mkdir -p "$(dirname "$BUILD_DIR")"
		git clone --quiet "$REPO" "$BUILD_DIR"
	fi

	cd "$BUILD_DIR"
	log "Fetching latest tags"
	git fetch --quiet --tags --prune origin

	LATEST_TAG="$(get_latest_tag)"
	[ -n "$LATEST_TAG" ] || error "Could not determine latest signify tag"

	local current_tag
	current_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"

	if [ "$current_tag" = "$LATEST_TAG" ]; then
		log "Source already at latest tag '$LATEST_TAG'"
		SOURCE_CHANGED=0
		return 0
	fi

	log "Checking out latest tag '$LATEST_TAG'"
	git checkout --quiet "tags/$LATEST_TAG"
	SOURCE_CHANGED=1
	return 0
}

build_and_install() {
	log "Building signify from source"
	BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/signify-build.XXXXXX.log")"
	if ! make -s -C "$BUILD_DIR" CC=clang BUNDLED_LIBBSD=1 >"$BUILD_LOG" 2>&1; then
		cat "$BUILD_LOG" >&2
		error "signify build failed"
	fi
	rm -f "$BUILD_LOG"
	BUILD_LOG=""

	log "Installing to $INSTALL_PATH"
	run_root install -m 0755 "$BUILD_DIR/signify" "$INSTALL_PATH"
}

verify_install() {
	if [ -x "$INSTALL_PATH" ]; then
		log "signify installed successfully at $INSTALL_PATH"
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
			log "Done - signify updated to $LATEST_TAG and is available at $INSTALL_PATH"
		else
			log "Done - signify installed at $INSTALL_PATH"
		fi
	else
		verify_install
		log "Done - signify already at latest source tag ($LATEST_TAG)"
	fi
}

cleanup() {
	if [ -n "${BUILD_LOG:-}" ] && [ -f "$BUILD_LOG" ]; then
		rm -f "$BUILD_LOG"
	fi
}

trap cleanup EXIT

main "$@"
