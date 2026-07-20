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
BUILD_DIR_NAME="builds"
SRC_DIR="$HOME/.local/src/Krohnkite"

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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
}

require_exec() {
	[[ -x $1 ]] || {
		error "Required executable '$1' not found."
		exit 1
	}
}

ensure_brew_path() {
	if command -v task >/dev/null 2>&1; then
		return 0
	fi

	local brew_prefix=""
	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [ -x "$prefix/bin/brew" ]; then
			export PATH="$prefix/bin:$prefix/sbin:$PATH"
			brew_prefix="$prefix"
			break
		fi
	done

	if [[ -n $brew_prefix && -d $brew_prefix/Cellar ]]; then
		local restricted
		restricted="$(find "$brew_prefix/Cellar" -maxdepth 3 -type d ! -perm -o+rx 2>/dev/null | head -1 || true)"
		if [[ -n $restricted ]]; then
			warn "Some Homebrew cellar directories have restricted permissions."
			warn "Run this to fix: run0 find $brew_prefix/Cellar -maxdepth 4 -type d ! -perm -o+rx -exec chmod o+rx {} \\;"
		fi
	fi
}

prepare_repo() {
	mkdir -p "$(dirname "$SRC_DIR")"

	if [[ -d "$SRC_DIR/.git" ]]; then
		log "Checking Krohnkite repository status…"
		git -C "$SRC_DIR" fetch --quiet
		local local_rev remote_rev
		local_rev="$(git -C "$SRC_DIR" rev-parse HEAD)"
		remote_rev="$(git -C "$SRC_DIR" rev-parse origin/HEAD)"

		if [[ $local_rev == "$remote_rev" ]]; then
			log "Repository already up to date. Nothing to do."
			exit 0
		fi

		log "Repository updated upstream; syncing…"
		git -C "$SRC_DIR" reset --hard origin/HEAD
	else
		log "Cloning Krohnkite repository into $SRC_DIR…"
		git clone "$REPO_URL" "$SRC_DIR"
	fi
}

build_krohnkite() {
	log "Building Krohnkite using task..."

	ensure_brew_path

	cd "$SRC_DIR"
	if ! env -u LD_PRELOAD task package; then
		error "Krohnkite build failed."
		exit 1
	fi

	if [[ ! -d "$SRC_DIR/$BUILD_DIR_NAME" ]]; then
		error "Build directory '$SRC_DIR/$BUILD_DIR_NAME' not found."
		exit 1
	fi
}

install_krohnkite() {
	local pkg files
	shopt -s nullglob
	files=("$SRC_DIR/$BUILD_DIR_NAME"/*.kwinscript)
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

check_prereqs() {
	require_cmd git
	require_cmd 7z
	require_cmd kpackagetool6
	ensure_brew_path
	require_exec "$(command -v task)"
}

run_update() {
	prepare_repo
	build_krohnkite
	install_krohnkite

	log "Krohnkite successfully built and installed."
	log "Restart KWin or log out/in if required."
}

main() {
	check_prereqs
	run_update
}

main "$@"
