#!/bin/bash

# Automatically update fastfetch on Debian-based systems.
# - Fetch latest release tag from GitHub
# - Download .deb package from GitHub releases
# - Install the .deb package via apt/apt-get
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail  # exit on error, unset variable, or failing pipeline

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Optional torsocks for network operations
if command -v torsocks >/dev/null 2>&1; then
    TORSOCKS="torsocks"
else
    TORSOCKS=""
fi

REPO="fastfetch-cli/fastfetch"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

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

net_curl() {
    if [[ -n "$TORSOCKS" ]]; then
        "$TORSOCKS" curl -fLsS --retry 5 "$@"
    else
        curl -fLsS --retry 5 "$@"
    fi
}

apt_net() {
    if [[ -n "$TORSOCKS" ]]; then
        "$TORSOCKS" "$@"
    else
        "$@"
    fi
}

if ! command -v apt-get >/dev/null 2>&1 && ! command -v apt >/dev/null 2>&1; then
    error "neither 'apt-get' nor 'apt' is available."
fi

# Get the latest version tag from GitHub releases
get_latest_release() {
    # Read all JSON into a variable to avoid SIGPIPE / curl error 23
    local json
    if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
        return 1
    fi
    awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

echo "Checking latest fastfetch release from GitHub..."
LATEST_VERSION="$(get_latest_release || true)"

if [[ -z "${LATEST_VERSION}" ]]; then
    error "could not fetch latest release version from GitHub."
fi

# Strip leading 'v' if present (tags are often like 'v2.55.1')
LATEST_VERSION_STRIPPED="${LATEST_VERSION#v}"

echo "Latest release tag: ${LATEST_VERSION}"

# Detect currently installed version (if any)
CURRENT_VERSION=""
if command -v fastfetch >/dev/null 2>&1; then
    # Try to extract something like 2.55.1 from the version output
    CURRENT_VERSION="$(fastfetch --version 2>/dev/null \
        | awk 'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){print substr($0,RSTART,RLENGTH); exit}')"
fi

if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Currently installed fastfetch version: ${CURRENT_VERSION}"
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" || "$CURRENT_VERSION" == "$LATEST_VERSION_STRIPPED" ]]; then
        echo "Fastfetch is already up to date. Nothing to do."
        exit 0
    fi
else
    echo "Fastfetch is not currently installed."
fi

# Determine architecture
ARCH="$(uname -m)"
PKG_ARCH=""

case "$ARCH" in
    # 64-bit x86
    x86_64|amd64)
        PKG_ARCH="amd64"
        ;;
    # 64-bit ARM
    aarch64|arm64)
        PKG_ARCH="aarch64"
        ;;
    # 32-bit ARM v6
    armv6l)
        PKG_ARCH="armv6l"
        ;;
    # 32-bit ARM v7 (armhf en Debian)
    armv7l|armv7hl)
        PKG_ARCH="armv7l"
        ;;
    # 32-bit x86
    i386|i686)
        PKG_ARCH="i686"
        ;;
    # PowerPC 64-bit little-endian (Debian usa ppc64el)
    ppc64le|ppc64el)
        PKG_ARCH="ppc64le"
        ;;
    # RISC-V 64
    riscv64)
        PKG_ARCH="riscv64"
        ;;
    # IBM Z (s390x)
    s390x)
        PKG_ARCH="s390x"
        ;;
    *)
        error "Unsupported architecture: ${ARCH}"
        ;;
esac

DEB_URL="https://github.com/${REPO}/releases/download/${LATEST_VERSION}/fastfetch-linux-${PKG_ARCH}.deb"

# Create a temporary file for the .deb
DEB_FILE="$(mktemp /tmp/fastfetch-XXXXXX.deb)"
cleanup() {
    rm -f "$DEB_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "Downloading fastfetch ${LATEST_VERSION} (${PKG_ARCH})..."
if ! net_curl "$DEB_URL" -o "$DEB_FILE"; then
    error "download failed from ${DEB_URL}"
fi

echo "Download complete: ${DEB_FILE}"
echo "Installing the package..."

if command -v apt-get >/dev/null 2>&1; then
    apt_net apt-get install -y "$DEB_FILE"
else
    apt_net apt install -y "$DEB_FILE"
fi

echo "Fastfetch installation finished successfully."
