#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

#
# Automatically update fastfetch on Debian-based systems.
# - Fetch latest release tag from GitHub
# - Download .deb package from GitHub releases
# - Install the .deb package via apt/apt-get
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="fastfetch-cli/fastfetch"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

# Ensure we run as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

# Helper to ensure required commands exist
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command '$1' is not installed or not in PATH."
        exit 1
    fi
}

require_cmd curl

if ! command -v apt-get >/dev/null 2>&1 && ! command -v apt >/dev/null 2>&1; then
    echo "Error: neither 'apt-get' nor 'apt' is available."
    exit 1
fi

# Get the latest version tag from GitHub releases
get_latest_release() {
    # Read all JSON into a variable to avoid SIGPIPE / curl error 23
    local json
    if ! json="$(curl -fLsS --retry 5 "$API_URL" 2>/dev/null)"; then
        return 1
    fi
    awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

echo "Checking latest fastfetch release from GitHub..."
LATEST_VERSION="$(get_latest_release || true)"

if [[ -z "${LATEST_VERSION}" ]]; then
    echo "Error: could not fetch latest release version from GitHub."
    exit 1
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
        echo "Unsupported architecture: ${ARCH}"
        exit 1
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
if ! curl -fLsS --retry 5 "$DEB_URL" -o "$DEB_FILE"; then
    echo "Error: download failed from ${DEB_URL}"
    exit 1
fi

echo "Download complete: ${DEB_FILE}"
echo "Installing the package..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y "$DEB_FILE"
else
    apt install -y "$DEB_FILE"
fi

echo "Fastfetch installation finished successfully."
