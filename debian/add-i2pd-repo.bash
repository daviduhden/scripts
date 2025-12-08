#!/bin/bash
set -euo pipefail  # exit on error, unset variable, or failing pipeline

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

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

DIST=""
RELEASE=""
REPO_RELEASE=""
ARCH_FILTER=""
APT_CMD=""

# Helper to ensure required commands exist
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed or not in PATH."
    fi
}

# Ensure we run as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
fi

require_cmd curl
require_cmd dpkg
require_cmd ps

# Wrapper for curl
net_curl() {
    curl -fLsS --retry 5 "$@"
}

# Detect apt/apt-get
if command -v apt-get >/dev/null 2>&1; then
    APT_CMD="apt-get"
elif command -v apt >/dev/null 2>&1; then
    APT_CMD="apt"
else
    error "neither 'apt-get' nor 'apt' is available. This script supports only Debian-like/Ubuntu-like systems."
fi

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

ensure_base_dependencies() {
    log "Updating APT index for base repositories..."
    "$APT_CMD" update

    if ! command -v gpg >/dev/null 2>&1; then
        log "Installing gnupg (for gpg)..."
        "$APT_CMD" install -y gnupg
    fi

    if ! dpkg -s apt-transport-https >/dev/null 2>&1; then
        log "Installing apt-transport-https..."
        "$APT_CMD" install -y apt-transport-https
    fi
}

enable_i2pd_shepherd() {
    log "Detected GNU Shepherd. Enabling and starting i2pd via shepherd..."
    herd enable i2pd || true
    herd start i2pd || true
}

enable_i2pd_openrc() {
    log "Detected OpenRC. Enabling and starting i2pd via OpenRC..."
    rc-update add i2pd default || true
    rc-service i2pd restart || rc-service i2pd start || true
}

enable_i2pd_runit() {
    log "Detected runit. Enabling and starting i2pd via runit..."
    if [[ -d /etc/sv/i2pd && ! -e /etc/service/i2pd ]]; then
        mkdir -p /etc/service
        ln -s /etc/sv/i2pd /etc/service/i2pd || true
    fi
    sv restart i2pd || sv start i2pd || true
}

enable_i2pd_systemd() {
    log "Detected systemd. Enabling and starting i2pd.service..."
    systemctl daemon-reload || true

    if systemctl list-unit-files | grep -q '^i2pd\.service[[:space:]]'; then
        systemctl enable i2pd.service
        systemctl restart i2pd.service
    else
        warn "i2pd systemd service not found; you may need to enable/start it manually."
    fi
}

enable_i2pd_s6() {
    log "Detected s6-based init. i2pd is installed, but this script does not manage s6 services automatically."
    log "Please enable and start the 'i2pd' service using your s6/s6-rc configuration."
}

enable_i2pd_sysv() {
    log "Detected SysV-style init. Enabling and starting i2pd via init scripts..."
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
}

enable_and_start_i2pd() {
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

    case "$init_comm" in
        shepherd)
            if command -v herd >/dev/null 2>&1; then
                enable_i2pd_shepherd; return
            fi
            ;;
        openrc-init)
            if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
                enable_i2pd_openrc; return
            fi
            ;;
        runit|runit-init)
            if command -v sv >/dev/null 2>&1; then
                enable_i2pd_runit; return
            fi
            ;;
        systemd)
            if command -v systemctl >/dev/null 2>&1; then
                enable_i2pd_systemd; return
            fi
            ;;
        s6-svscan*)
            enable_i2pd_s6; return
            ;;
    esac

    if command -v herd >/dev/null 2>&1; then
        enable_i2pd_shepherd; return
    fi
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        enable_i2pd_openrc; return
    fi
    if command -v sv >/dev/null 2>&1; then
        enable_i2pd_runit; return
    fi
    if command -v systemctl >/dev/null 2>&1; then
        enable_i2pd_systemd; return
    fi
    if command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
        enable_i2pd_s6; return
    fi
    if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/i2pd ]]; then
        enable_i2pd_sysv; return
    fi

    warn "could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
    warn "i2pd is installed, but you must start and enable it manually."
}

get_release
detect_arch_filter
ensure_base_dependencies

# Compute repo release codename (Raspbian uses <release>-rpi)
REPO_RELEASE="$RELEASE"
if [[ "$DIST" == "raspbian" ]]; then
    REPO_RELEASE="${RELEASE}-rpi"
fi

log "Detected distribution: ${DIST}"
log "Detected release codename: ${RELEASE}"
log "Using repo release codename: ${REPO_RELEASE}"
log "Using native APT architecture: ${ARCH_FILTER}"

log "Importing signing key..."
install -d -m 0755 /usr/share/keyrings
net_curl https://repo.i2pd.xyz/r4sas.gpg | gpg --dearmor -o /usr/share/keyrings/purplei2p.gpg

log "Writing APT deb822 sources file for Purple I2P..."
rm -f /etc/apt/sources.list.d/purplei2p.list
cat > /etc/apt/sources.list.d/purplei2p.sources <<EOF
Types: deb
URIs: https://repo.i2pd.xyz/${DIST}
Suites: ${REPO_RELEASE}
Components: main
Architectures: ${ARCH_FILTER}
Signed-By: /usr/share/keyrings/purplei2p.gpg
EOF

# Optional deb-src entry (commented out). Uncomment to enable source packages.
cat >> /etc/apt/sources.list.d/purplei2p.sources <<'EOF'
#
# Types: deb-src
# URIs: https://repo.i2pd.xyz/${DIST}
# Suites: ${REPO_RELEASE}
# Components: main
# Architectures: ${ARCH_FILTER}
# Signed-By: /usr/share/keyrings/purplei2p.gpg
EOF

log "Updating APT index..."
"$APT_CMD" update

log "Installing i2pd..."
"$APT_CMD" install -y i2pd

log "Enabling and starting i2pd service..."
enable_and_start_i2pd

log "Done. i2pd should now be installed and (where supported) enabled and running."
