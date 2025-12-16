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
elif [[ -f "$(dirname "$0")/../lib/silent" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname "$0")/../lib/silent"
	start_silence
fi

# Debian btop++ update script
# Build and install the latest btop++ from source on Debian-based systems.
# - Fetches the latest release tag from GitHub
# - Installs build dependencies if missing
# - Clones the repo at that tag, builds, and installs
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="aristocratos/btop"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
REPO_URL="https://github.com/${REPO}.git"
GH_USER="${GH_USER:-admin}"
GH_HOST="${GH_HOST:-github.com}"

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

# Resolve GH user's home and config dir
if command -v getent >/dev/null 2>&1; then
	GH_HOME="$(getent passwd "$GH_USER" | awk -F: '{print $6}')"
else
	GH_HOME="/home/$GH_USER"
fi
GH_CONFIG_DIR="${GH_HOME}/.config/gh"

run_as_gh_user() {
	if command -v runuser >/dev/null 2>&1; then
		runuser -u "$GH_USER" -- "$@"
	else
		su - "$GH_USER" -c "$*"
	fi
}

# Helpers
net_curl() {
	curl -fLsS --retry 5 "$@"
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

get_latest_tag() {
	local tag json

	if has_cmd gh; then
		if tag="$(run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh api "repos/${REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)" && [[ -n $tag ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	if has_cmd git; then
		tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null |
			awk '{print $2}' |
			sed 's#refs/tags/##' |
			sed 's/\^{}//' |
			sort -Vr |
			head -n1)"
		if [[ -n $tag ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
		return 1
	fi
	awk -F '"' '"tag_name":/ {print $4; exit}' <<<"$json"
}

get_current_version() {
	if command -v btop >/dev/null 2>&1; then
		# Extract versions like 1.4.5 or v1.4.5 from the first matching line
		btop --version 2>/dev/null | awk 'match($0,/v?[0-9]+\.[0-9]+\.[0-9]+/){ver=substr($0,RSTART,RLENGTH); sub(/^v/,"",ver); print ver; exit}'
	fi
}

install_build_deps() {
	local apt_cmd
	if command -v apt-get >/dev/null 2>&1; then
		apt_cmd="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		apt_cmd="apt"
	else
		error "neither 'apt-get' nor 'apt' is available."
	fi

	log "Installing build dependencies (gh git build-essential cmake libncurses-dev)..."
	"$apt_cmd" update
	"$apt_cmd" install -y gh git build-essential cmake libncurses-dev
}

fetch_source() {
	local tag="$1" dest="$2" src_dir="" tarball_url tarball

	if has_cmd gh; then
		log "Cloning btop tag ${tag} with GitHub CLI..." >&2
		if run_as_gh_user env GH_CONFIG_DIR="$GH_CONFIG_DIR" GH_HOST="$GH_HOST" gh repo clone "$REPO" "$dest/btop" -- --branch "$tag" --depth 1 >/dev/null 2>&1; then
			printf '%s\n' "$dest/btop"
			return 0
		fi
		warn "gh repo clone failed; falling back to git/curl." >&2
	fi

	if has_cmd git; then
		log "Cloning btop tag ${tag} with git..." >&2
		if git clone --depth 1 --branch "$tag" "$REPO_URL" "$dest/btop"; then
			printf '%s\n' "$dest/btop"
			return 0
		fi
		warn "git clone failed; falling back to tarball download." >&2
	fi

	tarball_url="https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"
	tarball="$dest/btop.tar.gz"

	log "Downloading tarball ${tarball_url} as last resort..." >&2
	if net_curl "$tarball_url" -o "$tarball" && tar -xzf "$tarball" -C "$dest"; then
		src_dir="$(find "$dest" -maxdepth 1 -type d -name 'btop*' | head -n1)"
		if [[ -n $src_dir ]]; then
			printf '%s\n' "$src_dir"
			return 0
		fi
	fi

	return 1
}

build_and_install() {
	local tag="$1"
	local tmpdir="" src_dir

	tmpdir=$(mktemp -d /tmp/btop-src-XXXXXX) || error "cannot create temporary directory for source."
	trap '[[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir"' EXIT

	src_dir="$(fetch_source "$tag" "$tmpdir")" || error "could not fetch source via gh/git/curl."
	if [[ -z $src_dir ]]; then
		error "source directory path was empty after fetch."
	fi

	log "Building btop..."
	cd "$src_dir"
	make -j"$(nproc)"

	log "Installing btop..."
	make install

	log "btop ${tag} installed successfully."
}

main() {
	require_root
	require_cmd curl
	require_cmd awk
	require_cmd tar

	install_build_deps

	log "Fetching latest btop release tag..."
	local latest_tag
	latest_tag="$(get_latest_tag || true)"
	if [[ -z $latest_tag ]]; then
		error "could not determine latest release tag from GitHub."
	fi

	log "Latest release tag: ${latest_tag}"
	local latest_stripped="${latest_tag#v}"

	local current
	current="$(get_current_version)"
	if [[ -n $current ]]; then
		log "Currently installed btop version: ${current}"
		if [[ $current == "$latest_stripped" || $current == "$latest_tag" ]]; then
			log "btop is already up to date. Nothing to do."
			exit 0
		fi
	else
		log "btop is not currently installed."
	fi

	build_and_install "$latest_tag"
}

main "$@"
