#!/bin/bash
set -euo pipefail

# Add the official Lynis (CISOfy) APT repository
# and install lynis using a deb822 source with the key in
# /etc/apt/keyrings. Supports Debian/Devuan (bookworm or newer)
# and other Debian-based systems with apt.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b 🟦 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
fi

require_cmd dpkg
require_cmd gpg

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    error "/etc/os-release not found. Cannot detect distribution."
fi

OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"
RELEASE=""

if [[ "$OS_ID" != "debian" && "$OS_ID" != "devuan" && "$OS_ID" != "raspbian" && "$OS_LIKE" != *"debian"* ]]; then
    error "This installer supports Debian/Devuan derivatives (bookworm or newer)."
fi

if [[ -n "${DEBIAN_CODENAME:-}" ]]; then
    RELEASE="$DEBIAN_CODENAME"
elif [[ -n "${VERSION_CODENAME:-}" ]]; then
    RELEASE="$VERSION_CODENAME"
else
    error "could not detect distribution codename (DEBIAN_CODENAME/VERSION_CODENAME)."
fi

if [[ "$OS_ID" == "devuan" ]]; then
    case "$RELEASE" in
        daedalus)
            RELEASE="bookworm"
            ;;
        excalibur)
            RELEASE="trixie"
            ;;
        *)
            error "unsupported Devuan codename '$RELEASE'. Supported: daedalus (bookworm) or excalibur (trixie)."
            ;;
    esac
fi

case "$RELEASE" in
    bookworm|trixie|sid)
        ;;
    *)
        error "unsupported release '$RELEASE'. Supported: bookworm, trixie, sid (or Devuan daedalus/excalibur)."
        ;;
esac

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

log "Updating APT index for base repositories..."
"$APT_CMD" update

if ! dpkg -s apt-transport-https >/dev/null 2>&1; then
    log "Installing apt-transport-https..."
    "$APT_CMD" install -y apt-transport-https
fi

mkdir -p -m 0755 /etc/apt/keyrings
KEYRING="/etc/apt/keyrings/cisofy-lynis-archive-keyring.gpg"
TMPKEY="$(mktemp)"
TMPDEARMOR="$(mktemp)"

fetch_key() {
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 5 "https://packages.cisofy.com/keys/cisofy-software-public.key" -o "$TMPKEY" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -nv -O "$TMPKEY" "https://packages.cisofy.com/keys/cisofy-software-public.key" && return 0
    fi
    return 1
}

log "Fetching Lynis archive key..."
if ! fetch_key; then
    rm -f "$TMPKEY" "$TMPDEARMOR"
    error "failed to download Lynis archive key (curl/wget)."
fi

log "Installing key to ${KEYRING} via gpg --dearmor..."
if ! gpg --dearmor "$TMPKEY" > "$TMPDEARMOR"; then
    rm -f "$TMPKEY" "$TMPDEARMOR"
    error "gpg --dearmor failed for downloaded key."
fi
install -m 0644 "$TMPDEARMOR" "$KEYRING"
rm -f "$TMPKEY" "$TMPDEARMOR"
chmod go+r "$KEYRING"

log "Writing APT deb822 source for Lynis..."
rm -f /etc/apt/sources.list.d/cisofy-lynis.list
cat > /etc/apt/sources.list.d/cisofy-lynis.sources <<EOF
Types: deb
URIs: https://packages.cisofy.com/community/lynis/deb/
Suites: stable
Components: main
Architectures: ${ARCH}
Signed-By: ${KEYRING}
EOF

log "Updating APT index (including Lynis repo)..."
"$APT_CMD" update

log "Installing lynis..."
"$APT_CMD" install -y lynis

log "Done. Lynis repository configured and lynis installed."
