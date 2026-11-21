#!/bin/bash

set -euo pipefail

# Debian fastfetch update script
# Automatically update fastfetch on Debian-based systems.
# - Fetch latest release tag from GitHub
# - Download .deb package from GitHub releases
# - Install the .deb package via apt/apt-get
#
# Requirements: root privileges, network access, curl, awk, uname,
# find, and mktemp, plus either apt-get or apt. gh and git are optional;
# gh can also download the release asset when available.
#
# Side effects:
#  - Downloads the release .deb into a temporary directory under /tmp
#  - Installs it with apt-get/apt and removes the temporary directory
#    on exit
#
# Verify the exact GitHub release digest and Debian package metadata before
# invoking APT. The digest is authenticated by the GitHub release channel.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Preserve the original path and arguments so require_root can re-exec the
# script through sudo without losing user-supplied options.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	SCRIPT_PATH="${BASH_SOURCE[0]}"
else
	SCRIPT_PATH="$0"
fi
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_ARGS=("$@")

REPO="fastfetch-cli/fastfetch"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
RELEASE_HELPER="${SCRIPT_PATH%/*}/release-verify"
if [[ ! -f $RELEASE_HELPER ]]; then
	RELEASE_HELPER="${SCRIPT_PATH%/*}/../scripts/release-verify.pl"
fi

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
ROOT_ENV_VARS=()

require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
	fi
	local -a env_args=()
	local name
	for name in "${ROOT_ENV_VARS[@]}"; do
		if [[ -v $name ]]; then
			env_args+=("$name=${!name}")
		fi
	done
	log "Re-executing this script via sudo to gain root privileges..."
	if ((${#env_args[@]} > 0)); then
		exec sudo -- env "${env_args[@]}" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
	fi
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

# Helper to ensure required commands exist
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

net_curl() {
	curl -fLsS --retry 5 --proto '=https' --proto-redir '=https' "$@"
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

ensure_apt() {
	if ! command -v apt-get >/dev/null 2>&1 &&
		! command -v apt >/dev/null 2>&1; then
		error "neither 'apt-get' nor 'apt' is available."
	fi
}

get_release_metadata() {
	local metadata
	if has_cmd gh && metadata=$(gh api "repos/$REPO/releases/latest"); then
		printf '%s\n' "$metadata"
		return 0
	fi
	net_curl "$API_URL"
}

# Map the kernel machine type to the architecture string used in the
# upstream .deb asset name. The mapping is intentionally separate from
# Debian architecture names and does not use dpkg.
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
	loong64 | loongarch64) printf '%s\n' "loongarch64" ;;
	*) error "Unsupported architecture: ${arch}" ;;
	esac
}

verify_package_metadata() {
	local file="$1" expected_version="$2" architecture version
	architecture=$(dpkg --print-architecture) || return 1
	version=$(dpkg-deb -f "$file" Version) || return 1
	[[ $(dpkg-deb -f "$file" Package) == fastfetch ]] &&
		[[ $(dpkg-deb -f "$file" Architecture) == "$architecture" ]] &&
		[[ $version == "$expected_version" || $version == "$expected_version"-* ]]
}

run_fastfetch_update() {
	local metadata asset url expected_digest actual_digest
	log "Checking latest fastfetch release from GitHub..."
	metadata=$(get_release_metadata) || error "could not fetch release metadata."
	LATEST_VERSION=$(perl "$RELEASE_HELPER" json-tag <<<"$metadata") ||
		error "missing release tag."
	[[ $LATEST_VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		error "invalid release tag: $LATEST_VERSION"
	LATEST_VERSION_STRIPPED="${LATEST_VERSION#v}"
	log "Latest release tag: ${LATEST_VERSION}"

	CURRENT_VERSION=""
	if command -v fastfetch >/dev/null 2>&1; then
		CURRENT_VERSION="$(fastfetch --version \
			2>/dev/null | awk \
			'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){
				print substr($0,RSTART,RLENGTH);
				exit}')"
	fi
	if [[ -n $CURRENT_VERSION ]]; then
		log "Currently installed fastfetch version: ${CURRENT_VERSION}"
		if [[ $CURRENT_VERSION == "$LATEST_VERSION" ||
			$CURRENT_VERSION == "$LATEST_VERSION_STRIPPED" ]]; then
			log "Fastfetch is already up to date. Nothing to do."
			return 0
		fi
	else
		log "Fastfetch is not currently installed."
	fi

	PKG_ARCH="$(detect_pkg_arch)"
	# The trap covers every later error path; no manual cleanup is
	# needed after this point.
	WORK_DIR="$(mktemp -d /tmp/fastfetch-XXXXXX)"
	DEB_FILE="$WORK_DIR/fastfetch-linux-${PKG_ARCH}.deb"
	trap 'rm -rf "$WORK_DIR" 2>/dev/null || true' EXIT

	asset="fastfetch-linux-${PKG_ARCH}.deb"
	url=$(perl "$RELEASE_HELPER" json-asset-url "$asset" <<<"$metadata") ||
		error "could not identify exact release asset: $asset"
	[[ $url == "https://github.com/$REPO/releases/download/$LATEST_VERSION/$asset" ]] ||
		error "unexpected release asset URL."
	expected_digest=$(perl "$RELEASE_HELPER" json-asset-digest "$url" <<<"$metadata") ||
		error "missing release asset digest."
	[[ $expected_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
		error "invalid release asset digest."
	expected_digest=${expected_digest#sha256:}
	log "Downloading fastfetch ${LATEST_VERSION} (${PKG_ARCH})..."
	net_curl "$url" -o "$DEB_FILE" || error "download failed."
	actual_digest=$(sha256sum <"$DEB_FILE") || error "could not hash package."
	[[ ${actual_digest%% *} == "$expected_digest" ]] ||
		error "fastfetch package digest mismatch."
	verify_package_metadata "$DEB_FILE" "$LATEST_VERSION_STRIPPED" ||
		error "fastfetch package metadata does not match the release and host."

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
	require_cmd perl
	require_cmd sha256sum
	require_cmd dpkg
	require_cmd dpkg-deb
	[[ -f $RELEASE_HELPER ]] || error "release verifier not found."
	require_cmd mktemp
	ensure_apt
}

main() {
	check_prereqs
	run_update
}

main "$@"
