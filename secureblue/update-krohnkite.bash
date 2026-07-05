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
BUILD_DIR="builds"
BUILD_USER="linuxbrew"
BUILD_USER_HOME="/home/linuxbrew"
ORIGINAL_USER=""
ORIGINAL_HOME=""
SRC_DIR=""

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

ensure_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return
	fi

	if command -v run0 >/dev/null 2>&1; then
		exec run0 -- "$0" "$@"
	else
		error "run0 is required for privilege escalation on SecureBlue."
		exit 1
	fi
}

init_context() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "init_context must be called as root."
		exit 1
	fi

	if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
		ORIGINAL_USER="$SUDO_USER"
	elif [[ -n ${PKEXEC_UID:-} ]]; then
		ORIGINAL_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
	fi

	if [[ -z ${ORIGINAL_USER:-} ]]; then
		error "Could not determine invoking non-root user. Run this script via sudo/run0 from your user account."
		exit 1
	fi

	ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)"
	if [[ -z ${ORIGINAL_HOME:-} ]]; then
		error "Could not determine home directory for user '$ORIGINAL_USER'."
		exit 1
	fi

	SRC_DIR="$ORIGINAL_HOME/.local/src/Krohnkite"
}

run_as_user_env() {
	local user="$1"
	shift

	local home uid runtime_dir bus_path
	home="$(getent passwd "$user" | cut -d: -f6)"
	uid="$(id -u "$user" 2>/dev/null || true)"

	if [[ -z ${home:-} || -z ${uid:-} ]]; then
		error "Could not determine HOME/UID for user '$user'."
		exit 1
	fi

	runtime_dir="/run/user/${uid}"
	bus_path="${runtime_dir}/bus"

	local -a env_vars
	env_vars=(
		"HOME=${home}"
		"USER=${user}"
		"LOGNAME=${user}"
		"PATH=${PATH}"
		"LANG=${LANG:-C.UTF-8}"
		"LC_ALL=${LC_ALL:-C.UTF-8}"
	)

	if [[ -d $runtime_dir ]]; then
		env_vars+=("XDG_RUNTIME_DIR=${runtime_dir}")
		if [[ -S $bus_path ]]; then
			env_vars+=("DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}")
		fi
	fi

	runuser -u "$user" -- env "${env_vars[@]}" "$@"
}

run_as_original_user() {
	run_as_user_env "$ORIGINAL_USER" "$@"
}

prepare_repo() {
	mkdir -p "$(dirname "$SRC_DIR")"

	if [[ -d "$SRC_DIR/.git" ]]; then
		log "Checking Krohnkite repository status…"
		run_as_original_user git -C "$SRC_DIR" fetch --quiet
		local local_rev remote_rev
		local_rev="$(run_as_original_user git -C "$SRC_DIR" rev-parse HEAD)"
		remote_rev="$(run_as_original_user git -C "$SRC_DIR" rev-parse origin/HEAD)"

		if [[ $local_rev == "$remote_rev" ]]; then
			log "Repository already up to date. Nothing to do."
			exit 0
		fi

		log "Repository updated upstream; syncing…"
		run_as_original_user git -C "$SRC_DIR" reset --hard origin/HEAD
	else
		log "Cloning Krohnkite repository into $SRC_DIR…"
		run_as_original_user git clone "$REPO_URL" "$SRC_DIR"
	fi
}

build_krohnkite() {
	log "Building Krohnkite using task via linuxbrew..."
	local build_workdir build_output_dir
	build_workdir="$(mktemp -d "${TMPDIR:-/tmp}/krohnkite-build-XXXXXX")"
	build_output_dir="$build_workdir/$BUILD_DIR"
	cleanup_build_workdir() {
		if [[ -n ${build_workdir:-} && -d $build_workdir ]]; then
			rm -rf "$build_workdir" >/dev/null 2>&1 || true
		fi
	}
	trap cleanup_build_workdir EXIT
	if ! cp -a "$SRC_DIR"/. "$build_workdir"/; then
		error "Could not stage Krohnkite sources for the linuxbrew build."
		exit 1
	fi

	if ! chown -R "$BUILD_USER:$BUILD_USER" "$build_workdir"; then
		error "Could not set build directory ownership for '$BUILD_USER'."
		exit 1
	fi

	if ! run_as_user_env "$BUILD_USER" env \
		-u LD_PRELOAD \
		HOME="$BUILD_USER_HOME" \
		PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin \
		bash -lc "cd '$build_workdir' && task package"; then
		error "Could not start the build through linuxbrew."
		exit 1
	fi

	if ! chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$build_workdir"; then
		error "Could not restore build directory ownership."
		exit 1
	fi

	if [[ ! -d $build_output_dir ]]; then
		error "Build directory '$build_output_dir' not found."
		exit 1
	fi

	run_as_original_user mkdir -p "$SRC_DIR/$BUILD_DIR"
	run_as_original_user cp -f "$build_output_dir"/*.kwinscript "$SRC_DIR/$BUILD_DIR"/
	trap - EXIT
	cleanup_build_workdir
}

install_krohnkite() {
	local pkg files
	shopt -s nullglob
	files=("$SRC_DIR/$BUILD_DIR"/*.kwinscript)
	shopt -u nullglob
	pkg="${files[0]:-}"

	if [[ -z $pkg ]]; then
		error "No .kwinscript package found."
		exit 1
	fi

	if run_as_original_user kpackagetool6 -t KWin/Script -s krohnkite >/dev/null 2>&1; then
		log "Upgrading Krohnkite…"
		run_as_original_user kpackagetool6 -t KWin/Script -u "$pkg"
	else
		log "Installing Krohnkite…"
		run_as_original_user kpackagetool6 -t KWin/Script -i "$pkg"
	fi
}

check_prereqs() {
	ensure_cmd run0 runuser git 7z kpackagetool6
	id -u "$BUILD_USER" >/dev/null 2>&1 || {
		error "Required user '$BUILD_USER' does not exist."
		exit 1
	}
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
	ensure_root "$@"
	init_context
	check_prereqs
	run_update
}

main "$@"
