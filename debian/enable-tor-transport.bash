#!/bin/bash

set -euo pipefail

# Debian enable Tor transport for APT repositories script
# Enable tor+https/tor+http transports for all APT repositories on Debian-based systems.
# Converts existing sources.list and *.list/.sources entries to use tor+https (or tor+http for plain HTTP),
# ensuring apt-transport-tor and tor are installed first. Backups are stored under /etc/apt/tor-transport-backup-<timestamp>.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Simple colors for messages
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
	GREEN="\033[32m"
	YELLOW="\033[33m"
	RED="\033[31m"
	RESET="\033[0m"
else
	GREEN=""
	YELLOW=""
	RED=""
	RESET=""
fi

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() {
	printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2
	exit 1
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "Missing required command: $1"
	fi
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi
}

detect_apt_cmd() {
	if command -v apt-get >/dev/null 2>&1; then
		APT_CMD="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		APT_CMD="apt"
	else
		error "Neither apt-get nor apt found. This script targets Debian-based systems."
	fi
}

install_tor_transport_packages() {
	log "Updating APT index and installing tor transport packages..."
	"$APT_CMD" update
	"$APT_CMD" install -y apt-transport-tor tor
}

backup_sources() {
	local timestamp backup_dir
	timestamp="$(date +%Y%m%d%H%M%S)"
	backup_dir="/etc/apt/tor-transport-backup-${timestamp}"
	mkdir -p "$backup_dir"

	if [[ -f /etc/apt/sources.list ]]; then
		cp -a /etc/apt/sources.list "$backup_dir/"
	fi
	if [[ -d /etc/apt/sources.list.d ]]; then
		cp -a /etc/apt/sources.list.d "$backup_dir/"
	fi

	log "Backups stored in ${backup_dir}"
}

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
    ' "$file" >"$tmp"
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
    ' "$file" >"$tmp"
	install -m 0644 "$tmp" "$file"
	rm -f "$tmp"
}

service_action() {
	local action_desc="$1"
	shift
	if "$@"; then
		return 0
	fi
	warn "Failed to ${action_desc}."
	return 1
}

systemd_unit_exists() {
	systemctl list-unit-files | grep -q "^$1[[:space:]]"
}

ensure_systemd_unit_active() {
	local unit="$1"

	service_action "enable ${unit} with systemd" systemctl enable "$unit" || return 1

	if ! systemctl restart "$unit"; then
		warn "Failed to restart ${unit} with systemd; trying start instead."
		service_action "start ${unit} with systemd" systemctl start "$unit" || return 1
	fi

	if ! systemctl is-active --quiet "$unit"; then
		warn "systemd reports ${unit} is not active after start/restart."
		return 1
	fi

	log "Verified ${unit} is active."
}

enable_tor_shepherd() {
	log "Detected GNU Shepherd. Enabling and starting tor via shepherd..."
	service_action "enable tor with shepherd" herd enable tor || return 1
	service_action "start tor with shepherd" herd start tor
}

enable_tor_openrc() {
	log "Detected OpenRC. Enabling and starting tor via OpenRC..."
	service_action "enable tor with OpenRC" rc-update add tor default || return 1

	if rc-service tor restart; then
		return 0
	fi
	warn "Failed to restart tor with OpenRC; trying start instead."
	service_action "start tor with OpenRC" rc-service tor start
}

enable_tor_runit() {
	log "Detected runit. Enabling and starting tor via runit..."
	if [[ -d /etc/sv/tor && ! -e /etc/service/tor ]]; then
		mkdir -p /etc/service
		service_action "link tor into runit service directory" ln -s /etc/sv/tor /etc/service/tor || return 1
	fi

	if sv restart tor; then
		return 0
	fi
	warn "Failed to restart tor with runit; trying start instead."
	service_action "start tor with runit" sv start tor
}

enable_tor_systemd() {
	log "Detected systemd. Enabling and starting tor service..."
	if ! systemctl daemon-reload; then
		warn "Failed to reload systemd daemon. Continuing with service management."
	fi

	if systemd_unit_exists 'tor.service'; then
		ensure_systemd_unit_active 'tor.service'
	elif systemd_unit_exists 'tor@default.service'; then
		ensure_systemd_unit_active 'tor@default.service'
	else
		warn "tor systemd service not found; cannot verify active state."
		return 1
	fi
}

enable_tor_s6() {
	log "Detected s6-based init. tor is installed, but this script does not manage s6 services automatically."
	log "Please enable and start the 'tor' service using your s6/s6-rc configuration."
}

enable_tor_sysv() {
	local failed=0

	log "Detected SysV-style init. Enabling and starting tor via init scripts..."
	if command -v update-rc.d >/dev/null 2>&1; then
		service_action "enable tor with update-rc.d" update-rc.d tor defaults || failed=1
	elif command -v chkconfig >/dev/null 2>&1; then
		service_action "enable tor with chkconfig" chkconfig tor on || failed=1
	else
		warn "No SysV enable helper (update-rc.d/chkconfig) found for tor."
		failed=1
	fi

	if command -v service >/dev/null 2>&1; then
		if ! service tor restart; then
			warn "Failed to restart tor via service; trying start instead."
			service_action "start tor via service" service tor start || failed=1
		fi
	elif [[ -x /etc/init.d/tor ]]; then
		if ! /etc/init.d/tor restart; then
			warn "Failed to restart tor via /etc/init.d/tor; trying start instead."
			service_action "start tor via /etc/init.d/tor" /etc/init.d/tor start || failed=1
		fi
	else
		warn "No SysV tor service script found."
		failed=1
	fi

	return "$failed"
}

enable_and_start_tor() {
	local init_comm
	init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

	case "$init_comm" in
	shepherd)
		if command -v herd >/dev/null 2>&1; then
			enable_tor_shepherd
			return
		fi
		;;
	openrc-init)
		if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
			enable_tor_openrc
			return
		fi
		;;
	runit | runit-init)
		if command -v sv >/dev/null 2>&1; then
			enable_tor_runit
			return
		fi
		;;
	systemd)
		if command -v systemctl >/dev/null 2>&1; then
			enable_tor_systemd
			return
		fi
		;;
	s6-svscan*)
		enable_tor_s6
		return
		;;
	esac

	if command -v herd >/dev/null 2>&1; then
		enable_tor_shepherd
		return
	fi
	if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
		enable_tor_openrc
		return
	fi
	if command -v sv >/dev/null 2>&1; then
		enable_tor_runit
		return
	fi
	if command -v systemctl >/dev/null 2>&1; then
		enable_tor_systemd
		return
	fi
	if command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
		enable_tor_s6
		return
	fi
	if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/tor ]]; then
		enable_tor_sysv
		return
	fi

	warn "could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
	warn "tor is installed, but you must start and enable it manually."
	return 1
}

convert_sources_to_tor_transport() {
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
}

check_prereqs() {
	require_root
	require_cmd awk
	require_cmd cp
	require_cmd date
	require_cmd dpkg
	require_cmd ps
	require_cmd install
}

run_enable_tor_transport() {
	detect_apt_cmd
	install_tor_transport_packages
	backup_sources
	convert_sources_to_tor_transport

	log "Enabling and starting tor service..."
	enable_and_start_tor
	log "Conversion complete. Run 'apt update' to refresh indexes over Tor."
}

main() {
	check_prereqs
	run_enable_tor_transport
}

main "$@"
