#!/bin/bash
set -euo pipefail

# Secureblue Krohnkite build & install script
# Automated script to build and install the latest Krohnkite KWin script
#
# - Clones or updates the Krohnkite repository into ~/.local/src
# - Builds the .kwinscript package using go-task if the repository has changed
# - Installs or upgrades the script via kpackagetool6
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_URL="https://codeberg.org/anametologin/Krohnkite.git"
SRC_DIR="$HOME/.local/src/Krohnkite"
BUILD_DIR="builds"

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

ensure_cmd() {
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			error "Required command '$cmd' not found."
			exit 1
		fi
	done
}

repo_is_up_to_date() {
	git fetch --quiet
	local local_rev remote_rev
	local_rev="$(git rev-parse HEAD)"
	remote_rev="$(git rev-parse origin/HEAD)"
	[[ $local_rev == "$remote_rev" ]]
}

prepare_repo() {
	mkdir -p "$(dirname "$SRC_DIR")"

	if [[ -d "$SRC_DIR/.git" ]]; then
		log "Checking Krohnkite repository status…"
		cd "$SRC_DIR"

		if repo_is_up_to_date; then
			log "Repository already up to date. Nothing to do."
			exit 0
		fi

		log "Repository updated upstream; syncing…"
		git reset --hard origin/HEAD
	else
		log "Cloning Krohnkite repository into $SRC_DIR…"
		git clone "$REPO_URL" "$SRC_DIR"
		cd "$SRC_DIR"
	fi
}

build_krohnkite() {
	log "Building Krohnkite using task…"
	task package

	if [[ ! -d $BUILD_DIR ]]; then
		error "Build directory '$BUILD_DIR' not found."
		exit 1
	fi
}

install_krohnkite() {
	local pkg files
	shopt -s nullglob
	files=("$BUILD_DIR"/*.kwinscript)
	shopt -u nullglob
	pkg="${files[0]:-}"

	if [[ -z $pkg ]]; then
		error "No .kwinscript package found."
		exit 1
	fi

	if kpackagetool6 -t KWin/Script -s krohnkite >/dev/null 2>&1; then
		log "Upgrading Krohnkite…"
		kpackagetool6 -t KWin/Script -u "$pkg"
	else
		log "Installing Krohnkite…"
		kpackagetool6 -t KWin/Script -i "$pkg"
	fi
}

main() {
	ensure_cmd git task npm 7z kpackagetool6

	prepare_repo
	build_krohnkite
	install_krohnkite

	log "Krohnkite successfully built and installed."
	log "Restart KWin or log out/in if required."
}

main "$@"
