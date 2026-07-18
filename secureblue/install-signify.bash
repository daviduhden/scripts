#!/bin/bash
set -euo pipefail

# SecureBlue signify install/update script.
# Builds OpenBSD signify from source and installs it to /usr/local/bin.
# Build dependencies are installed via Homebrew.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO="https://codeberg.org/aperezdc/signify.git"
INSTALL_PATH="/usr/local/bin/signify"
BUILD_DIR="${HOME}/.local/src/signify-build"
ROOT_CMD=""
LATEST_TAG=""
SOURCE_CHANGED=0
BUILD_LOG=""

################
# Color helpers #
################
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

log() { printf '%s %b[INFO]%b  %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b  %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*" >&2; }
error() {
	printf '%s %b[ERROR]%b %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2
	exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_non_root() {
	[ "${EUID:-$(id -u)}" -ne 0 ] || error "Run this script as your normal SecureBlue user, not root"
}

detect_root_cmd() {
	if have_cmd run0; then
		ROOT_CMD="run0"
		log "Using run0 for privileged operations."
	elif [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
		log "Running as root; no elevation helper needed."
	else
		error "run0 is required to install into /usr/local/bin"
	fi
}

run_root() {
	"$ROOT_CMD" "$@"
}

ensure_homebrew_path() {
	if have_cmd brew; then
		return
	fi

	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [ -x "$prefix/bin/brew" ]; then
			PATH="$prefix/bin:$PATH"
			export PATH
			BREW_PREFIX="$prefix"
			break
		fi
	done

	have_cmd brew || error "Homebrew is required but was not found in PATH"

	if [[ -n ${BREW_PREFIX:-} && -d $BREW_PREFIX/Cellar ]]; then
		local restricted
		restricted="$(find "$BREW_PREFIX/Cellar" -maxdepth 3 -type d ! -perm -o+rx 2>/dev/null | head -1 || true)"
		if [[ -n $restricted ]]; then
			log "Fixing Homebrew cellar permissions for multi-user access..."
			if command -v run0 >/dev/null 2>&1; then
				run0 find "$BREW_PREFIX/Cellar" -maxdepth 4 -type d ! -perm -o+rx -exec chmod o+rx {} \; 2>/dev/null || true
			else
				warn "run0 not available; cannot fix cellar permissions."
			fi
		fi
	fi
}

install_build_deps() {
	local deps=()
	local dep

	for dep in git llvm libbsd; do
		if ! brew list --formula "$dep" >/dev/null 2>&1; then
			deps+=("$dep")
		fi
	done

	if [ "${#deps[@]}" -eq 0 ]; then
		return
	fi

	log "Installing build dependencies via brew"
	brew install --quiet "${deps[@]}" >/dev/null
}

get_latest_tag() {
	git ls-remote --tags --sort='version:refname' "$REPO" 'refs/tags/v*' 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s#\^{}##' |
		uniq |
		tail -n1
}

prepare_source() {
	if [ ! -d "$BUILD_DIR/.git" ]; then
		log "Cloning signify repository"
		rm -rf "$BUILD_DIR"
		mkdir -p "$(dirname "$BUILD_DIR")"
		git clone --quiet "$REPO" "$BUILD_DIR"
	fi

	cd "$BUILD_DIR"
	log "Fetching latest tags"
	git fetch --quiet --tags --prune origin

	LATEST_TAG="$(get_latest_tag)"
	[ -n "$LATEST_TAG" ] || error "Could not determine latest signify tag"

	local current_tag
	current_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"

	if [ "$current_tag" = "$LATEST_TAG" ]; then
		log "Source already at latest tag '$LATEST_TAG'"
		SOURCE_CHANGED=0
		return 0
	fi

	log "Checking out latest tag '$LATEST_TAG'"
	git checkout --quiet "tags/$LATEST_TAG"
	SOURCE_CHANGED=1
	return 0
}

build_and_install() {
	log "Building signify from source"
	BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/signify-build.XXXXXX.log")"
	if ! env -u LD_PRELOAD make -s -C "$BUILD_DIR" CC=clang BUNDLED_LIBBSD=1 >"$BUILD_LOG" 2>&1; then
		cat "$BUILD_LOG" >&2
		error "signify build failed"
	fi
	rm -f "$BUILD_LOG"
	BUILD_LOG=""

	log "Installing to $INSTALL_PATH"
	run_root install -m 0755 "$BUILD_DIR/signify" "$INSTALL_PATH"
}

verify_install() {
	if [ -x "$INSTALL_PATH" ]; then
		log "signify installed successfully at $INSTALL_PATH"
	else
		error "Installation failed: $INSTALL_PATH not found or not executable"
	fi
}

main() {
	require_non_root
	detect_root_cmd
	ensure_homebrew_path
	install_build_deps
	prepare_source
	if [ "$SOURCE_CHANGED" -eq 1 ] || [ ! -x "$INSTALL_PATH" ]; then
		build_and_install
		verify_install
		if [ "$SOURCE_CHANGED" -eq 1 ]; then
			log "Done - signify updated to $LATEST_TAG and is available at $INSTALL_PATH"
		else
			log "Done - signify installed at $INSTALL_PATH"
		fi
	else
		verify_install
		log "Done - signify already at latest source tag ($LATEST_TAG)"
	fi
}

cleanup() {
	if [ -n "${BUILD_LOG:-}" ] && [ -f "$BUILD_LOG" ]; then
		rm -f "$BUILD_LOG"
	fi
}

trap cleanup EXIT

main "$@"
