#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Source silent runner and start silent capture (prints output only on error)
if [[ -f "$(dirname "$0")/../lib/silent.bash" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname "$0")/../lib/silent.bash"
	start_silence
fi

# Debian add Tor APT repository script
# This script adds the Tor Project APT repository,
# installs tor automatically and enables/starts the service
# on systemd, SysV-init, OpenRC, runit, sinit (via SysV scripts),
# s6 (manual instructions) and GNU Shepherd.
#
# It is intended for Debian-based distributions (Debian/Devuan) only.
# It supports only amd64 and arm64 architectures (as per repository).
#
# Supported (based on current published repositories):
#   Debian: bookworm, trixie
#   Ubuntu: jammy, noble
#   Devuan:
#     - daedalus  -> Debian bookworm
#     - excalibur -> Debian trixie
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

OS_ID=""
OS_CODENAME=""
SUITE_CODENAME=""
ARCH_FILTER=""
APT_CMD=""

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

# Helper to ensure required commands exist
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

# Simple curl wrapper
net_curl() {
	curl -fLsS --retry 5 "$@"
}

get_suite_codename() {
	# Detect OS codename
	if [[ -n ${DEBIAN_CODENAME:-} ]]; then
		OS_CODENAME="${DEBIAN_CODENAME}"
	elif [[ -n ${UBUNTU_CODENAME:-} ]]; then
		OS_CODENAME="${UBUNTU_CODENAME}"
	elif [[ -n ${VERSION_CODENAME:-} ]]; then
		OS_CODENAME="${VERSION_CODENAME}"
	else
		error "could not detect distribution codename (DEBIAN_CODENAME/UBUNTU_CODENAME/VERSION_CODENAME missing)."
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
	ubuntu)
		case "$OS_CODENAME" in
		jammy | noble)
			SUITE_CODENAME="$OS_CODENAME"
			;;
		*)
			error "unsupported Ubuntu codename '$OS_CODENAME'. Supported: jammy, noble."
			;;
		esac
		;;
	*)
		SUITE_CODENAME="$OS_CODENAME"
		;;
	esac

	case "$SUITE_CODENAME" in
	bookworm | trixie | jammy | noble) ;;
	*)
		error "unsupported release '$SUITE_CODENAME'. Supported: bookworm, trixie, jammy, noble (or Devuan daedalus/excalibur)."
		;;
	esac
}

detect_architecture() {
	local native
	native="$(dpkg --print-architecture 2>/dev/null || true)"

	if [[ -z $native ]]; then
		error "could not detect native APT architecture."
	fi

	case "$native" in
	amd64 | arm64)
		ARCH_FILTER="$native"
		;;
	*)
		error "unsupported native architecture '$native'. Tor Project APT repository supports only amd64 and arm64."
		;;
	esac
}

ensure_base_dependencies() {
	log "Updating APT index for base repositories..."
	"$APT_CMD" update

	# Ensure gnupg (for gpg) is installed
	if ! command -v gpg >/dev/null 2>&1; then
		log "Installing gnupg (for gpg)..."
		"$APT_CMD" install -y gnupg
	fi

	# Ensure apt-transport-https is installed (some systems still require it)
	if ! dpkg -s apt-transport-https >/dev/null 2>&1; then
		log "Installing apt-transport-https..."
		"$APT_CMD" install -y apt-transport-https
	fi

	# Ensure apt-transport-tor is installed for onion transport
	if ! dpkg -s apt-transport-tor >/dev/null 2>&1; then
		log "Installing apt-transport-tor..."
		"$APT_CMD" install -y apt-transport-tor
	fi
}

choose_repo_transport() {
	log "Select Tor repository transport:"
	log "  1) Onion (tor+http, via apt-transport-tor)"
	log "  2) HTTPS (clearnet)"
	local choice=""

	while :; do
		read -r -p "Choice [1/2] (default: 1): " choice || choice=""
		choice=${choice:-1}
		case "$choice" in
		1)
			REPO_URL="tor+http://apow7mjfryruh65chtdydfmqfpj5btws7nbocgtaovhvezgccyjazpqd.onion/torproject.org"
			log "Using onion transport: $REPO_URL"
			return 0
			;;
		2)
			REPO_URL="https://deb.torproject.org/torproject.org"
			log "Using HTTPS transport: $REPO_URL"
			return 0
			;;
		*)
			warn "Invalid choice. Enter 1 or 2."
			;;
		esac
	done
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

	if systemctl list-unit-files | grep -q '^tor\.service[[:space:]]'; then
		systemctl enable tor.service
		systemctl restart tor.service
	elif systemctl list-unit-files | grep -q '^tor@default\.service[[:space:]]'; then
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
}

main() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi

	require_cmd curl
	require_cmd dpkg
	require_cmd ps

	if command -v apt-get >/dev/null 2>&1; then
		APT_CMD="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		APT_CMD="apt"
	else
		error "neither 'apt-get' nor 'apt' is available. This script supports only Debian-like/Ubuntu-like systems."
	fi

	if [[ -r /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
	else
		error "/etc/os-release not found. Cannot detect distribution."
	fi

	OS_ID="${ID:-}"

	# Normalize Ubuntu-like derivatives to ubuntu for support checks
	if [[ $OS_ID != "debian" && $OS_ID != "devuan" && $OS_ID != "raspbian" && $OS_ID != "ubuntu" && ${ID_LIKE:-} == *"ubuntu"* ]]; then
		OS_ID="ubuntu"
	fi

	if [[ ${ID_LIKE:-} != *"debian"* && ${ID_LIKE:-} != *"ubuntu"* && $OS_ID != "debian" && $OS_ID != "devuan" && $OS_ID != "raspbian" && $OS_ID != "ubuntu" ]]; then
		error "this script is intended for Debian/Devuan/Ubuntu-based systems (bookworm or newer)."
	fi

	get_suite_codename
	detect_architecture
	ensure_base_dependencies
	choose_repo_transport

	log "Detected OS ID: ${OS_ID}"
	log "Detected OS codename: ${OS_CODENAME}"
	log "Using Tor repo suite codename: ${SUITE_CODENAME}"
	log "Using native APT architecture: ${ARCH_FILTER}"

	log "Importing Tor Project signing key..."
	install -d -m 0755 /usr/share/keyrings
	net_curl "https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc" |
		gpg --dearmor -o /usr/share/keyrings/deb.torproject.org-keyring.gpg

	log "Writing APT deb822 sources file for Tor..."
	rm -f /etc/apt/sources.list.d/tor.list
	cat >/etc/apt/sources.list.d/tor.sources <<EOF
Types: deb deb-src
URIs: ${REPO_URL}
Suites: ${SUITE_CODENAME}
Components: main
Architectures: ${ARCH_FILTER}
Signed-By: /usr/share/keyrings/deb.torproject.org-keyring.gpg
EOF

	cat >>/etc/apt/sources.list.d/tor.sources <<EOF

Enabled: no
Types: deb deb-src
URIs: ${REPO_URL}
Suites: tor-nightly-main-${SUITE_CODENAME}
Components: main
Architectures: ${ARCH_FILTER}
Signed-By: /usr/share/keyrings/deb.torproject.org-keyring.gpg
EOF

	log "Updating APT index (including Tor repository)..."
	"$APT_CMD" update

	log "Installing tor, torsocks, obfs4proxy and deb.torproject.org-keyring..."
	"$APT_CMD" install -y tor torsocks obfs4proxy deb.torproject.org-keyring

	log "Enabling and starting tor service..."
	enable_and_start_tor

	log "Done. Tor should now be installed and (where supported) enabled and running."
}

main "$@"
