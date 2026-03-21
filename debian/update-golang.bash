#!/bin/bash

set -euo pipefail

# Debian golang update script
# Automatically install/update Go (golang) to the latest stable version
# on Linux systems using official tarballs.
# - Fetch latest stable version from go.dev
# - Download the appropriate tarball for the system architecture
# - Install into /usr/local/go
# - Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

GO_BASE_URL="https://go.dev/dl"
VERSION_URL="https://go.dev/VERSION?m=text"
INSTALL_DIR="/usr/local"
GO_ROOT="${INSTALL_DIR}/go"

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

# Get the latest stable Go version (e.g. go1.25.5) from go.dev
get_latest_go_version() {
	local ver
	if ! ver="$(net_curl "$VERSION_URL" 2>/dev/null)"; then
		return 1
	fi
	# Strip trailing whitespace/newlines
	ver="${ver%%[[:space:]]*}"
	printf '%s\n' "$ver"
}

detect_go_arch() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
	x86_64 | amd64) printf '%s\n' "amd64" ;;
	i386 | i486 | i586 | i686 | x86) printf '%s\n' "386" ;;
	aarch64 | arm64) printf '%s\n' "arm64" ;;
	armv6l) printf '%s\n' "armv6l" ;;
	armv7l | armv7hl | armv7) printf '%s\n' "armv6l" ;;
	loongarch64) printf '%s\n' "loong64" ;;
	mips) printf '%s\n' "mips" ;;
	mips64) printf '%s\n' "mips64" ;;
	mipsel | mipsle) printf '%s\n' "mipsle" ;;
	mips64el | mips64le) printf '%s\n' "mips64le" ;;
	ppc64) printf '%s\n' "ppc64" ;;
	ppc64le | ppc64el) printf '%s\n' "ppc64le" ;;
	riscv64) printf '%s\n' "riscv64" ;;
	s390x) printf '%s\n' "s390x" ;;
	*) error "Unsupported architecture: ${arch}. No matching official Go Linux tarball known for this arch." ;;
	esac
}

# Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile
ensure_go_path_in_etc_profile() {
	local profile_file="/etc/profile"
	local backup_suffix
	local go_path_snippet

	go_path_snippet=$'# Go binary path\nexport PATH="$PATH:/usr/local/go/bin"\n'

	if [[ ! -f $profile_file ]]; then
		warn "${profile_file} not found; cannot automatically update system PATH."
		return 0
	fi

	if grep -q '/usr/local/go/bin' "$profile_file"; then
		log "${profile_file} already contains /usr/local/go/bin in PATH. No changes made."
		return 0
	fi

	backup_suffix="$(date +%Y%m%d%H%M%S)"
	cp "$profile_file" "${profile_file}.bak.${backup_suffix}"
	log "Backup of ${profile_file} created at ${profile_file}.bak.${backup_suffix}"

	printf '\n%s' "$go_path_snippet" >>"$profile_file"
	log "${profile_file} updated to include /usr/local/go/bin in PATH."
}

run_golang_update() {
	OS="$(uname -s)"
	if [[ $OS != "Linux" ]]; then
		error "this script currently supports only Linux."
	fi

	log "Checking latest Go version from go.dev..."
	LATEST_VERSION="$(get_latest_go_version || true)"
	if [[ -z ${LATEST_VERSION} ]]; then
		error "could not fetch latest Go version from ${VERSION_URL}."
	fi
	log "Latest available Go version: ${LATEST_VERSION}"

	CURRENT_VERSION=""
	if command -v go >/dev/null 2>&1; then
		CURRENT_VERSION="$(go version 2>/dev/null | awk '{print $3}')"
	fi
	if [[ -n $CURRENT_VERSION ]]; then
		log "Currently installed Go version: ${CURRENT_VERSION}"
		if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
			log "Go is already up to date. Nothing to do."
			return 0
		fi
	else
		log "Go is not currently installed."
	fi

	GO_ARCH="$(detect_go_arch)"
	TAR_NAME="${LATEST_VERSION}.linux-${GO_ARCH}.tar.gz"
	TAR_URL="${GO_BASE_URL}/${TAR_NAME}"
	TAR_FILE="$(mktemp /tmp/go-XXXXXX.tar.gz)"
	trap 'rm -f "$TAR_FILE" 2>/dev/null || true' EXIT

	log "Downloading ${TAR_NAME} from ${TAR_URL}..."
	if ! net_curl "$TAR_URL" -o "$TAR_FILE"; then
		error "download failed from ${TAR_URL}"
	fi

	log "Download complete: ${TAR_FILE}"
	log "Installing Go into ${GO_ROOT}..."
	install -d -m 0755 "${INSTALL_DIR}"
	if [[ -d $GO_ROOT ]]; then
		log "Removing previous Go installation at ${GO_ROOT}..."
		rm -rf "$GO_ROOT"
	fi
	tar -C "$INSTALL_DIR" -xzf "$TAR_FILE"

	log "Go installation finished successfully."
	log "Installed version:"
	"${GO_ROOT}/bin/go" version || true

	ensure_go_path_in_etc_profile
	log "Done."
	log "Log out and log back in (or source /etc/profile) to ensure the new PATH is applied."
}

run_update() {
	run_golang_update
}

check_prereqs() {
	require_root
	require_cmd curl
	require_cmd tar
	require_cmd install
	require_cmd uname
	require_cmd mktemp
}

main() {
	check_prereqs
	run_update
}

main "$@"
