#!/bin/bash

# Automatically install/update Go (golang) to the latest stable version
# on Linux systems using official tarballs.
# - Fetch latest stable version from go.dev
# - Download the appropriate tarball for the system architecture
# - Install into /usr/local/go
# - Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail  # exit on error, unset variable, or failing pipeline

# Basic PATH (important when run from cron)
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Optional torsocks for network operations
if command -v torsocks >/dev/null 2>&1; then
    TORSOCKS="torsocks"
else
    TORSOCKS=""
fi

GO_BASE_URL="https://go.dev/dl"
VERSION_URL="https://go.dev/VERSION?m=text"
INSTALL_DIR="/usr/local"
GO_ROOT="${INSTALL_DIR}/go"

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

# Ensure we run as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
fi

# Helper to ensure required commands exist
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

require_cmd curl
require_cmd tar
require_cmd install

net_curl() {
    if [[ -n "$TORSOCKS" ]]; then
        "$TORSOCKS" curl -fLsS --retry 5 "$@"
    else
        curl -fLsS --retry 5 "$@"
    fi
}

OS="$(uname -s)"
if [[ "$OS" != "Linux" ]]; then
    error "this script currently supports only Linux."
fi

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

echo "Checking latest Go version from go.dev..."
LATEST_VERSION="$(get_latest_go_version || true)"

if [[ -z "${LATEST_VERSION}" ]]; then
    error "could not fetch latest Go version from ${VERSION_URL}."
fi

echo "Latest available Go version: ${LATEST_VERSION}"

# Detect currently installed version (if any)
CURRENT_VERSION=""
if command -v go >/dev/null 2>&1; then
    # Example: 'go version' → go version go1.25.5 linux/amd64
    CURRENT_VERSION="$(go version 2>/dev/null | awk '{print $3}')"
fi

if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Currently installed Go version: ${CURRENT_VERSION}"
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Go is already up to date. Nothing to do."
        exit 0
    fi
else
    echo "Go is not currently installed."
fi

# Determine architecture
ARCH="$(uname -m)"
GO_ARCH=""

case "$ARCH" in
    # 64-bit x86
    x86_64|amd64)
        GO_ARCH="amd64"
        ;;
    # 32-bit x86
    i386|i486|i586|i686|x86)
        GO_ARCH="386"
        ;;
    # 64-bit ARM
    aarch64|arm64)
        GO_ARCH="arm64"
        ;;
    # 32-bit ARM
    armv6l)
        # Go provides linux-armv6l tarball
        GO_ARCH="armv6l"
        ;;
    armv7l|armv7hl|armv7)
        # Go upstream recommends using the armv6l tarball for 32-bit ARM
        GO_ARCH="armv6l"
        ;;
    # LoongArch
    loongarch64)
        GO_ARCH="loong64"
        ;;
    # MIPS (big-endian 32/64)
    mips)
        GO_ARCH="mips"
        ;;
    mips64)
        GO_ARCH="mips64"
        ;;
    # MIPS (little-endian 32/64)
    mipsel|mipsle)
        GO_ARCH="mipsle"
        ;;
    mips64el|mips64le)
        GO_ARCH="mips64le"
        ;;
    # PowerPC 64-bit (big- and little-endian)
    ppc64)
        GO_ARCH="ppc64"
        ;;
    ppc64le|ppc64el)
        GO_ARCH="ppc64le"
        ;;
    # RISC-V 64
    riscv64)
        GO_ARCH="riscv64"
        ;;
    # IBM Z (s390x)
    s390x)
        GO_ARCH="s390x"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}."
        echo "No matching official Go Linux tarball known for this arch."
        exit 1
        ;;
esac

TAR_NAME="${LATEST_VERSION}.linux-${GO_ARCH}.tar.gz"
TAR_URL="${GO_BASE_URL}/${TAR_NAME}"

# Create a temporary file for the tarball
TAR_FILE="$(mktemp /tmp/go-XXXXXX.tar.gz)"
cleanup() {
    rm -f "$TAR_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "Downloading ${TAR_NAME} (GO_ARCH=${GO_ARCH}, uname -m=${ARCH}) from ${TAR_URL}..."
if ! net_curl "$TAR_URL" -o "$TAR_FILE"; then
    error "download failed from ${TAR_URL}"
fi

echo "Download complete: ${TAR_FILE}"
echo "Installing Go into ${GO_ROOT}..."

# Ensure the installation directory exists (using install)
install -d -m 0755 "${INSTALL_DIR}"

# Remove previous Go tree if present
if [[ -d "$GO_ROOT" ]]; then
    echo "Removing previous Go installation at ${GO_ROOT}..."
    rm -rf "$GO_ROOT"
fi

# Extract the new Go tree under /usr/local
tar -C "$INSTALL_DIR" -xzf "$TAR_FILE"

echo "Go installation finished successfully."
echo "Installed version:"
"${GO_ROOT}/bin/go" version || true

# Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile
ensure_go_path_in_etc_profile() {
    local profile_file="/etc/profile"
    local backup_suffix
    local go_path_snippet

    go_path_snippet=$'# Go binary path\nexport PATH="$PATH:/usr/local/go/bin"\n'

    if [[ ! -f "$profile_file" ]]; then
        warn "${profile_file} not found; cannot automatically update system PATH."
        return 0
    fi

    if grep -q '/usr/local/go/bin' "$profile_file"; then
        echo "${profile_file} already contains /usr/local/go/bin in PATH. No changes made."
        return 0
    fi

    backup_suffix="$(date +%Y%m%d%H%M%S)"
    cp "$profile_file" "${profile_file}.bak.${backup_suffix}"
    echo "Backup of ${profile_file} created at ${profile_file}.bak.${backup_suffix}"

    printf '\n%s' "$go_path_snippet" >> "$profile_file"
    echo "${profile_file} updated to include /usr/local/go/bin in PATH."
}

ensure_go_path_in_etc_profile

echo
echo "Done."
echo "Log out and log back in (or source /etc/profile) to ensure the new PATH is applied."
