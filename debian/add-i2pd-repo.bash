#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

#
# This script adds the Purple I2P APT repository,
# installs i2pd automatically and enables/starts the service
# on systemd, SysV-init, OpenRC, runit, sinit (via SysV scripts),
# s6 (manual instructions) and GNU Shepherd.
#
# It is intended for Debian-based distributions (Debian, Ubuntu, Devuan, etc.).
# It supports only amd64, i386, arm64 and armhf architectures (as per repository).
#
# Supported (based on current published repos):
#   Debian:   buster, bullseye, bookworm, trixie, sid
#   Raspbian: buster, bullseye, bookworm, trixie  (repo codename: <release>-rpi, e.g. trixie-rpi)
#   Ubuntu:   focal, jammy, noble, plucky, questing, oracular
# Devuan:
#   - daedalus  -> Debian bookworm
#   - excalibur -> Debian trixie
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DIST=""
RELEASE=""
REPO_RELEASE=""
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
require_cmd gpg
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

DIST="${ID:-}"

get_release() {
    case "$ID" in
        ##################
        # Devuan support #
        ##################
        devuan)
            # Devuan uses its own codenames; map them to Debian codenames.
            #   Devuan 5 "daedalus"   -> Debian 12 "bookworm"
            #   Devuan 6 "excalibur"  -> Debian 13 "trixie"
            if [[ -z "${VERSION_CODENAME:-}" ]]; then
                error "could not find VERSION_CODENAME in /etc/os-release on Devuan."
            fi

            case "$VERSION_CODENAME" in
                *daedalus*)
                    RELEASE="bookworm"
                    ;;
                *excalibur*)
                    RELEASE="trixie"
                    ;;
                *chimaera*)
                    error "Devuan chimaera (Debian 11) is not supported. Need Devuan daedalus or newer."
                    ;;
                *)
                    error "unsupported Devuan version '${VERSION_CODENAME}'. Supported: daedalus and excalibur."
                    ;;
            esac

            # Use Debian repo layout for Devuan (packages are Debian-compatible).
            DIST="debian"
            ;;
        ############################
        # Native Debian / Raspbian #
        ############################
        debian|raspbian)
            if [[ -n "${DEBIAN_CODENAME:-}" ]]; then
                RELEASE="$DEBIAN_CODENAME"
            elif [[ -n "${VERSION_CODENAME:-}" ]]; then
                RELEASE="$VERSION_CODENAME"
            else
                error "couldn't find DEBIAN_CODENAME or VERSION_CODENAME in /etc/os-release."
            fi
            # DIST remains actual ID: debian or raspbian
            DIST="$ID"
            ;;
        #################
        # Native Ubuntu #
        #################
        ubuntu)
            if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
                RELEASE="$UBUNTU_CODENAME"
            elif [[ -n "${VERSION_CODENAME:-}" ]]; then
                RELEASE="$VERSION_CODENAME"
            else
                error "couldn't find UBUNTU_CODENAME or VERSION_CODENAME in /etc/os-release."
            fi
            DIST="ubuntu"
            ;;
        ###################################################
        # Other Debian-/Ubuntu-like systems (derivatives) #
        ###################################################
        *)
            if [[ -z "${ID_LIKE:-}" ]]; then
                error "your system is not supported. Only Debian-like and Ubuntu-like systems are supported."
            fi

            # Ubuntu-like derivative (e.g. Linux Mint, Pop!_OS, etc.)
            if [[ "$ID_LIKE" == *"ubuntu"* ]]; then
                DIST="ubuntu"
                if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
                    RELEASE="$UBUNTU_CODENAME"
                elif [[ -n "${VERSION_CODENAME:-}" ]]; then
                    RELEASE="$VERSION_CODENAME"
                else
                    error "couldn't find UBUNTU_CODENAME or VERSION_CODENAME for Ubuntu-like system."
                fi

            # Debian-like derivative (generic)
            elif [[ "$ID_LIKE" == *"debian"* ]]; then
                DIST="debian"
                if [[ -n "${DEBIAN_CODENAME:-}" ]]; then
                    RELEASE="$DEBIAN_CODENAME"
                elif [[ -n "${VERSION_CODENAME:-}" ]]; then
                    RELEASE="$VERSION_CODENAME"
                else
                    error "couldn't find DEBIAN_CODENAME or VERSION_CODENAME for Debian-like system."
                fi

            else
                error "your system is not supported. Only Debian-like and Ubuntu-like systems are supported."
            fi
            ;;
    esac

    if [[ -z "$RELEASE" ]]; then
        error "couldn't detect a supported system release."
    fi

    # Enforce supported releases based on published repos
    case "$DIST" in
        debian|raspbian)
            case "$RELEASE" in
                buster|bullseye|bookworm|trixie|sid)
                    ;;
                *)
                    error "unsupported ${DIST} release codename '$RELEASE'. Supported: buster, bullseye, bookworm, trixie, sid."
                    ;;
            esac
            ;;
        ubuntu)
            case "$RELEASE" in
                focal|jammy|noble|plucky|questing|oracular)
                    ;;
                *)
                    error "unsupported ubuntu release codename '$RELEASE'. Supported: focal, jammy, noble, plucky, questing, oracular."
                    ;;
            esac
            ;;
        *)
            error "internal error: unsupported DIST '$DIST'."
            ;;
    esac
}

