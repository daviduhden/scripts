#!/bin/bash

set -euo pipefail

# Debian add Purple I2P APT repository script
# This script adds the Purple I2P APT repository,
# installs i2pd automatically and enables/starts the service
# on systemd, SysV-init, OpenRC, runit, sinit (via SysV scripts),
# s6 (manual instructions) and GNU Shepherd.
#
# It is intended for Debian-based distributions (Debian/Devuan and derivatives).
# It supports only amd64, i386, arm64 and armhf architectures (as per repository).
#
# Supported (based on current published repos):
#   Debian/Raspbian: bookworm, trixie, sid (raspbian uses <release>-rpi)
#   Ubuntu: jammy, noble
#   Devuan:
#     - daedalus  -> Debian bookworm
#     - excalibur -> Debian trixie
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

# Wrapper for curl
net_curl() {
	curl -fLsS --retry 5 "$@"
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
		error "neither 'apt-get' nor 'apt' is available. This script supports only Debian-like/Ubuntu-like systems."
	fi
}

load_os_release() {
	if [[ -r /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
	else
		error "/etc/os-release not found. Cannot detect distribution."
	fi
}

normalize_dist() {
	DIST="${ID:-}"
	if [[ $DIST != "debian" && $DIST != "devuan" && $DIST != "raspbian" && $DIST != "ubuntu" && ${ID_LIKE:-} == *"ubuntu"* ]]; then
		DIST="ubuntu"
	fi
}

validate_supported_base() {
	if [[ ${ID_LIKE:-} != *"debian"* && ${ID_LIKE:-} != *"ubuntu"* && $DIST != "debian" && $DIST != "devuan" && $DIST != "raspbian" && $DIST != "ubuntu" ]]; then
		error "This installer supports Debian/Devuan/Ubuntu-based systems (bookworm or newer)."
	fi
}

compute_repo_release() {
	REPO_RELEASE="$RELEASE"
	if [[ $DIST == "raspbian" ]]; then
		REPO_RELEASE="${RELEASE}-rpi"
	fi
}

log_detected_platform() {
	log "Detected distribution: ${DIST}"
	log "Detected release codename: ${RELEASE}"
	log "Using repo release codename: ${REPO_RELEASE}"
	log "Using native APT architecture: ${ARCH_FILTER}"
}

install_repo_key() {
	log "Importing signing key..."
	install -d -m 0755 /usr/share/keyrings
	net_curl https://repo.i2pd.xyz/r4sas.gpg | gpg --dearmor -o /usr/share/keyrings/purplei2p.gpg
}

write_i2pd_sources() {
	log "Writing APT deb822 sources file for Purple I2P..."
	rm -f /etc/apt/sources.list.d/purplei2p.list
	cat >/etc/apt/sources.list.d/purplei2p.sources <<EOF
Types: deb
URIs: https://repo.i2pd.xyz/${DIST}
Suites: ${REPO_RELEASE}
Components: main
Architectures: ${ARCH_FILTER}
Signed-By: /usr/share/keyrings/purplei2p.gpg
EOF

	cat >>/etc/apt/sources.list.d/purplei2p.sources <<EOF

Enabled: no
Types: deb-src
URIs: https://repo.i2pd.xyz/${DIST}
Suites: ${REPO_RELEASE}
Components: main
Architectures: ${ARCH_FILTER}
Signed-By: /usr/share/keyrings/purplei2p.gpg
EOF
}

install_i2pd() {
	log "Updating APT index..."
	"$APT_CMD" update

	log "Installing i2pd..."
	"$APT_CMD" install -y i2pd
}

run_setup() {
	get_release
	detect_arch_filter
	ensure_base_dependencies
	compute_repo_release
	log_detected_platform
	install_repo_key
	write_i2pd_sources
	install_i2pd

	log "Enabling and starting i2pd service..."
	enable_and_start_i2pd
	log "Done. i2pd should now be installed and (where supported) enabled and running."
}

main() {
	require_root
	require_cmd curl
	require_cmd dpkg
	require_cmd ps
	detect_apt_cmd
	load_os_release
	normalize_dist
	validate_supported_base
	run_setup
}

get_release() {
	case "$ID" in
	##################
	# Devuan support #
	##################
	devuan)
		# Devuan uses its own codenames; map them to Debian codenames.
		#   Devuan 5 "daedalus"   -> Debian 12 "bookworm"
		#   Devuan 6 "excalibur"  -> Debian 13 "trixie"
		if [[ -z ${VERSION_CODENAME:-} ]]; then
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
	debian | raspbian)
		if [[ -n ${DEBIAN_CODENAME:-} ]]; then
			RELEASE="$DEBIAN_CODENAME"
		elif [[ -n ${VERSION_CODENAME:-} ]]; then
			RELEASE="$VERSION_CODENAME"
		else
			error "couldn't find DEBIAN_CODENAME or VERSION_CODENAME in /etc/os-release."
		fi
		# DIST remains actual ID: debian or raspbian
		DIST="$ID"
		;;
	############################
	# Ubuntu and derivatives   #
	############################
	ubuntu)
		if [[ -n ${UBUNTU_CODENAME:-} ]]; then
			RELEASE="$UBUNTU_CODENAME"
		elif [[ -n ${VERSION_CODENAME:-} ]]; then
			RELEASE="$VERSION_CODENAME"
		else
			error "couldn't find UBUNTU_CODENAME or VERSION_CODENAME in /etc/os-release."
		fi
		DIST="ubuntu"
		;;
	###################################################
	# Other Debian-like systems (derivatives)         #
	###################################################
	*)
		if [[ -z ${ID_LIKE:-} || ($ID_LIKE != *"debian"* && $ID_LIKE != *"ubuntu"*) ]]; then
			error "your system is not supported. Only Debian/Ubuntu-like systems are supported."
		fi

		if [[ $ID_LIKE == *"ubuntu"* ]]; then
			DIST="ubuntu"
			if [[ -n ${UBUNTU_CODENAME:-} ]]; then
				RELEASE="$UBUNTU_CODENAME"
			elif [[ -n ${VERSION_CODENAME:-} ]]; then
				RELEASE="$VERSION_CODENAME"
			else
				error "couldn't find UBUNTU_CODENAME or VERSION_CODENAME for Ubuntu-like system."
			fi
		else
			DIST="debian"
			if [[ -n ${DEBIAN_CODENAME:-} ]]; then
				RELEASE="$DEBIAN_CODENAME"
			elif [[ -n ${VERSION_CODENAME:-} ]]; then
				RELEASE="$VERSION_CODENAME"
			else
				error "couldn't find DEBIAN_CODENAME or VERSION_CODENAME for Debian-like system."
			fi
		fi
		;;
	esac

	if [[ -z $RELEASE ]]; then
		error "couldn't detect a supported system release."
	fi

	# Enforce supported releases based on published repos
	case "$DIST" in
	debian | raspbian)
		case "$RELEASE" in
		bookworm | trixie | sid) ;;
		*)
			error "unsupported ${DIST} release codename '$RELEASE'. Supported: bookworm, trixie, sid."
			;;
		esac
		;;
	ubuntu)
		case "$RELEASE" in
		jammy | noble) ;;
		*)
			error "unsupported ubuntu release codename '$RELEASE'. Supported: jammy, noble."
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

	if [[ -z $native ]]; then
		error "could not detect native APT architecture."
	fi

	case "$native" in
	amd64 | i386 | arm64 | armhf)
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

