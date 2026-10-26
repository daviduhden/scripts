#!/bin/bash

set -euo pipefail

# Debian add Purple I2P APT repository script
# This script adds the Purple I2P APT repository,
# installs i2pd automatically and enables/starts the service
# on systemd, SysV-init, OpenRC, runit, sinit (via SysV scripts),
# s6 (manual instructions) and GNU Shepherd.
#
# It is intended for Debian-based distributions
# (Debian/Devuan and derivatives).
# It supports only amd64, i386, arm64 and armhf
# architectures (as per repository).
#
# Requirements: root privileges, network access, dpkg, curl, gpg,
# mktemp, and ps. gpg must already be installed; apt-transport-https is
# installed when missing.
#
# Side effects:
#  - Writes /usr/share/keyrings/purplei2p.gpg
#  - Writes /etc/apt/sources.list.d/purplei2p.sources
#  - Removes the legacy /etc/apt/sources.list.d/purplei2p.list
#  - Runs apt update and installs i2pd
#  - Enables and starts i2pd through the detected service manager
#
# The source file contains a second, disabled deb-src stanza. The
# keyring and source files are overwritten without a backup. Service
# setup covers several init systems; on s6 it only prints instructions.
# If a detected manager's commands fail, the script exits non-zero
# after i2pd has been installed.
#
# Supported (based on current published repos):
#   Debian/Raspbian: bookworm, trixie, sid
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

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
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
		error "required command '$1' is not" \
			"installed or not in PATH."
	fi
}

# Wrapper for curl
net_curl() {
	curl -fLsS --retry 5 "$@"
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root." \
			"Try: sudo $0"
	fi
}

detect_apt_cmd() {
	if command -v apt-get >/dev/null 2>&1; then
		APT_CMD="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		APT_CMD="apt"
	else
		error "neither 'apt-get' nor 'apt'" \
			"is available. This script supports only" \
			"Debian-like/Ubuntu-like systems."
	fi
}

