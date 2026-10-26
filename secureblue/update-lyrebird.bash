#!/bin/bash
set -euo pipefail

# SecureBlue lyrebird install/update helper.
#
# Builds the Go-based Tor pluggable transport from the Tor Project GitLab and
# installs it as /usr/local/bin/lyrebird. Run it as the normal desktop user:
# Go is installed through Homebrew when missing, the build happens in
# ~/.local/src, and run0 is used only for the copy into /usr/local/bin.
#
# The persistent checkout is fetched and checked out at the newest tag (by the
# date of its tagged commit). If the repository has no tags, it falls back to
# a fast-forward pull of the default branch. When the checkout is already at
# that tag and the installed binary exists, the build and install are skipped.
#
# Source trust is Git-over-HTTPS only; no release checksum or signature is
# verified. Builds use the standard allocator to avoid hardened_malloc issues.

REPO="tpo/anti-censorship/pluggable-transports/lyrebird"
REPO_URL="https://gitlab.torproject.org/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="lyrebird"
INSTALL_PATH="/usr/local/bin/$BIN_NAME"
# ROOT_CMD is empty when already root. SKIP_BUILD is set when the checkout is
# already at the newest tag.
ROOT_CMD=""
SKIP_BUILD=0

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%F %T')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%F %T')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%F %T')" "$*" >&2
	exit 1
}

# Use the standard allocator for the build command and its children.
# LD_PRELOAD alone cannot override /etc/ld.so.preload.
run_build() {
	if command -v with-standard-malloc >/dev/null 2>&1; then
		with-standard-malloc "$@"
	else
		env -u LD_PRELOAD "$@"
	fi
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		error "Required command '$1' not found."
}

detect_root_cmd() {
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
		log "Running as root; no run0 needed."
	elif command -v run0 >/dev/null 2>&1; then
		ROOT_CMD="run0"
		log "Using run0 for privileged operations."
	else
		error "run0 not found. Run this script as root or install run0."
	fi
}

run_root() {
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
}

ensure_git() {
	require_cmd git
}

ensure_brew_access() {
	if command -v go >/dev/null 2>&1; then
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
		restricted="$(find "$brew_prefix/Cellar" \
			-maxdepth 3 -type d ! -perm -o+rx \
			2>/dev/null | sed -n '1p' || true)"
		if [[ -n $restricted ]]; then
			warn "Some Homebrew cellar directories have restricted permissions."
			warn "Run this to fix: run0 find" \
				"$brew_prefix/Cellar -maxdepth 4" \
				"-type d ! -perm -o+rx" \
				'-exec chmod o+rx {} \;'
		fi
	fi
}

ensure_go() {
	if command -v go >/dev/null 2>&1; then
		log "Go already installed: $(go version)"
		return
	fi

	if command -v brew >/dev/null 2>&1; then
		log "Homebrew detected, installing Go..."
		if brew list go >/dev/null 2>&1; then
			log "Go already installed via Homebrew, attempting upgrade..."
			brew upgrade go || log "brew upgrade go not needed or failed."
		else
			brew install go
		fi
	else
		error "Go is not installed and Homebrew" \
			"is not available. Please install Go" \
			"manually."
	fi

	require_cmd go
	log "Using Go at: $(command -v go)"
}

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

	# Determine the latest tag by the date of its tagged commit. This is not
	# semantic-version ordering, but it matches the upstream release flow.
	latest_tag=$(git describe --tags \
		"$(git rev-list --tags --max-count=1)" \
		2>/dev/null || true)

	if [ -n "$latest_tag" ]; then
		# Check if local HEAD is exactly at a tag
		local_tag=$(git describe --tags --exact-match \
			HEAD 2>/dev/null || true)
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

# The upstream Makefile writes the binary into the repository root.
build_lyrebird() {
	log "Building lyrebird..."
	run_build make build

	[ -x "./$BIN_NAME" ] || error \
		"Build failed: binary $BIN_NAME not found."
}

install_lyrebird() {
	log "Installing lyrebird to $INSTALL_PATH..."
	# cp and chmod are system binaries, so they remain runnable through run0
	# even though the build itself ran in the user's environment.
	run_root cp "./$BIN_NAME" "$INSTALL_PATH"
	run_root chmod +x "$INSTALL_PATH"
	log "Lyrebird installed successfully."
}

check_prereqs() {
	detect_root_cmd
	ensure_brew_access
	ensure_git
	ensure_go
}

# Skipping requires both conditions: a current checkout and an installed
# binary. A missing binary forces a rebuild even when the source is current.
maybe_skip_build() {
	if [ "$SKIP_BUILD" -eq 1 ] && [ -x "$INSTALL_PATH" ]; then
		log "No build required. Exiting."
		return 0
	fi
	return 1
}

run_update() {
	clone_or_update_repo
	if maybe_skip_build; then
		return 0
	fi
	build_lyrebird
	install_lyrebird
	log "Done. Make sure $INSTALL_PATH is in your PATH."
}

main() {
	check_prereqs
	run_update
}

main "$@"