enable_i2pd_shepherd() {
	log "Detected GNU Shepherd. Enabling and starting i2pd via shepherd..."
	service_action "enable i2pd with shepherd" herd enable i2pd || return 1
	service_action "start i2pd with shepherd" herd start i2pd
}

enable_i2pd_openrc() {
	log "Detected OpenRC. Enabling and starting i2pd via OpenRC..."
	service_action "enable i2pd with OpenRC" rc-update add i2pd default || return 1

	if rc-service i2pd restart; then
		return 0
	fi
	warn "Failed to restart i2pd with OpenRC; trying start instead."
	service_action "start i2pd with OpenRC" rc-service i2pd start
}

enable_i2pd_runit() {
	log "Detected runit. Enabling and starting i2pd via runit..."
	if [[ -d /etc/sv/i2pd && ! -e /etc/service/i2pd ]]; then
		mkdir -p /etc/service
		service_action "link i2pd into runit service directory" ln -s /etc/sv/i2pd /etc/service/i2pd || return 1
	fi

	if sv restart i2pd; then
		return 0
	fi
	warn "Failed to restart i2pd with runit; trying start instead."
	service_action "start i2pd with runit" sv start i2pd
}

enable_i2pd_systemd() {
	log "Detected systemd. Enabling and starting i2pd.service..."
	if ! systemctl daemon-reload; then
		warn "Failed to reload systemd daemon. Continuing with service management."
	fi

	if systemd_unit_exists 'i2pd.service'; then
		ensure_systemd_unit_active 'i2pd.service'
	else
		warn "i2pd systemd service not found; cannot verify active state."
		return 1
	fi
}

