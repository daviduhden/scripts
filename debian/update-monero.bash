#!/bin/bash
set -euo pipefail

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
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="monero-project/monero"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
REPO_URL="https://github.com/${REPO}.git"
DOWNLOAD_BASE="https://downloads.getmonero.org/cli"
HASHES_URL="https://www.getmonero.org/downloads/hashes.txt"
BINARYFATE_KEY_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/systemd/monerod.service"

INSTALL_DIR="/usr/bin"
MONERO_USER="monero"
MONERO_DATA_DIR="/var/lib/monero"
MONERO_LOG_DIR="/var/log/monero"
MONEROD_CONF="/etc/monerod.conf"

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

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
require_cmd awk
require_cmd systemctl
require_cmd install
require_cmd sha256sum
require_cmd gpg

net_curl() {
    curl -fLsS --retry 5 "$@"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Get the latest release tag from GitHub
get_latest_release() {
    local tag json

    if has_cmd gh; then
        tag="$(gh api "repos/${REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)"
        if [[ -n "$tag" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi

    if has_cmd git; then
        tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null \
            | awk '{print $2}' \
            | sed 's#refs/tags/##' \
            | sed 's/\^{}//' \
            | sort -Vr \
            | head -n1)"
        if [[ -n "$tag" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi

    if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
        return 1
    fi
    awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

log "Checking latest Monero CLI release from GitHub..."
LATEST_TAG="$(get_latest_release || true)"

if [[ -z "${LATEST_TAG}" ]]; then
    error "could not fetch latest release tag from GitHub."
fi

log "Latest available tag: ${LATEST_TAG}"

# Detect currently installed version (if any)
CURRENT_VERSION_RAW=""
if command -v monerod >/dev/null 2>&1; then
    CURRENT_VERSION_RAW="$(monerod --version 2>/dev/null | awk 'NR==1{print}')"
    log "Current monerod version line: ${CURRENT_VERSION_RAW:-unknown}"

    # If current version string contains the latest tag, assume it's up to date
    if [[ -n "${CURRENT_VERSION_RAW}" && "${CURRENT_VERSION_RAW}" == *"${LATEST_TAG}"* ]]; then
        log "Monero CLI already at latest version (${LATEST_TAG})."
        exit 0
    fi
else
    log "Monero CLI is not currently installed (or not in PATH)."
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
        error "Unsupported architecture: ${ARCH}"
        ;;
esac

TARBALL="monero-${PLATFORM}-${LATEST_TAG}.tar.bz2"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${TARBALL}"

log "Detected architecture: ${ARCH} -> ${PLATFORM}"
log "Tarball to download: ${TARBALL}"
log "Download URL: ${DOWNLOAD_URL}"

# Temporary working directory
TMPDIR="$(mktemp -d /tmp/monero-cli-XXXXXX)"
GPG_HOME="$(mktemp -d /tmp/monero-gpg-XXXXXX)"
cleanup() {
    rm -rf "$TMPDIR" "$GPG_HOME" 2>/dev/null || true
}
trap cleanup EXIT

log "Downloading Monero CLI ${LATEST_TAG}..."
if ! net_curl "${DOWNLOAD_URL}" -o "${TMPDIR}/${TARBALL}"; then
    error "download failed from ${DOWNLOAD_URL}"
fi

log "Fetching reference hashes for verification..."
HASHES_ASC="${TMPDIR}/hashes.txt"
HASHES_PLAIN="${TMPDIR}/hashes-plain.txt"
BINARYFATE_KEY="${TMPDIR}/binaryfate.asc"

if ! net_curl "${HASHES_URL}" -o "${HASHES_ASC}"; then
    error "failed to download hash list from ${HASHES_URL}"
fi

log "Importing binaryFate signing key for hash verification..."
if ! net_curl "${BINARYFATE_KEY_URL}" -o "${BINARYFATE_KEY}"; then
    error "failed to download binaryFate GPG key"
fi

if ! gpg --homedir "$GPG_HOME" --batch --import "${BINARYFATE_KEY}" >/dev/null 2>&1; then
    error "failed to import binaryFate GPG key"
fi

log "Verifying hashes file signature..."
if ! gpg --homedir "$GPG_HOME" --batch --verify "${HASHES_ASC}" >/dev/null 2>&1; then
    error "hash file signature verification failed"
fi

if ! gpg --homedir "$GPG_HOME" --batch --output "${HASHES_PLAIN}" --decrypt "${HASHES_ASC}" >/dev/null 2>&1; then
    error "failed to decrypt (strip signature from) hashes file"
fi

EXPECTED_HASH="$(awk -v fname="${TARBALL}" '$1 ~ /^[0-9a-f]{64}$/ && $2==fname{print $1; exit}' "${HASHES_PLAIN}")"
if [[ -z "${EXPECTED_HASH}" ]]; then
    error "could not find expected hash for ${TARBALL} in downloaded hash list"
fi

ACTUAL_HASH="$(sha256sum "${TMPDIR}/${TARBALL}" | awk '{print $1}')"
if [[ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]]; then
    error "hash mismatch for ${TARBALL} (expected ${EXPECTED_HASH}, got ${ACTUAL_HASH})"
fi

log "Hash verified for ${TARBALL}."

log "Extracting tarball..."
tar -xjf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

EXTRACTED_DIR="$(find "$TMPDIR" -maxdepth 1 -type d -name 'monero-*' | head -n1)"
if [[ -z "${EXTRACTED_DIR}" ]]; then
    error "could not find extracted Monero directory."
fi

log "Extracted directory: ${EXTRACTED_DIR}"

# Stop monerod if it is running
log "Stopping monerod service if it is running..."
WAS_ACTIVE=0
if systemctl is-active --quiet monerod; then
    WAS_ACTIVE=1
    systemctl stop monerod
fi

# Install binaries
log "Installing binaries into ${INSTALL_DIR}..."

install -d "${INSTALL_DIR}"

shopt -s nullglob
for bin in "${EXTRACTED_DIR}"/monerod "${EXTRACTED_DIR}"/monero-*; do
    if [[ -f "$bin" && -x "$bin" ]]; then
        log " -> installing $(basename "$bin")"
        install -m 0755 "$bin" "${INSTALL_DIR}/"
    fi
done
shopt -u nullglob

# Ensure monero user and directories
log "Ensuring monero system user and directories exist..."

if ! id -u "${MONERO_USER}" >/dev/null 2>&1; then
    log "Creating system user '${MONERO_USER}'..."
    useradd --system --home-dir "${MONERO_DATA_DIR}" --shell /usr/sbin/nologin "${MONERO_USER}"
fi

mkdir -p "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"
chown -R "${MONERO_USER}:${MONERO_USER}" "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"

# Create a basic config file if it does not exist
if [[ ! -f "${MONEROD_CONF}" ]]; then
    log "Creating basic monerod config at ${MONEROD_CONF}..."
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
log "Updating systemd unit: /etc/systemd/system/monerod.service..."
install -d /etc/systemd/system

UNIT_TMP="${TMPDIR}/monerod.service"
download_systemd_unit() {
    local out_file="$1"

    if has_cmd gh; then
        if gh api --method GET -H "Accept: application/vnd.github.raw" "repos/${REPO}/contents/utils/systemd/monerod.service?ref=master" --output "$out_file" >/dev/null 2>&1; then
            return 0
        fi
        warn "gh api for systemd unit failed; falling back to curl."
    fi

    net_curl "${SYSTEMD_UNIT_URL}" -o "$out_file"
}

if ! download_systemd_unit "${UNIT_TMP}"; then
    error "failed to download systemd unit (gh/git/curl chain)"
fi

# This always overwrites the target file, whether it exists or not
install -m 0644 "${UNIT_TMP}" /etc/systemd/system/monerod.service

log "Reloading systemd daemon..."
systemctl daemon-reload

log "Enabling monerod service at boot..."
systemctl enable monerod >/dev/null 2>&1 || true

if [[ "$WAS_ACTIVE" -eq 1 ]]; then
    log "Restarting monerod..."
    systemctl restart monerod
else
    log "monerod was not running before."
    log "You can start it now with: systemctl start monerod"
fi

# Show final version
if command -v monerod >/dev/null 2>&1; then
    log "Installed Monero CLI version: $(monerod --version | head -n1 || true)"
fi

log "Monero CLI install/update completed successfully."