load_os_release() {
	if [[ -r /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
	else
		error "/etc/os-release not found." \
			"Cannot detect distribution."
	fi
}

# Normalize derivatives that advertise Ubuntu in ID_LIKE to "ubuntu"
# so they use the Ubuntu repository path.
normalize_dist() {
	DIST="${ID:-}"
	if [[ $DIST != "debian" &&
		$DIST != "devuan" &&
		$DIST != "raspbian" &&
		$DIST != "ubuntu" &&
		${ID_LIKE:-} == *"ubuntu"* ]]; then
		DIST="ubuntu"
	fi
}

validate_supported_base() {
	if [[ ${ID_LIKE:-} != *"debian"* &&
		${ID_LIKE:-} != *"ubuntu"* &&
		$DIST != "debian" &&
		$DIST != "devuan" &&
		$DIST != "raspbian" &&
		$DIST != "ubuntu" ]]; then
		error "This installer supports" \
			"Debian/Devuan/Ubuntu-based systems" \
			"(bookworm or newer)."
	fi
}

compute_repo_release() {
	# The Purple I2P raspbian repository uses the plain Debian codename
	# (bookworm/trixie), not a "-rpi" suffix.
	REPO_RELEASE="$RELEASE"
}

log_detected_platform() {
	log "Detected distribution: ${DIST}"
	log "Detected release codename: ${RELEASE}"
	log "Using repo release codename: ${REPO_RELEASE}"
	log "Using native APT architecture: ${ARCH_FILTER}"
}

# Download the repository key into a temporary file, dearmor it into
# /usr/share/keyrings, and remove the temporary file on success or
# failure. The keyring is replaced on every run.
install_repo_key() {
	local key_tmp

	log "Importing signing key..."
	install -d -m 0755 /usr/share/keyrings
	key_tmp="$(mktemp /tmp/purplei2p-key.XXXXXX)" || {
		error "Cannot create a temporary key file."
	}
	if ! net_curl https://repo.i2pd.xyz/r4sas.gpg \
		-o "$key_tmp"; then
		rm -f "$key_tmp"
		error "Cannot download the Purple I2P signing key."
	fi
	if ! gpg --batch --yes --dearmor \
		-o /usr/share/keyrings/purplei2p.gpg <"$key_tmp"; then
		rm -f "$key_tmp"
		error "Cannot dearmor the Purple I2P signing key."
	fi
	rm -f "$key_tmp"
}

# Write the deb822 source and a second stanza for source packages.
# The deb-src stanza is disabled with "Enabled: no" so APT does not
# fetch source indexes unless the user opts in. The legacy .list file
# is removed to avoid duplicate entries.
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
	log "Done. i2pd should now be installed and" \
		"(where supported) enabled and running."
}

main() {
	require_root
	require_cmd curl
	require_cmd dpkg
	require_cmd gpg
	require_cmd mktemp
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
		if [[ -z ${VERSION_CODENAME:-} ]]; then
			error "could not find VERSION_CODENAME" \
				"in /etc/os-release on Devuan."
		fi

		case "$VERSION_CODENAME" in
		*daedalus*)
			RELEASE="bookworm"
			;;
		*excalibur*)
			RELEASE="trixie"
			;;
		*chimaera*)
			error "Devuan chimaera (Debian 11)" \
				"is not supported. Need Devuan" \
				"daedalus or newer."
			;;
		*)
			error "unsupported Devuan version" \
				"'${VERSION_CODENAME}'." \
				"Supported: daedalus and excalibur."
			;;
		esac
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
			error "couldn't find DEBIAN_CODENAME" \
				"or VERSION_CODENAME" \
				"in /etc/os-release."
		fi
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
			error "couldn't find UBUNTU_CODENAME" \
				"or VERSION_CODENAME" \
				"in /etc/os-release."
		fi
		DIST="ubuntu"
		;;
	###################################################
	# Other Debian-like systems (derivatives)         #
	###################################################
	*)
		if [[ -z ${ID_LIKE:-} ||
			($ID_LIKE != *"debian"* &&
			$ID_LIKE != *"ubuntu"*) ]]; then
			error "your system is not supported." \
				"Only Debian/Ubuntu-like systems" \
				"are supported."
		fi

		if [[ $ID_LIKE == *"ubuntu"* ]]; then
			DIST="ubuntu"
			if [[ -n ${UBUNTU_CODENAME:-} ]]; then
				RELEASE="$UBUNTU_CODENAME"
			elif [[ -n ${VERSION_CODENAME:-} ]]; then
				RELEASE="$VERSION_CODENAME"
			else
				error "couldn't find UBUNTU_CODENAME" \
					"or VERSION_CODENAME" \
					"for Ubuntu-like system."
			fi
		else
			DIST="debian"
			if [[ -n ${DEBIAN_CODENAME:-} ]]; then
				RELEASE="$DEBIAN_CODENAME"
			elif [[ -n ${VERSION_CODENAME:-} ]]; then
				RELEASE="$VERSION_CODENAME"
			else
				error "couldn't find DEBIAN_CODENAME" \
					"or VERSION_CODENAME" \
					"for Debian-like system."
			fi
		fi
		;;
	esac

	if [[ -z $RELEASE ]]; then
		error "couldn't detect a supported" \
			"system release."
	fi

	case "$DIST" in
	debian | raspbian)
		case "$RELEASE" in
		bookworm | trixie | sid) ;;
		*)
			error "unsupported ${DIST} release" \
				"codename '$RELEASE'." \
				"Supported: bookworm, trixie, sid."
			;;
		esac
		;;
	ubuntu)
		case "$RELEASE" in
		jammy | noble) ;;
		*)
			error "unsupported ubuntu release" \
				"codename '$RELEASE'." \
				"Supported: jammy, noble."
			;;
		esac
		;;
	*)
		error "internal error: unsupported" \
			"DIST '$DIST'."
		;;
	esac
}

# Match the native dpkg architecture against the four architectures
# the Purple I2P repository publishes.
detect_arch_filter() {
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
		error "unsupported native architecture" \
			"'$native'. This repo supports only" \
			"amd64, i386, arm64, armhf."
		;;
	esac
}

# Refresh the base index, then install gpg and apt-transport-https
# only when they are missing. Installing from the base repositories
# first keeps the later repository setup from depending on packages
# that are not yet resolvable.
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

# Run a service command, logging a warning and returning non-zero on
# failure so callers can try an alternative action.
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
	# `systemctl list-unit-files PATTERN` matches unit names
	# directly and exits 0 only when at least one unit matches.
	# The previous `systemctl list-unit-files | grep -q` form
	# returned 141 under pipefail: grep -q exits on the first
	# match, systemctl dies of SIGPIPE, and the pipeline fails
	# even though the unit exists.
	systemctl list-unit-files "$1" >/dev/null 2>&1
}

# Enable the unit, then restart it (falling back to start), and verify
# that systemd reports it active. Returns non-zero if any step fails.
ensure_systemd_unit_active() {
	local unit="$1"

	service_action "enable ${unit} with systemd" \
		systemctl enable "$unit" || return 1

	if ! systemctl restart "$unit"; then
		warn "Failed to restart ${unit}" \
			"with systemd; trying start instead."
		service_action "start ${unit} with systemd" \
			systemctl start "$unit" || return 1
	fi

	if ! systemctl is-active --quiet "$unit"; then
		warn "systemd reports ${unit} is not" \
			"active after start/restart."
		return 1
	fi

	log "Verified ${unit} is active."
}

