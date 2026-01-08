#!/bin/bash
set -euo pipefail

# Debian msedit update/install script (precompiled binaries)
# - Reads installed version via `edit -v`
# - Compares against latest GitHub release
# - Downloads and installs if an update is needed
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_OWNER="microsoft"
REPO_NAME="edit"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

INSTALL_DIR="/usr/local/bin"
TMPDIR="$(mktemp -d)"
ROOT_CMD=""

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
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

detect_root_cmd() {
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
	elif command -v sudo >/dev/null 2>&1; then
		ROOT_CMD="sudo"
	else
		error "sudo not found. Run as root."
		exit 1
	fi
}

run_root() {
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
}

ensure_cmd() {
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			error "Required command '$cmd' not found."
			exit 1
		fi
	done
}

detect_arch() {
	case "$(uname -m)" in
	x86_64) echo "x86_64" ;;
	aarch64) echo "aarch64" ;;
	*)
		error "Unsupported architecture."
		exit 1
		;;
	esac
}

get_installed_version() {
	if ! command -v edit >/dev/null 2>&1; then
		return 1
	fi

	edit -v 2>/dev/null | awk '{print $3}'
}

get_latest_version() {
	curl -fsSL "$GITHUB_API" |
		grep -Eo '"tag_name":[^"]+' |
		cut -d'"' -f4 |
		sed 's/^v//'
}

version_is_up_to_date() {
	local installed="$1"
	local latest="$2"

	[[ "$(printf '%s\n%s\n' "$latest" "$installed" | sort -V | tail -n1)" == "$installed" ]]
}

get_release_asset() {
	local arch="$1"

	curl -fsSL "$GITHUB_API" |
		grep -Eo '"browser_download_url":[^"]+' |
		cut -d'"' -f4 |
		grep linux |
		grep "$arch" |
		grep '\.tar\.gz$' |
		head -n1
}

install_msedit() {
	local url="$1"

	cd "$TMPDIR"
	log "Downloading $url"
	curl -fLO "$url"

	local archive bin
	archive="$(basename "$url")"

	log "Extracting $archive"
	tar -xzf "$archive"

	bin="$(find . -type f -name edit -perm -u+x | head -n1)"

	if [[ -z $bin ]]; then
		error "edit binary not found."
		exit 1
	fi

	log "Installing edit to $INSTALL_DIR"
	run_root install -m 0755 "$bin" "$INSTALL_DIR/edit"
}

main() {
	detect_root_cmd
	ensure_cmd curl tar grep awk sort uname

	local installed latest arch asset
	installed="$(get_installed_version || true)"
	latest="$(get_latest_version)"

	if [[ -n $installed ]]; then
		log "Installed version: $installed"
	else
		log "edit not currently installed."
	fi

	log "Latest available version: $latest"

	if [[ -n $installed ]] && version_is_up_to_date "$installed" "$latest"; then
		log "edit is already up to date. Nothing to do."
		exit 0
	fi

	arch="$(detect_arch)"
	asset="$(get_release_asset "$arch")"

	if [[ -z $asset ]]; then
		error "No suitable binary found for this architecture."
		exit 1
	fi

	install_msedit "$asset"

	rm -rf "$TMPDIR"
	log "edit successfully installed or updated to version $latest."
}

main "$@"
