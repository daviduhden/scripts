#!/bin/bash
set -euo pipefail

# Debian msedit update/install script (precompiled binaries)
# - Reads installed version via `edit -v`
# - Compares against latest GitHub release
# - Downloads and installs if an update is needed
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
}

ensure_cmd() {
	for cmd in "$@"; do
		require_cmd "$cmd"
	done
}

cleanup() {
	rm -rf "$TMPDIR" 2>/dev/null || true
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

detect_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) echo "x86_64" ;;
	aarch64) echo "aarch64" ;;
	*)
		error "Unsupported architecture."
		exit 1
		;;
	esac
}

get_installed_version() {
	local version

	if ! command -v edit >/dev/null 2>&1; then
		return 1
	fi

	version="$(
		edit --version 2>/dev/null |
			awk 'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){print substr($0,RSTART,RLENGTH); exit}'
	)"
	if [[ -z ${version:-} ]]; then
		version="$(
			edit -v 2>/dev/null |
				awk 'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){print substr($0,RSTART,RLENGTH); exit}'
		)"
	fi

	[[ -n ${version:-} ]] || return 1
	printf '%s\n' "$version"
}

get_latest_version_from_json() {
	local json="$1"
	awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json" | sed 's/^v//'
}

version_is_up_to_date() {
	local installed="$1"
	local latest="$2"

	[[ "$(printf '%s\n%s\n' "$latest" "$installed" | sort -V | tail -n1)" == "$installed" ]]
}

get_release_asset_from_json() {
	local json="$1"
	local arch="$2"

	awk -F'"' '/"browser_download_url":/ {print $4}' <<<"$json" |
		grep -F linux |
		grep -F "$arch" |
		grep -E '\.tar\.gz$' |
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

run_update() {
	local installed latest arch asset release_json
	installed="$(get_installed_version || true)"
	release_json="$(net_curl "$GITHUB_API")"
	latest="$(get_latest_version_from_json "$release_json")"

	if [[ -z ${latest:-} ]]; then
		error "Could not determine latest version from GitHub release metadata."
		exit 1
	fi

	if [[ -n $installed ]]; then
		log "Installed version: $installed"
	else
		log "edit not currently installed."
	fi

	log "Latest available version: $latest"

	if [[ -n $installed ]] && version_is_up_to_date "$installed" "$latest"; then
		log "edit is already up to date. Nothing to do."
		return 0
	fi

	arch="$(detect_arch)"
	asset="$(get_release_asset_from_json "$release_json" "$arch")"

	if [[ -z $asset ]]; then
		error "No suitable binary found for this architecture."
		exit 1
	fi

	install_msedit "$asset"
	rm -rf "$TMPDIR"
	log "edit successfully installed or updated to version $latest."
}

check_prereqs() {
	detect_root_cmd
	ensure_cmd curl tar grep awk sort uname find mktemp head install sed
}

main() {
	trap cleanup EXIT
	check_prereqs
	run_update
}

main "$@"
