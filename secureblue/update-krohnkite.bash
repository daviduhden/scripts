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

ensure_cmd() {
	for cmd in "$@"; do
		require_cmd "$cmd"
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
	log "Building Krohnkite using task via linuxbrew..."
	local build_workdir build_output_dir
	build_workdir="$(mktemp -d "${TMPDIR:-/tmp}/krohnkite-build-XXXXXX")"
	build_output_dir="$build_workdir/$BUILD_DIR"
	cleanup_build_workdir() {
		if [[ -n ${build_workdir:-} && -d $build_workdir ]]; then
			run0 -- rm -rf "$build_workdir" >/dev/null 2>&1 || true
		fi
	}
	trap cleanup_build_workdir EXIT
	if ! run0 -- cp -a "$SRC_DIR"/. "$build_workdir"/; then
		error "Could not stage Krohnkite sources for the linuxbrew build."
		exit 1
	fi

	if ! run0 -D "$build_workdir" -- env \
		HOME=/home/linuxbrew \
		PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin \
		task package; then
		error "Could not start the build through linuxbrew."
		exit 1
	fi

	if ! run0 -- chown -R "$(id -un):$(id -gn)" "$build_workdir"; then
		error "Could not restore build directory ownership."
		exit 1
	fi

	if [[ ! -d $build_output_dir ]]; then
		error "Build directory '$build_output_dir' not found."
		exit 1
	fi

	mkdir -p "$SRC_DIR/$BUILD_DIR"
	cp -f "$build_output_dir"/*.kwinscript "$SRC_DIR/$BUILD_DIR"/
	trap - EXIT
	cleanup_build_workdir
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

check_prereqs() {
	ensure_cmd run0 git 7z kpackagetool6
	require_exec /home/linuxbrew/.linuxbrew/bin/task
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