enable_i2pd_shepherd() {
	log "Detected GNU Shepherd. Enabling and" \
		"starting i2pd via shepherd..."
	service_action "enable i2pd with shepherd" \
		herd enable i2pd || return 1
	service_action "start i2pd with shepherd" \
		herd start i2pd
}

enable_i2pd_openrc() {
	log "Detected OpenRC. Enabling and" \
		"starting i2pd via OpenRC..."
	service_action "enable i2pd with OpenRC" \
		rc-update add i2pd default || return 1

	if rc-service i2pd restart; then
		return 0
	fi
	warn "Failed to restart i2pd with" \
		"OpenRC; trying start instead."
	service_action "start i2pd with OpenRC" \
		rc-service i2pd start
}

# runit needs the service linked into /etc/service before sv can use
# it; the link is only created when the source directory exists and
# no link is already present.
enable_i2pd_runit() {
	log "Detected runit. Enabling and" \
		"starting i2pd via runit..."
	if [[ -d /etc/sv/i2pd &&
		! -e /etc/service/i2pd ]]; then
		mkdir -p /etc/service
		service_action "link i2pd into runit service directory" \
			ln -s /etc/sv/i2pd \
			/etc/service/i2pd || return 1
	fi

	if sv restart i2pd; then
		return 0
	fi
	warn "Failed to restart i2pd with" \
		"runit; trying start instead."
	service_action "start i2pd with runit" \
		sv start i2pd
}

enable_i2pd_systemd() {
	log "Detected systemd. Enabling and" \
		"starting i2pd.service..."
	if ! systemctl daemon-reload; then
		warn "Failed to reload systemd daemon." \
			"Continuing with service management."
	fi

	if systemd_unit_exists 'i2pd.service'; then
		ensure_systemd_unit_active 'i2pd.service'
	else
		warn "i2pd systemd service not found;" \
			"cannot verify active state."
		return 1
	fi
}

enable_i2pd_s6() {
	log "Detected s6-based init. i2pd is installed," \
		"but this script does not manage s6 services" \
		"automatically."
	log "Please enable and start the 'i2pd'" \
		"service using your s6/s6-rc configuration."
}

enable_i2pd_sysv() {
	local failed=0

	log "Detected SysV-style init. Enabling and" \
		"starting i2pd via init scripts..."
	if command -v update-rc.d >/dev/null 2>&1; then
		service_action "enable i2pd with update-rc.d" \
			update-rc.d i2pd defaults || failed=1
	elif command -v chkconfig >/dev/null 2>&1; then
		service_action "enable i2pd with chkconfig" \
			chkconfig i2pd on || failed=1
	else
		warn "No SysV enable helper found for i2pd."
		failed=1
	fi

	if command -v service >/dev/null 2>&1; then
		if ! service i2pd restart; then
			warn "Failed to restart i2pd via" \
				"service; trying start instead."
			service_action "start i2pd via service" \
				service i2pd start || failed=1
		fi
	elif [[ -x /etc/init.d/i2pd ]]; then
		if ! /etc/init.d/i2pd restart; then
			warn "Failed to restart i2pd via" \
				"/etc/init.d/i2pd; trying start" \
				"instead."
			service_action "start i2pd via /etc/init.d/i2pd" \
				/etc/init.d/i2pd start ||
				failed=1
		fi
	else
		warn "No SysV i2pd service script found."
		failed=1
	fi

	return "$failed"
}

# Identify the init system from PID 1 and dispatch to the matching
# helper. If PID 1 is not recognized, probe for service-manager
# commands in priority order. The s6 path only prints instructions;
# the final fallback warns and returns non-zero when no manager is
# found. sinit is expected to be handled through its SysV scripts.
enable_and_start_i2pd() {
	local init_comm
	init_comm="$(ps -p 1 -o comm= 2>/dev/null |
		tr -d ' ' || true)"

	case "$init_comm" in
	shepherd)
		if command -v herd >/dev/null 2>&1; then
			enable_i2pd_shepherd
			return
		fi
		;;
	openrc-init)
		if command -v rc-update >/dev/null 2>&1 &&
			command -v rc-service >/dev/null 2>&1; then
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
	if command -v rc-update >/dev/null 2>&1 &&
		command -v rc-service >/dev/null 2>&1; then
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
	if command -v s6-rc >/dev/null 2>&1 ||
		command -v s6-svc >/dev/null 2>&1; then
		enable_i2pd_s6
		return
	fi
	if command -v service >/dev/null 2>&1 ||
		[[ -x /etc/init.d/i2pd ]]; then
		enable_i2pd_sysv
		return
	fi

	warn "could not detect a known service manager" \
		"(systemd, SysV, OpenRC, runit, s6, shepherd)."
	warn "i2pd is installed, but you must start and" \
		"enable it manually."
	return 1
}

main "$@"
