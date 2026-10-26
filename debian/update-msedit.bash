#!/bin/bash
set -euo pipefail

# Debian msedit update/install script (precompiled binaries)
# - Reads the installed version with `edit --version` or `edit -v`
# - Compares against latest GitHub release
# - Downloads and installs if an update is needed
#
# Requirements: curl, tar, grep, awk, sort, uname, find, mktemp, head,
# sed, and install. Root is not required if sudo is available; the
# installation step is elevated through sudo when needed.
#
# Side effects:
#  - Downloads the matching Linux release tarball into a temporary
#    directory under /tmp
#  - Installs the edit binary as /usr/local/bin/edit
#  - Removes the temporary directory on exit
#
# The download is not checked against a published checksum or
# signature. Only x86_64 and aarch64 are supported. The installed
# version is compared with the release tag as versions, so a newer
# installed build is left in place.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO_OWNER="microsoft"
REPO_NAME="edit"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}"
GITHUB_API="${GITHUB_API}/${REPO_NAME}/releases/latest"

INSTALL_DIR="/usr/local/bin"
WORK_DIR=""
ROOT_CMD=""

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Choose between direct execution as root and sudo. Lack of both is
# fatal because installation writes to /usr/local/bin.
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
	rm -rf "$WORK_DIR" 2>/dev/null || true
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

# Read the installed version. Both --version and -v are tried; returns
# non-zero when the binary is absent or no semantic version can be
# extracted.
get_installed_version() {
	local version

	if ! command -v edit >/dev/null 2>&1; then
		return 1
	fi

	version="$(
		edit --version 2>/dev/null | awk \
			'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){
				print substr($0,RSTART,RLENGTH);
				exit}'
	)"
	if [[ -z ${version:-} ]]; then
		version="$(
			edit -v 2>/dev/null | awk \
				'match($0,/[0-9]+\.[0-9]+\.[0-9]+/){
					print substr($0,RSTART,RLENGTH);
					exit}'
		)"
	fi

	[[ -n ${version:-} ]] || return 1
	printf '%s\n' "$version"
}

get_latest_version_from_json() {
	local json="$1"
	awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json" | sed 's/^v//'
}

# Compare versions with sort -V and test whether the installed version
# sorts at or above the latest one.
version_is_up_to_date() {
	local installed="$1"
	local latest="$2"

	[[ "$(printf '%s\n%s\n' \
		"$latest" "$installed" |
		sort -V | tail -n1)" == "$installed" ]]
}

# Select the first browser_download_url that contains "linux", the
# architecture string, and a .tar.gz suffix.
get_release_asset_from_json() {
	local json="$1"
	local arch="$2"

	awk -F'"' '/"browser_download_url":/ {print $4}' <<<"$json" |
		grep -F linux |
		grep -F "$arch" |
		grep -E '\.tar\.gz$' |
		sed -n '1p'
}

# Download the release archive with curl -O in WORK_DIR, extract it,
# find the first executable named edit, and install it. curl here does
# not use the net_curl retry wrapper.
install_msedit() {
	local url="$1"

	cd "$WORK_DIR"
	log "Downloading $url"
	curl -fLO "$url"

	local archive bin
	archive="$(basename "$url")"

	log "Extracting $archive"
	tar -xzf "$archive"

	# sed reads the whole stream; `| head -n1` would exit early
	# and make find die of SIGPIPE (141 under pipefail).
	bin="$(find . -type f -name edit -perm -u+x | sed -n '1p')"

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
		error "Could not determine latest version" \
			"from GitHub release metadata."
		exit 1
	fi

	if [[ -n $installed ]]; then
		log "Installed version: $installed"
	else
		log "edit not currently installed."
	fi

	log "Latest available version: $latest"

	if [[ -n $installed ]] &&
		version_is_up_to_date "$installed" "$latest"; then
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
	rm -rf "$WORK_DIR"
	log "edit successfully installed or updated to version $latest."
}

check_prereqs() {
	detect_root_cmd
	ensure_cmd curl tar grep awk sort uname find \
		mktemp head install sed
}

main() {
	check_prereqs
	# The EXIT trap removes the work directory on every later failure
	# path as well as on success.
	WORK_DIR="$(mktemp -d /tmp/msedit-XXXXXX)" || {
		error "Cannot create temporary directory."
		exit 1
	}
	trap cleanup EXIT
	run_update
}

main "$@"
