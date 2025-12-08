#!/bin/bash
set -euo pipefail

# Add the official GitHub CLI APT repository 
# and install gh using a deb822 source with the key in
# /etc/apt/keyrings.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
fi

require_cmd dpkg

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    error "/etc/os-release not found. Cannot detect distribution."
fi

OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"

if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" && "$OS_ID" != "devuan" && "$OS_LIKE" != *"debian"* ]]; then
    error "This installer supports Debian/Ubuntu/Devuan (and derivatives with ID_LIKE=debian)."
fi

APT_CMD=""
if command -v apt-get >/dev/null 2>&1; then
    APT_CMD="apt-get"
elif command -v apt >/dev/null 2>&1; then
    APT_CMD="apt"
else
    error "neither 'apt-get' nor 'apt' is available."
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
if [[ -z "$ARCH" ]]; then
    error "could not determine dpkg architecture."
fi

case "$ARCH" in
    amd64|arm64|i386|armhf)
        ;;
    *)
        error "Unsupported architecture '$ARCH'. Supported: amd64, arm64, i386, armhf."
        ;;
esac

log "Updating APT index for base repositories..."
"$APT_CMD" update

if ! dpkg -s apt-transport-https >/dev/null 2>&1; then
    log "Installing apt-transport-https..."
    "$APT_CMD" install -y apt-transport-https
fi

mkdir -p -m 0755 /etc/apt/keyrings
KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
TMPKEY="$(mktemp)"

fetch_key() {
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 5 "https://cli.github.com/packages/githubcli-archive-keyring.gpg" -o "$TMPKEY" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -nv -O "$TMPKEY" "https://cli.github.com/packages/githubcli-archive-keyring.gpg" && return 0
    fi
    return 1
}

log "Fetching GitHub CLI archive key..."
if ! fetch_key; then
    rm -f "$TMPKEY"
    error "failed to download GitHub CLI archive key (curl/wget)."
fi
install -m 0644 "$TMPKEY" "$KEYRING"
rm -f "$TMPKEY"
chmod go+r "$KEYRING"

log "Writing APT deb822 source for GitHub CLI..."
rm -f /etc/apt/sources.list.d/github-cli.list
cat > /etc/apt/sources.list.d/github-cli.sources <<EOF
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: ${ARCH}
Signed-By: ${KEYRING}
EOF

log "Updating APT index (including GitHub CLI repo)..."
"$APT_CMD" update

log "Installing gh..."
"$APT_CMD" install -y gh

log "Done. GitHub CLI repository configured and gh installed."