detect_arch_filter() {
    # Native architecture only
    local native
    native="$(dpkg --print-architecture 2>/dev/null || true)"

    if [[ -z "$native" ]]; then
        error "could not detect native APT architecture."
    fi

    case "$native" in
        amd64|i386|arm64|armhf)
            ARCH_FILTER="$native"
            ;;
        *)
            error "unsupported native architecture '$native'. This repo supports only amd64, i386, arm64, armhf."
            ;;
    esac
}

enable_and_start_i2pd() {
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

    # GNU Shepherd
    if [[ "$init_comm" == "shepherd" ]] || command -v herd >/dev/null 2>&1; then
        echo "Detected GNU Shepherd. Enabling and starting i2pd via shepherd..."
        herd enable i2pd || true
        herd start i2pd || true
        return
    fi

    # OpenRC
    if [[ "$init_comm" == "openrc-init" ]] || command -v rc-update >/dev/null 2>&1; then
        if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
            echo "Detected OpenRC. Enabling and starting i2pd via OpenRC..."
            rc-update add i2pd default || true
            rc-service i2pd restart || rc-service i2pd start || true
            return
        fi
    fi

    # runit
    if [[ "$init_comm" == "runit" ]] || [[ "$init_comm" == "runit-init" ]] || command -v sv >/dev/null 2>&1; then
        if command -v sv >/dev/null 2>&1; then
            echo "Detected runit. Enabling and starting i2pd via runit..."
            if [[ -d /etc/sv/i2pd && ! -e /etc/service/i2pd ]]; then
                mkdir -p /etc/service
                ln -s /etc/sv/i2pd /etc/service/i2pd || true
            fi
            sv restart i2pd || sv start i2pd || true
            return
        fi
    fi

    # systemd
    if [[ "$init_comm" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        echo "Detected systemd. Enabling and starting i2pd.service..."
        systemctl daemon-reload || true
        systemctl enable i2pd.service
        systemctl restart i2pd.service
        return
    fi

    # s6
    if [[ "$init_comm" == s6-svscan* ]] || command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
        echo "Detected s6-based init. i2pd is installed, but this script does not manage s6 services automatically."
        echo "Please enable and start the 'i2pd' service using your s6/s6-rc configuration."
        return
    fi

    # SysV-style (covers classic sysvinit and sinit using /etc/init.d)
    if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/i2pd ]]; then
        echo "Detected SysV-style init. Enabling and starting i2pd via init scripts..."
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d i2pd defaults || true
        elif command -v chkconfig >/dev/null 2>&1; then
            chkconfig i2pd on || true
        fi

        if command -v service >/dev/null 2>&1; then
            service i2pd restart || service i2pd start || true
        elif [[ -x /etc/init.d/i2pd ]]; then
            /etc/init.d/i2pd restart || /etc/init.d/i2pd start || true
        fi
        return
    fi

    echo "Warning: could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
    echo "i2pd is installed, but you must start and enable it manually."
}

get_release
detect_arch_filter

# Compute repo release codename (Raspbian uses <release>-rpi)
REPO_RELEASE="$RELEASE"
if [[ "$DIST" == "raspbian" ]]; then
    REPO_RELEASE="${RELEASE}-rpi"
fi

echo "Detected distribution: ${DIST}"
echo "Detected release codename: ${RELEASE}"
echo "Using repo release codename: ${REPO_RELEASE}"
echo "Using native APT architecture: ${ARCH_FILTER}"

echo "Importing signing key..."
install -d -m 0755 /usr/share/keyrings
net_curl -fsSL https://repo.i2pd.xyz/r4sas.gpg | gpg --dearmor -o /usr/share/keyrings/purplei2p.gpg

echo "Adding APT repository..."
cat > /etc/apt/sources.list.d/purplei2p.list <<EOF
deb [arch=${ARCH_FILTER} signed-by=/usr/share/keyrings/purplei2p.gpg] https://repo.i2pd.xyz/${DIST} ${REPO_RELEASE} main
# deb-src [arch=${ARCH_FILTER} signed-by=/usr/share/keyrings/purplei2p.gpg] https://repo.i2pd.xyz/${DIST} ${REPO_RELEASE} main
EOF

echo "Updating APT index..."
net_apt update

echo "Installing i2pd..."
net_apt install -y i2pd

echo "Enabling and starting i2pd service..."
enable_and_start_i2pd

echo "Done. i2pd should now be installed and (where supported) enabled and running."
