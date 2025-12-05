#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

#
# This script adds the Tor Project APT repository,
# installs tor automatically and enables/starts the service
# on systemd, SysV-init, OpenRC, runit, sinit (via SysV scripts),
# s6 (manual instructions) and GNU Shepherd.
#
# It is intended for Debian-based distributions (Debian, Ubuntu, Devuan, etc.)
# It supports only amd64 and arm64 architectures (as per repository).
#
# Supported (based on current published repositories):
#   Debian: buster, bullseye, bookworm, trixie
#   Ubuntu: bionic, focal, jammy, kinetic
# Devuan:
#   - daedalus  -> Debian bookworm
#   - excalibur -> Debian trixie
#
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

OS_ID=""
OS_CODENAME=""
SUITE_CODENAME=""
ARCH_FILTER=""
APT_CMD=""
TORSOCKS=""

error() {
    echo "Error: $*" >&2
    exit 1
}

# Helper to ensure required commands exist
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

# Ensure we run as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

require_cmd curl
require_cmd dpkg
require_cmd ps

# Detect torsocks (for all network operations)
if command -v torsocks >/dev/null 2>&1; then
    TORSOCKS="torsocks"
    echo "torsocks detected. Network operations will be wrapped with torsocks."
else
    TORSOCKS=""
fi

# Wrapper for curl with optional torsocks
net_curl() {
    if [[ -n "$TORSOCKS" ]]; then
        "$TORSOCKS" curl "$@"
    else
        curl "$@"
    fi
}

# Detect apt/apt-get
if command -v apt-get >/dev/null 2>&1; then
    APT_CMD="apt-get"
elif command -v apt >/dev/null 2>&1; then
    APT_CMD="apt"
else
    error "neither 'apt-get' nor 'apt' is available. This script supports only Debian-like/Ubuntu-like systems."
fi

# Wrapper for apt commands with optional torsocks
net_apt() {
    if [[ -n "$TORSOCKS" ]]; then
        "$TORSOCKS" "$APT_CMD" "$@"
    else
        "$APT_CMD" "$@"
    fi
}

# Load system release information
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    error "/etc/os-release not found. Cannot detect distribution."
fi

OS_ID="${ID:-}"

# Basic sanity: ensure it's Debian-based
if [[ "${ID_LIKE:-}" != *"debian"* && "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" && "$OS_ID" != "devuan" ]]; then
    error "this script is intended for Debian-based systems (Debian/Ubuntu/Devuan and derivatives)."
fi

get_suite_codename() {
    # Detect OS codename
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
        OS_CODENAME="${VERSION_CODENAME}"
    elif [[ -n "${UBUNTU_CODENAME:-}" ]]; then
        OS_CODENAME="${UBUNTU_CODENAME}"
    elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
        OS_CODENAME="${DEBIAN_CODENAME}"
    else
        error "could not detect distribution codename (VERSION_CODENAME/UBUNTU_CODENAME/DEBIAN_CODENAME missing)."
    fi

    case "$OS_ID" in
        devuan)
            case "$OS_CODENAME" in
                daedalus)
                    SUITE_CODENAME="bookworm"
                    ;;
                excalibur)
                    SUITE_CODENAME="trixie"
                    ;;
                *)
                    error "unsupported Devuan codename '$OS_CODENAME'. Supported: daedalus (-> bookworm), excalibur (-> trixie)."
                    ;;
            esac
            ;;
        *)
            SUITE_CODENAME="$OS_CODENAME"
            ;;
    esac
}

detect_architecture() {
    local native
    native="$(dpkg --print-architecture 2>/dev/null || true)"

    if [[ -z "$native" ]]; then
        error "could not detect native APT architecture."
    fi

    case "$native" in
        amd64|arm64)
            ARCH_FILTER="$native"
            ;;
        *)
            error "unsupported native architecture '$native'. Tor Project APT repository supports only amd64 and arm64."
            ;;
    esac
}

ensure_base_dependencies() {
    echo "Updating APT index for base repositories..."
    net_apt update

    # Ensure gnupg (for gpg) is installed
    if ! command -v gpg >/dev/null 2>&1; then
        echo "Installing gnupg (for gpg)..."
        net_apt install -y gnupg
    fi

    # Ensure apt-transport-https if package exists (older recommendations)
    if ! dpkg -s apt-transport-https >/dev/null 2>&1; then
        echo "Trying to install apt-transport-https (optional)..."
        if ! net_apt install -y apt-transport-https; then
            echo "Warning: could not install apt-transport-https. Continuing; modern APT usually has HTTPS support built-in."
        fi
    fi
}

