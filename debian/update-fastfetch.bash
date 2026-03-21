#!/bin/bash

set -euo pipefail

# Debian fastfetch update script
# Automatically update fastfetch on Debian-based systems.
# - Fetch latest release tag from GitHub
# - Download .deb package from GitHub releases
# - Install the .deb package via apt/apt-get
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="fastfetch-cli/fastfetch"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
REPO_URL="https://github.com/${REPO}.git"

# Simple colors for messages
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
error() {
	printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2
	exit 1
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi
}

# Helper to ensure required commands exist
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

ensure_apt() {
	if ! command -v apt-get >/dev/null 2>&1 && ! command -v apt >/dev/null 2>&1; then
		error "neither 'apt-get' nor 'apt' is available."
	fi
}

# Get the latest version tag from GitHub releases
get_latest_release() {
	local tag json

	if has_cmd gh; then
		tag="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
		if [[ -n $tag ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	if has_cmd git; then
		tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null |
			awk '{print $2}' |
			sed 's#refs/tags/##' |
			sed 's/\^{}//' |
			sort -Vr |
			head -n1)"
		if [[ -n $tag ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
		return 1
	fi
	awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

detect_pkg_arch() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
	x86_64 | amd64) printf '%s\n' "amd64" ;;
	aarch64 | arm64) printf '%s\n' "aarch64" ;;
	armv6l) printf '%s\n' "armv6l" ;;
	armv7l | armv7hl) printf '%s\n' "armv7l" ;;
	i386 | i686) printf '%s\n' "i686" ;;
	ppc64le | ppc64el) printf '%s\n' "ppc64le" ;;
	riscv64) printf '%s\n' "riscv64" ;;
	s390x) printf '%s\n' "s390x" ;;
	*) error "Unsupported architecture: ${arch}" ;;
	esac
}

download_deb() {
	local version="$1" arch="$2" out_dir="$3" out_file="$4" url

	if has_cmd gh; then
		log "Attempting download via GitHub CLI..."
		if gh release download "$version" --repo "$REPO" --pattern "fastfetch-linux-${arch}.deb" --dir "$out_dir" --clobber >/dev/null 2>&1; then
			return 0
		fi
		warn "gh release download failed; falling back to curl."
	fi

	url="https://github.com/${REPO}/releases/download/${version}/fastfetch-linux-${arch}.deb"
	net_curl "$url" -o "$out_file"
}

run_fastfetch_update() {
	log "Checking latest fastfetch release from GitHub..."
	LATEST_VERSION="$(get_latest_release || true)"
	if [[ -z ${LATEST_VERSION} ]]; then
		error "could not fetch latest release version from GitHub."
	fi
	LATEST_VERSION_STRIPPED="${LATEST_VERSION#v}"
	log "Latest release tag: ${LATEST_VERSION}"

	CURRENT_VERSION=""
	if command -v fastfetch >/dev/null 2>&1; then
		CURRENT_VERSION="$(fastfetch --version 2>/dev/null | awk 'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){print substr($0,RSTART,RLENGTH); exit}')"
	fi
	if [[ -n $CURRENT_VERSION ]]; then
		log "Currently installed fastfetch version: ${CURRENT_VERSION}"
		if [[ $CURRENT_VERSION == "$LATEST_VERSION" || $CURRENT_VERSION == "$LATEST_VERSION_STRIPPED" ]]; then
			log "Fastfetch is already up to date. Nothing to do."
			return 0
		fi
	else
		log "Fastfetch is not currently installed."
	fi

	PKG_ARCH="$(detect_pkg_arch)"
	TMPDIR="$(mktemp -d /tmp/fastfetch-XXXXXX)"
	DEB_FILE="$TMPDIR/fastfetch-linux-${PKG_ARCH}.deb"
	trap 'rm -rf "$TMPDIR" 2>/dev/null || true' EXIT

	log "Downloading fastfetch ${LATEST_VERSION} (${PKG_ARCH})..."
	if ! download_deb "$LATEST_VERSION" "$PKG_ARCH" "$TMPDIR" "$DEB_FILE"; then
		error "download failed for fastfetch ${LATEST_VERSION} (${PKG_ARCH})"
	fi

	if [[ ! -f $DEB_FILE ]]; then
		alt_file="$(find "$TMPDIR" -maxdepth 1 -type f -name 'fastfetch-linux-*.deb' | head -n1)"
		if [[ -n $alt_file ]]; then
			DEB_FILE="$alt_file"
		else
			error "download did not produce a .deb file"
		fi
	fi

	log "Download complete: ${DEB_FILE}"
	log "Installing the package..."
	if command -v apt-get >/dev/null 2>&1; then
		apt-get install -y "$DEB_FILE"
	else
		apt install -y "$DEB_FILE"
	fi

	log "Fastfetch installation finished successfully."
}

run_update() {
	run_fastfetch_update
}

check_prereqs() {
	require_root
	require_cmd curl
	require_cmd awk
	require_cmd uname
	require_cmd find
	require_cmd mktemp
	require_cmd head
	ensure_apt
}

main() {
	check_prereqs
	run_update
}

main "$@"