enable_i2pd_s6() {
	log "Detected s6-based init. i2pd is installed, but this script does not manage s6 services automatically."
	log "Please enable and start the 'i2pd' service using your s6/s6-rc configuration."
}

enable_i2pd_sysv() {
	local failed=0

	log "Detected SysV-style init. Enabling and starting i2pd via init scripts..."
	if command -v update-rc.d >/dev/null 2>&1; then
		service_action "enable i2pd with update-rc.d" update-rc.d i2pd defaults || failed=1
	elif command -v chkconfig >/dev/null 2>&1; then
		service_action "enable i2pd with chkconfig" chkconfig i2pd on || failed=1
	else
		warn "No SysV enable helper (update-rc.d/chkconfig) found for i2pd."
		failed=1
	fi

	if command -v service >/dev/null 2>&1; then
		if ! service i2pd restart; then
			warn "Failed to restart i2pd via service; trying start instead."
			service_action "start i2pd via service" service i2pd start || failed=1
		fi
	elif [[ -x /etc/init.d/i2pd ]]; then
		if ! /etc/init.d/i2pd restart; then
			warn "Failed to restart i2pd via /etc/init.d/i2pd; trying start instead."
			service_action "start i2pd via /etc/init.d/i2pd" /etc/init.d/i2pd start || failed=1
		fi
	else
		warn "No SysV i2pd service script found."
		failed=1
	fi

	return "$failed"
}

enable_and_start_i2pd() {
	local init_comm
	init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"

	case "$init_comm" in
	shepherd)
		if command -v herd >/dev/null 2>&1; then
			enable_i2pd_shepherd
			return
		fi
		;;
	openrc-init)
		if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
			enable_i2pd_openrc
			return
		fi
		;;
	runit | runit-init)
		if command -v sv >/dev/null 2>&1; then
			enable_i2pd_runit
			return
		fi
		;;
	systemd)
		if command -v systemctl >/dev/null 2>&1; then
			enable_i2pd_systemd
			return
		fi
		;;
	s6-svscan*)
		enable_i2pd_s6
		return
		;;
	esac

	if command -v herd >/dev/null 2>&1; then
		enable_i2pd_shepherd
		return
	fi
	if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
		enable_i2pd_openrc
		return
	fi
	if command -v sv >/dev/null 2>&1; then
		enable_i2pd_runit
		return
	fi
	if command -v systemctl >/dev/null 2>&1; then
		enable_i2pd_systemd
		return
	fi
	if command -v s6-rc >/dev/null 2>&1 || command -v s6-svc >/dev/null 2>&1; then
		enable_i2pd_s6
		return
	fi
	if command -v service >/dev/null 2>&1 || [[ -x /etc/init.d/i2pd ]]; then
		enable_i2pd_sysv
		return
	fi

	warn "could not detect a known service manager (systemd, SysV, OpenRC, runit, s6, shepherd)."
	warn "i2pd is installed, but you must start and enable it manually."
	return 1
}

main "$@"
