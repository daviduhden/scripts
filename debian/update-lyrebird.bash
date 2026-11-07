#!/bin/bash

set -euo pipefail

# Lyrebird Go build/install script
# Builds and installs the latest Lyrebird from source
# on Debian-based systems.
# - Requires Go to be installed
# - Clones or updates the Lyrebird GitLab repository
# - Builds the project using make
# - Installs the resulting binary into /usr/local/bin
#
# Requirements: root privileges, network access, git, Go, and make. Go
# is not installed by this script.
#
# Side effects:
#  - Clones or updates the repository under $HOME/.local/src/lyrebird
#  - Checks out the latest tag, or pulls the default branch when the
#    repository has no tags
#  - Builds with make and copies the binary to /usr/local/bin
#
# The build runs with LD_PRELOAD unset. Source authenticity relies on
# the Git transport; there is no separate signature check. When HEAD is
# already at the latest tag, the build and install steps are skipped
# (the installed binary is not compared against the source).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PATH="${PATH}:/usr/local/go/bin"
export PATH

# Preserve the original path and arguments so require_root can re-exec the
# script through sudo without losing user-supplied options.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	SCRIPT_PATH="${BASH_SOURCE[0]}"
else
	SCRIPT_PATH="$0"
fi
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_ARGS=("$@")

REPO="tpo/anti-censorship/pluggable-transports/lyrebird"
REPO_URL="https://gitlab.torproject.org/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="lyrebird"

# Control: set when the local copy is already on the latest tag
SKIP_BUILD=0

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
ROOT_ENV_VARS=()

require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
	fi
	local -a env_args=()
	local name
	for name in "${ROOT_ENV_VARS[@]}"; do
		if [[ -v $name ]]; then
			env_args+=("$name=${!name}")
		fi
	done
	log "Re-executing this script via sudo to gain root privileges..."
	if ((${#env_args[@]} > 0)); then
		exec sudo -- env "${env_args[@]}" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
	fi
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		error "Required command '$1' not found."
}

ensure_go() {
	require_cmd go
	log "Go version: $(go version)"
}

# Clone on first use, fetch tags, and compare HEAD with the newest tag.
# The newest tag is the one attached to the most recent commit in
# rev-list --tags output, not necessarily the highest version string.
# Sets SKIP_BUILD when HEAD is exactly that tag.
clone_or_update_repo() {
	mkdir -p "$BUILD_DIR"
	cd "$BUILD_DIR"
	if [ ! -d "$BIN_NAME" ]; then
		log "Cloning $BIN_NAME repository..."
		git clone "$REPO_URL" "$BIN_NAME"
	fi

	cd "$BUILD_DIR/$BIN_NAME"

	# Fetch tags and remote refs
	git fetch --tags --prune origin || git fetch --tags --prune

	# Determine latest tag (by tag creation date)
	latest_tag=$(git describe --tags \
		"$(git rev-list --tags --max-count=1)" \
		2>/dev/null || true)

	if [ -n "$latest_tag" ]; then
		# Check if local HEAD is exactly at a tag
		local_tag=$(git describe --tags \
			--exact-match HEAD 2>/dev/null || true)
		if [ "$local_tag" = "$latest_tag" ]; then
			log "Local repository is already at" \
				"latest tag '$latest_tag'." \
				"Skipping build."
			SKIP_BUILD=1
			return
		fi
		log "Checking out latest tag $latest_tag..."
		git checkout "tags/$latest_tag" -q
	else
		log "No tags found; updating to latest commit on default branch..."
		git pull --ff-only
	fi
}

# Build with LD_PRELOAD unset and fail if the expected binary was not
# produced.
build_lyrebird() {
	log "Building lyrebird..."
	env -u LD_PRELOAD make build
	if [ ! -x ./lyrebird ]; then
		error "Build failed: lyrebird binary not found."
	fi
}

# Copy the built binary into /usr/local/bin. cp preserves the source
# mode, and chmod +x makes the installed file executable explicitly.
install_lyrebird() {
	local staged backup
	log "Installing lyrebird to /usr/local/bin..."
	# Stage beside the destination and rename atomically. A plain cp over a
	# running transport fails with ETXTBSY on Linux.
	staged=$(mktemp /usr/local/bin/.lyrebird.XXXXXX) || {
		error "Cannot create a staging file for lyrebird."
	}
	if ! install -m 0755 ./lyrebird "$staged"; then
		rm -f "$staged"
		error "Cannot stage lyrebird."
	fi
	if [ -e /usr/local/bin/lyrebird ]; then
		backup="/usr/local/bin/lyrebird.bak.$(date +%Y%m%d%H%M%S)"
		cp -p /usr/local/bin/lyrebird "$backup" ||
			warn "Could not back up the previous lyrebird binary."
	fi
	if ! mv -f "$staged" /usr/local/bin/lyrebird; then
		rm -f "$staged"
		error "Cannot activate lyrebird."
	fi
	log "Lyrebird installed successfully."
}

check_prereqs() {
	require_root
	require_cmd git
	ensure_go
}

maybe_skip_build() {
	if [ "$SKIP_BUILD" -eq 1 ]; then
		log "No build required. Exiting."
		return 0
	fi
	return 1
}

run_update() {
	clone_or_update_repo
	if maybe_skip_build; then
		exit 0
	fi
	build_lyrebird
	install_lyrebird
}

main() {
	check_prereqs
	run_update
}

main "$@"
