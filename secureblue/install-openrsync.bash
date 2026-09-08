#!/bin/bash
set -euo pipefail

# SecureBlue openrsync install/update script.
# Builds openrsync from source and installs it to /usr/local.
# Build dependencies are installed via Homebrew.
#
# Upstream release tags are stale; this tracks the latest
# master branch commit instead.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO="https://github.com/kristapsdz/openrsync.git"
PREFIX="/usr/local"
INSTALL_PATH="/usr/local/bin/openrsync"
BUILD_DIR="${HOME}/.local/src/openrsync-build"
ROOT_CMD=""
LATEST_COMMIT=""
SOURCE_CHANGED=0
BUILD_LOG=""
CONFIG_EXTRA=()

################
# Color helpers #
################

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%F %T')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%F %T')" "$*" >&2
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%F %T')" "$*" >&2
	exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_non_root() {
	[ "${EUID:-$(id -u)}" -ne 0 ] || error \
		"Run this script as your normal SecureBlue user, not root"
}

detect_root_cmd() {
	if have_cmd run0; then
		ROOT_CMD="run0"
		log "Using run0 for privileged operations."
	elif [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
		log "Running as root; no elevation helper needed."
	else
		error "run0 is required to install into /usr/local"
	fi
}

run_root() {
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
}

ensure_homebrew_path() {
	if have_cmd brew; then
		return
	fi

	local brew_prefix=""
	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [ -x "$prefix/bin/brew" ]; then
			PATH="$prefix/bin:$PATH"
			export PATH
			brew_prefix="$prefix"
			break
		fi
	done

	have_cmd brew || error "Homebrew is required but was not found in PATH"

	if [[ -n $brew_prefix && -d $brew_prefix/Cellar ]]; then
		local restricted
		restricted="$(find "$brew_prefix/Cellar" \
			-maxdepth 3 -type d ! -perm -o+rx \
			2>/dev/null | sed -n '1p' || true)"
		if [[ -n $restricted ]]; then
			warn "Some Homebrew cellar directories have restricted permissions."
			warn "Run this to fix: run0 find" \
				"$brew_prefix/Cellar -maxdepth 4" \
				"-type d ! -perm -o+rx" \
				"-exec chmod o+rx {} \\;"
		fi
	fi
}

install_build_deps() {
	local deps=()
	local dep

	# Configure invokes plain make internally.
	# Install bmake (which is what actually builds openrsync).
	for dep in git bmake llvm pkgconf zlib; do
		if ! brew list --formula "$dep" >/dev/null 2>&1; then
			deps+=("$dep")
		fi
	done

	if [ "${#deps[@]}" -eq 0 ]; then
		have_cmd clang || error "clang is required but was not found in PATH"
		return
	fi

	log "Installing build dependencies via brew"
	brew install --quiet "${deps[@]}" >/dev/null

	have_cmd clang || error "clang is required but was not found in PATH"
}

# Homebrew's zlib is keg-only, so pkg-config usually cannot see it.
# Only add explicit paths when pkg-config cannot find zlib; otherwise
# the build's own "pkg-config --libs zlib || -lz" fallback applies.
configure_zlib_flags() {
	if pkg-config --exists zlib 2>/dev/null; then
		return
	fi

	local zlib_prefix
	zlib_prefix="$(brew --prefix zlib 2>/dev/null || true)"
	[ -n "$zlib_prefix" ] || error "Could not determine Homebrew zlib prefix"

	CONFIG_EXTRA=(
		CPPFLAGS="-I$zlib_prefix/include"
		LDFLAGS="-L$zlib_prefix/lib"
	)
}

get_latest_commit() {
	git ls-remote --heads "$REPO" refs/heads/master 2>/dev/null |
		awk '{print $1}'
}

prepare_source() {
	if [ ! -d "$BUILD_DIR/.git" ]; then
		log "Cloning openrsync repository"
		rm -rf "$BUILD_DIR"
		mkdir -p "$(dirname "$BUILD_DIR")"
		git clone --quiet "$REPO" "$BUILD_DIR"
	fi

	cd "$BUILD_DIR"
	log "Fetching latest upstream changes"
	git fetch --quiet --prune origin

	LATEST_COMMIT="$(get_latest_commit)"
	[ -n "$LATEST_COMMIT" ] || error "Could not determine latest openrsync commit"

	local current_commit
	current_commit="$(git rev-parse HEAD)"

	if [ "$current_commit" = "$LATEST_COMMIT" ]; then
		log "Source already at latest commit '$LATEST_COMMIT'"
		SOURCE_CHANGED=0
		return 0
	fi

	log "Checking out latest commit '$LATEST_COMMIT'"
	git checkout --quiet "$LATEST_COMMIT"
	SOURCE_CHANGED=1
	return 0
}

build_and_install() {
	BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/openrsync-build.XXXXXX.log")"
	cd "$BUILD_DIR"

	log "Configuring openrsync"
	if ! env -u LD_PRELOAD ./configure PREFIX="$PREFIX" \
		CC=clang "${CONFIG_EXTRA[@]}" >"$BUILD_LOG" 2>&1; then
		cat "$BUILD_LOG" >&2
		error "openrsync configure failed"
	fi

	log "Building openrsync from source"
	if ! env -u LD_PRELOAD bmake -s >>"$BUILD_LOG" 2>&1; then
		cat "$BUILD_LOG" >&2
		error "openrsync build failed"
	fi
	rm -f "$BUILD_LOG"
	BUILD_LOG=""

	# Replicate the Makefile's "install" target with plain install(1):
	# root cannot execute Homebrew binaries (run0 exits with 203),
	# but install is a system binary.
	log "Installing to $PREFIX"
	run_root sh -c '
		install -d "$2/bin" "$2/man/man1" "$2/man/man5" &&
		install -m 0755 "$1/openrsync" "$2/bin/openrsync" &&
		install -m 0644 "$1/openrsync.1" "$2/man/man1/openrsync.1" &&
		install -m 0644 "$1/rsync.5" "$1/rsyncd.5" "$2/man/man5/"
	' sh "$BUILD_DIR" "$PREFIX"
}

verify_install() {
	if [ -x "$INSTALL_PATH" ]; then
		log "openrsync installed successfully at $INSTALL_PATH"
	else
		error "Installation failed: $INSTALL_PATH not found or not executable"
	fi
}

main() {
	require_non_root
	detect_root_cmd
	ensure_homebrew_path
	install_build_deps
	configure_zlib_flags
	prepare_source
	if [ "$SOURCE_CHANGED" -eq 1 ] || [ ! -x "$INSTALL_PATH" ]; then
		build_and_install
		verify_install
		if [ "$SOURCE_CHANGED" -eq 1 ]; then
			log "Done - openrsync updated to $LATEST_COMMIT" \
				"and is available at $INSTALL_PATH"
		else
			log "Done - openrsync installed at $INSTALL_PATH"
		fi
	else
		verify_install
		log "Done - openrsync already at latest source commit ($LATEST_COMMIT)"
	fi
}

cleanup() {
	if [ -n "${BUILD_LOG:-}" ] && [ -f "$BUILD_LOG" ]; then
		rm -f "$BUILD_LOG"
	fi
}

trap cleanup EXIT

main "$@"