enable_and_start_tor() {
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

    # GNU Shepherd
    if [[ "$init_comm" == "shepherd" ]] || command -v herd >/dev/null 2>&1; then
        echo "Detected GNU Shepherd. Enabling and starting tor via shepherd..."
        herd enable tor || true
        herd start tor || true
        return
    fi

    # OpenRC
    if [[ "$init_comm" == "openrc-init" ]] || command -v rc-update >/dev/null 2>&1; then
        if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
            echo "Detected OpenRC. Enabling and starting tor via OpenRC..."
            rc-update add tor default || true
            rc-service tor restart || rc-service tor start || true
            return
        fi
    fi

    # runit
    if [[ "$init_comm" == "runit" ]] || [[ "$init_comm" == "runit-init" ]] || command -v sv >/dev/null 2>&1; then
        if command -v sv >/dev/null 2>&1; then
            echo "Detected runit. Enabling and starting tor via runit..."
            if [[ -d /etc/sv/tor && ! -e /etc/service/tor ]]; then
                mkdir -p /etc/service
                ln -s /etc/sv/tor /etc/service/tor || true
            fi
            sv restart tor || sv start tor || true
            return
        fi
    fi

    # systemd
    if [[ "$init_comm" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        echo "Detected systemd. Enabling and starting tor.service..."
        systemctl daemon-reload || true

        if systemctl list-unit-files | grep -q '^tor\.service'; then
            systemctl enable tor.service
            systemctl restart tor.service
        elif systemctl list-unit-files | grep -q '^tor@default\.service'; then
            systemctl enable tor@default.service
            systemctl restart tor@default.service
        else
            echo "Warning: tor systemd service not found; you may need to enable/start it manually."
        fi
        return
    fi

    # s6
    if [[ "$init_comm" == s6-svscan* ]] || command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
        echo "Detected s6-based init. tor is installed, but this script does not manage s6 services automatically."
        echo "Please enable and start the 'tor' service using your s6/s6-rc configuration."
        return
    fi

    # SysV-style (covers classic sysvinit and sinit using /etc/init.d)
    if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/tor ]]; then
        echo "Detected SysV-style init. Enabling and starting tor via init scripts..."
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d tor defaults || true
        elif command -v chkconfig >/dev/null 2>&1; then
            chkconfig tor on || true
        fi

        if command -v service >/dev/null 2>&1; then
            service tor restart || service tor start || true
        elif [[ -x /etc/init.d/tor ]]; then
            /etc/init.d/tor restart || /etc/init.d/tor start || true
        fi
        return
    fi

    echo "Warning: could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
    echo "tor is installed, but you must start and enable it manually."
}

get_suite_codename
detect_architecture
ensure_base_dependencies

echo "Detected OS ID: ${OS_ID}"
echo "Detected OS codename: ${OS_CODENAME}"
echo "Using Tor repo suite codename: ${SUITE_CODENAME}"
echo "Using native APT architecture: ${ARCH_FILTER}"

echo "Importing Tor Project signing key..."
install -d -m 0755 /usr/share/keyrings
net_curl -fsSL "https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc" \
    | gpg --dearmor -o /usr/share/keyrings/deb.torproject.org-keyring.gpg

echo "Writing APT sources file for Tor..."
cat > /etc/apt/sources.list.d/tor.list <<EOF
deb     [arch=${ARCH_FILTER} signed-by=/usr/share/keyrings/deb.torproject.org-keyring.gpg] https://deb.torproject.org/torproject.org ${SUITE_CODENAME} main
deb-src [arch=${ARCH_FILTER} signed-by=/usr/share/keyrings/deb.torproject.org-keyring.gpg] https://deb.torproject.org/torproject.org ${SUITE_CODENAME} main
# For experimental or nightly packages, see:
#   https://support.torproject.org/debian/tor-deb-repo/
EOF

echo "Updating APT index (including Tor repository)..."
net_apt update

echo "Installing tor and deb.torproject.org-keyring..."
net_apt install -y tor deb.torproject.org-keyring

echo "Enabling and starting tor service..."
enable_and_start_tor

echo "Done. Tor should now be installed and (where supported) enabled and running."
