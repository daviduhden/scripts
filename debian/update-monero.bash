#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

#
# Automatically install/update Monero CLI to the latest stable version
# on Linux systems using official tarballs.
# - Fetch latest tag from GitHub
# - Download CLI tarball from downloads.getmonero.org
# - Install binaries into /usr/bin
# - Ensure "monero" system user and directories exist
# - Download official monerod systemd unit (always replace)
# - Create a basic /etc/monerod.conf if it does not exist
# - Enable and start/restart monerod service
#
# Supported Linux architectures (official Monero CLI binaries):
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="monero-project/monero"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
DOWNLOAD_BASE="https://downloads.getmonero.org/cli"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/systemd/monerod.service"

INSTALL_DIR="/usr/bin"
MONERO_USER="monero"
MONERO_DATA_DIR="/var/lib/monero"
MONERO_LOG_DIR="/var/log/monero"
MONEROD_CONF="/etc/monerod.conf"

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
require_cmd tar
require_cmd awk
require_cmd systemctl
require_cmd install

# Get the latest release tag from GitHub
get_latest_release() {
    local json
    if ! json="$(curl -fsSL "$API_URL" 2>/dev/null)"; then
        return 1
    fi
    awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

echo "Checking latest Monero CLI release from GitHub..."
LATEST_TAG="$(get_latest_release || true)"

if [[ -z "${LATEST_TAG}" ]]; then
    echo "Error: could not fetch latest release tag from GitHub."
    exit 1
fi

echo "Latest available tag: ${LATEST_TAG}"

# Detect currently installed version (if any)
CURRENT_VERSION_RAW=""
if command -v monerod >/dev/null 2>&1; then
    CURRENT_VERSION_RAW="$(monerod --version 2>/dev/null | awk 'NR==1{print}')"
    echo "Current 'monerod --version' output: ${CURRENT_VERSION_RAW:-unknown}"

    # If current version string contains the latest tag, assume it's up to date
    if [[ -n "${CURRENT_VERSION_RAW}" && "${CURRENT_VERSION_RAW}" == *"${LATEST_TAG}"* ]]; then
        echo "Monero CLI already appears to be at the latest version (${LATEST_TAG}). Nothing to do."
        exit 0
    fi
else
    echo "Monero CLI is not currently installed (or not in PATH)."
fi

# Map architecture to CLI tarball platform name
ARCH="$(uname -m)"
PLATFORM=""
case "$ARCH" in
    x86_64|amd64)
        PLATFORM="linux-x64"
        ;;
    i386|i686)
        PLATFORM="linux-x86"
        ;;
    aarch64|arm64)
        PLATFORM="linux-armv8"
        ;;
    armv7l|armv7*)
        PLATFORM="linux-armv7"
        ;;
    riscv64)
        PLATFORM="linux-riscv64"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

TARBALL="monero-${PLATFORM}-${LATEST_TAG}.tar.bz2"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${TARBALL}"

echo "Detected architecture: ${ARCH} -> ${PLATFORM}"
echo "Tarball to download: ${TARBALL}"
echo "Download URL: ${DOWNLOAD_URL}"

# Temporary working directory
TMPDIR="$(mktemp -d /tmp/monero-cli-XXXXXX)"
cleanup() {
    rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "Downloading Monero CLI ${LATEST_TAG}..."
if ! curl -fL -o "${TMPDIR}/${TARBALL}" "${DOWNLOAD_URL}"; then
    echo "Error: download failed from ${DOWNLOAD_URL}"
    exit 1
fi

echo "Extracting tarball..."
tar -xjf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

EXTRACTED_DIR="$(find "$TMPDIR" -maxdepth 1 -type d -name 'monero-*' | head -n1)"
if [[ -z "${EXTRACTED_DIR}" ]]; then
    echo "Error: could not find extracted Monero directory."
    exit 1
fi

echo "Extracted directory: ${EXTRACTED_DIR}"

# Stop monerod if it is running
echo "Stopping monerod service if it is running..."
WAS_ACTIVE=0
if systemctl is-active --quiet monerod; then
    WAS_ACTIVE=1
    systemctl stop monerod
fi

# Install binaries
echo "Installing binaries into ${INSTALL_DIR}..."

install -d "${INSTALL_DIR}"

shopt -s nullglob
for bin in "${EXTRACTED_DIR}"/monerod "${EXTRACTED_DIR}"/monero-*; do
    if [[ -f "$bin" && -x "$bin" ]]; then
        echo " -> installing $(basename "$bin")"
        install -m 0755 "$bin" "${INSTALL_DIR}/"
    fi
done
shopt -u nullglob

# Ensure monero user and directories
echo "Ensuring monero system user and directories exist..."

if ! id -u "${MONERO_USER}" >/dev/null 2>&1; then
    echo "Creating system user '${MONERO_USER}'..."
    useradd --system --home-dir "${MONERO_DATA_DIR}" --shell /usr/sbin/nologin "${MONERO_USER}"
fi

mkdir -p "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"
chown -R "${MONERO_USER}:${MONERO_USER}" "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"

# Create a basic config file if it does not exist
if [[ ! -f "${MONEROD_CONF}" ]]; then
    echo "Creating basic monerod config at ${MONEROD_CONF}..."
    cat >"${MONEROD_CONF}" <<EOF
# Basic configuration for monerod generated by update script.
# Adjust to your needs. Check 'monerod --help' for more options.

data-dir=${MONERO_DATA_DIR}
log-file=${MONERO_LOG_DIR}/monerod.log
log-level=0
db-sync-mode=safe

# Limit log size
max-log-file-size=10485760
max-log-files=5
EOF
    chmod 644 "${MONEROD_CONF}"
fi

# Update systemd unit from the official repository (always replace)
echo "Updating systemd unit: /etc/systemd/system/monerod.service..."
install -d /etc/systemd/system

UNIT_TMP="${TMPDIR}/monerod.service"
if ! curl -fsSL "${SYSTEMD_UNIT_URL}" -o "${UNIT_TMP}"; then
    echo "Error: failed to download systemd unit from ${SYSTEMD_UNIT_URL}"
    exit 1
fi

# This always overwrites the target file, whether it exists or not
install -m 0644 "${UNIT_TMP}" /etc/systemd/system/monerod.service

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling monerod service at boot..."
systemctl enable monerod >/dev/null 2>&1 || true

if [[ "$WAS_ACTIVE" -eq 1 ]]; then
    echo "Restarting monerod..."
    systemctl restart monerod
else
    echo "monerod was not running before."
    echo "You can start it now with:"
    echo "  systemctl start monerod"
fi

# Show final version
if command -v monerod >/dev/null 2>&1; then
    echo "Installed Monero CLI version:"
    monerod --version | head -n1 || true
fi

echo "Monero CLI update completed successfully."
