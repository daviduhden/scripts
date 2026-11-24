#!/bin/bash

set -euo pipefail

# Lyrebird Go build/install script
# Builds and installs the latest Lyrebird from source
# on Debian-based systems.
# - Requires Go to be installed
# - Checks out the latest tagged Lyrebird source in a private build directory
# - Builds the project using make
# - Installs the resulting binary into /usr/local/bin
#
# Requirements: root privileges, network access, git, Go, and make. Go
# is not installed by this script.
#
# Side effects:
#  - Clones the repository into disposable staging as nobody
#  - Checks out the latest tag, or uses the default branch when the
#    repository has no tags
#  - Builds with make and copies the binary to /usr/local/bin
#
# The build runs with LD_PRELOAD unset. Source authenticity relies on
# the Git transport; there is no separate signature check.
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
BUILD_STAGE=
BUILD_DIR=
BUILD_USER=nobody
BIN_NAME="lyrebird"

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
	fi
	log "Re-executing this script via sudo to gain root privileges..."
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		error "Required command '$1' not found."
}

run_build() {
	runuser -u "$BUILD_USER" -- env -i HOME="$BUILD_DIR" PATH="$PATH" "$@"
}

prepare_build() {
	[[ $(id -u "$BUILD_USER") != 0 ]] || error 'An unprivileged build account is required.'
	BUILD_STAGE=$(mktemp -d /tmp/lyrebird-build.XXXXXX)
	trap 'rm -rf -- "$BUILD_STAGE"' EXIT
	chmod 0711 "$BUILD_STAGE"
	BUILD_DIR=$BUILD_STAGE/work
	install -d -m 0700 -o "$BUILD_USER" "$BUILD_DIR"
}

ensure_go() {
	require_cmd go
	log "Go version: $(go version)"
}

clone_source() {
	run_build git clone "$REPO_URL" "$BUILD_DIR/$BIN_NAME"
	cd "$BUILD_DIR/$BIN_NAME"
	local tagged_commit latest_tag
	tagged_commit=$(run_build git rev-list --tags --max-count=1)
	if [[ -n $tagged_commit ]]; then
		latest_tag=$(run_build git describe --tags "$tagged_commit")
		run_build git checkout "tags/$latest_tag" -q
	fi
}

# Build with LD_PRELOAD unset and fail if the expected binary was not
# produced.
build_lyrebird() {
	log "Building lyrebird..."
	run_build make build
	if [ ! -x ./lyrebird ]; then
		error "Build failed: lyrebird binary not found."
	fi
}

# Copy the built binary into /usr/local/bin. cp preserves the source
# mode, and chmod +x makes the installed file executable explicitly.
install_lyrebird() {
	local staged backup
	log "Installing lyrebird to /usr/local/bin..."
	[[ ! -L ./lyrebird && -f ./lyrebird ]] || error 'Expected a regular build output.'
	# Stage beside the destination and rename atomically. A plain cp over a
	# running transport fails with ETXTBSY on Linux.
	staged=$(mktemp /usr/local/bin/.lyrebird.XXXXXX) || {
		error "Cannot create a staging file for lyrebird."
	}
	if ! run_build cat -- ./lyrebird >"$staged" || ! chmod 0755 "$staged"; then
		rm -f "$staged"
		error "Cannot stage lyrebird."
	fi
	if cmp -s -- "$staged" /usr/local/bin/lyrebird; then
		rm -f -- "$staged"
		log 'Lyrebird is already installed.'
		return
	fi
	if [ -e /usr/local/bin/lyrebird ]; then
		backup="/usr/local/bin/lyrebird.bak.$(date +%Y%m%d%H%M%S)"
		cp -p /usr/local/bin/lyrebird "$backup" ||
			warn "Could not back up the previous lyrebird binary."
	fi
	if ! mv -fT -- "$staged" /usr/local/bin/lyrebird; then
		rm -f "$staged"
		error "Cannot activate lyrebird."
	fi
	log "Lyrebird installed successfully."
}

check_prereqs() {
	require_root
	require_cmd git
	require_cmd runuser
	require_cmd make
	ensure_go
}

run_update() {
	prepare_build
	clone_source
	build_lyrebird
	install_lyrebird
}

main() {
	check_prereqs
	run_update
}

main "$@"
