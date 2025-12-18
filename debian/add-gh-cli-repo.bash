#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

set -euo pipefail

# Debian add GitHub CLI APT repository script
# Add the official GitHub CLI APT repository
# and install gh using a deb822 source with the key in
# /etc/apt/keyrings. Supports Debian/Devuan (bookworm or newer)
# and Ubuntu (jammy or newer).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() {
	printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2
	exit 1
}

fetch_key() {
	if command -v curl >/dev/null 2>&1; then
		curl -fLsS --retry 5 "https://cli.github.com/packages/githubcli-archive-keyring.gpg" -o "$TMPKEY" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -nv -O "$TMPKEY" "https://cli.github.com/packages/githubcli-archive-keyring.gpg" && return 0
	fi
	return 1
}

main() {
	local OS_ID OS_LIKE RELEASE APT_CMD ARCH KEYRING TMPKEY

	require_cmd() {
		if ! command -v "$1" >/dev/null 2>&1; then
			error "required command '$1' is not installed or not in PATH."
		fi
	}

	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi

	require_cmd dpkg

	if [[ -r /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
	else
		error "/etc/os-release not found. Cannot detect distribution."
	fi

	OS_ID="${ID:-}"
	OS_LIKE="${ID_LIKE:-}"
	RELEASE=""

	if [[ $OS_ID != "debian" && $OS_ID != "devuan" && $OS_ID != "raspbian" && $OS_ID != "ubuntu" && $OS_LIKE == *"ubuntu"* ]]; then
		OS_ID="ubuntu"
	fi

	if [[ $OS_ID != "debian" && $OS_ID != "devuan" && $OS_ID != "raspbian" && $OS_ID != "ubuntu" && $OS_LIKE != *"debian"* && $OS_LIKE != *"ubuntu"* ]]; then
		error "This installer supports Debian/Devuan/Ubuntu derivatives (bookworm or newer)."
	fi

	if [[ -n ${DEBIAN_CODENAME:-} ]]; then
		RELEASE="$DEBIAN_CODENAME"
	elif [[ -n ${UBUNTU_CODENAME:-} ]]; then
		RELEASE="$UBUNTU_CODENAME"
	elif [[ -n ${VERSION_CODENAME:-} ]]; then
		RELEASE="$VERSION_CODENAME"
	else
		error "could not detect distribution codename (DEBIAN_CODENAME/UBUNTU_CODENAME/VERSION_CODENAME)."
	fi

	if [[ $OS_ID == "devuan" ]]; then
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

	case "$OS_ID" in
	ubuntu)
		case "$RELEASE" in
		jammy | noble) ;;
		*)
			error "unsupported Ubuntu release '$RELEASE'. Supported: jammy, noble."
			;;
		esac
		;;
	*)
		case "$RELEASE" in
		bookworm | trixie | sid) ;;
		*)
			error "unsupported release '$RELEASE'. Supported: bookworm, trixie, sid (or Devuan daedalus/excalibur)."
			;;
		esac
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
	if [[ -z $ARCH ]]; then
		error "could not determine dpkg architecture."
	fi

	case "$ARCH" in
	amd64 | arm64 | i386 | armhf) ;;
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

	mkdir -p /etc/apt/keyrings && chmod 0755 /etc/apt/keyrings
	KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
	TMPKEY="$(mktemp)"

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
	cat >/etc/apt/sources.list.d/github-cli.sources <<EOF
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
}

main "$@"
