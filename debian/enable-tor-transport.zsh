#!/usr/bin/env zsh
set -euo pipefail

# Enable tor+https/tor+http transports for all APT repositories on Debian-based systems.
# Converts existing sources.list and *.list/.sources entries to use tor+https (or tor+http for plain HTTP),
# ensuring apt-transport-tor and tor are installed first. Backups are stored under /etc/apt/tor-transport-backup-<timestamp>.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Missing required command: $1"
    fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
fi

require_cmd awk
require_cmd cp
require_cmd date
require_cmd dpkg
require_cmd ps

APT_CMD=""
if command -v apt-get >/dev/null 2>&1; then
    APT_CMD="apt-get"
elif command -v apt >/dev/null 2>&1; then
    APT_CMD="apt"
else
    error "Neither apt-get nor apt found. This script targets Debian-based systems."
fi

log "Updating APT index and installing tor transport packages..."
"$APT_CMD" update
"$APT_CMD" install -y apt-transport-tor tor

timestamp="$(date +%Y%m%d%H%M%S)"
backup_dir="/etc/apt/tor-transport-backup-${timestamp}"
mkdir -p "$backup_dir"

# Back up sources.list and sources.list.d
if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$backup_dir/"
fi
if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "$backup_dir/"
fi

log "Backups stored in ${backup_dir}"

convert_list_file() {
    local file="$1" tmp
    tmp="$(mktemp)"
    awk '
        /^deb/ || /^deb-src/ {
            if ($0 !~ /tor\+https?/ && $0 ~ /https:\/\//) {
                sub(/https:\/\//, "tor+https://", $0)
            } else if ($0 !~ /tor\+https?/ && $0 ~ /http:\/\//) {
                sub(/http:\/\//, "tor+http://", $0)
            }
        }
        { print }
    ' "$file" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

convert_sources_file() {
    local file="$1" tmp
    tmp="$(mktemp)"
    awk '
        /^URIs:/ {
            if ($0 !~ /tor\+https?/ && $0 ~ /https:\/\//) {
                sub(/https:\/\//, "tor+https://", $0)
            } else if ($0 !~ /tor\+https?/ && $0 ~ /http:\/\//) {
                sub(/http:\/\//, "tor+http://", $0)
            }
        }
        { print }
    ' "$file" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

enable_tor_shepherd() {
    log "Detected GNU Shepherd. Enabling and starting tor via shepherd..."
    herd enable tor || true
    herd start tor || true
}

enable_tor_openrc() {
    log "Detected OpenRC. Enabling and starting tor via OpenRC..."
    rc-update add tor default || true
    rc-service tor restart || rc-service tor start || true
}

enable_tor_runit() {
    log "Detected runit. Enabling and starting tor via runit..."
    if [[ -d /etc/sv/tor && ! -e /etc/service/tor ]]; then
        mkdir -p /etc/service
        ln -s /etc/sv/tor /etc/service/tor || true
    fi
    sv restart tor || sv start tor || true
}

enable_tor_systemd() {
    log "Detected systemd. Enabling and starting tor.service..."
    systemctl daemon-reload || true

    if systemctl list-unit-files | grep -q '^tor\.service'; then
        systemctl enable tor.service
        systemctl restart tor.service
    elif systemctl list-unit-files | grep -q '^tor@default\.service'; then
        systemctl enable tor@default.service
        systemctl restart tor@default.service
    else
        warn "tor systemd service not found; you may need to enable/start it manually."
    fi
}

enable_tor_s6() {
    log "Detected s6-based init. tor is installed, but this script does not manage s6 services automatically."
    log "Please enable and start the 'tor' service using your s6/s6-rc configuration."
}

enable_tor_sysv() {
    log "Detected SysV-style init. Enabling and starting tor via init scripts..."
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
}

enable_and_start_tor() {
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

    case "$init_comm" in
        shepherd)
            if command -v herd >/dev/null 2>&1; then
                enable_tor_shepherd; return
            fi
            ;;
        openrc-init)
            if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
                enable_tor_openrc; return
            fi
            ;;
        runit|runit-init)
            if command -v sv >/dev/null 2>&1; then
                enable_tor_runit; return
            fi
            ;;
        systemd)
            if command -v systemctl >/dev/null 2>&1; then
                enable_tor_systemd; return
            fi
            ;;
        s6-svscan*)
            enable_tor_s6; return
            ;;
    esac

    if command -v herd >/dev/null 2>&1; then
        enable_tor_shepherd; return
    fi
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        enable_tor_openrc; return
    fi
    if command -v sv >/dev/null 2>&1; then
        enable_tor_runit; return
    fi
    if command -v systemctl >/dev/null 2>&1; then
        enable_tor_systemd; return
    fi
    if command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
        enable_tor_s6; return
    fi
    if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/tor ]]; then
        enable_tor_sysv; return
    fi

    warn "could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
    warn "tor is installed, but you must start and enable it manually."
}

if [[ -f /etc/apt/sources.list ]]; then
    log "Converting /etc/apt/sources.list..."
    convert_list_file /etc/apt/sources.list
fi

if [[ -d /etc/apt/sources.list.d ]]; then
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list; do
        log "Converting ${f}..."
        convert_list_file "$f"
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        log "Converting ${f}..."
        convert_sources_file "$f"
    done
    shopt -u nullglob
fi

log "Enabling and starting tor service (if available)..."
enable_and_start_tor

log "Conversion complete. Run 'apt update' to refresh indexes over Tor."
