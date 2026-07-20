#!/bin/bash
set -euo pipefail

# SecureBlue arti and oniux update/install script
# Automated script to install or update Rust-based Tor software (arti and oniux)
# - Ensures Rust and cargo are installed (via rustup or Homebrew)
# - Clones the arti and oniux repositories from the Tor Project GitLab
# - Determines the latest release tags for each project
# - Installs or updates the crates via cargo with appropriate features
# - Installs the resulting binaries into /usr/local/bin (requires root)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_ARTI="https://gitlab.torproject.org/tpo/core/arti.git"
REPO_ONIUX="https://gitlab.torproject.org/tpo/core/oniux.git"

CARGO_BIN_DIR="${CARGO_HOME:-$HOME/.cargo}/bin"
ROOT_CMD=""
TMP_FILES=()

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

cleanup_tmp_files() {
	local file
	for file in "${TMP_FILES[@]}"; do
		[[ -n "$file" && -f "$file" ]] && rm -f -- "$file"
	done
}

trap cleanup_tmp_files EXIT

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
}

detect_root_cmd() {
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		ROOT_CMD=""
		log "Running as root; no elevation helper needed for privileged operations."
	elif command -v run0 >/dev/null 2>&1; then
		ROOT_CMD="run0"
		log "Using run0 for privileged operations."
	else
		error "run0 not found. Run this script as root or install run0."
		exit 1
	fi
}

run_root() {
	if [ -n "$ROOT_CMD" ]; then
		"$ROOT_CMD" "$@"
	else
		"$@"
	fi
}

ensure_brew_path() {
	if command -v cargo >/dev/null 2>&1; then
		return 0
	fi

	local brew_prefix=""
	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [ -x "$prefix/bin/cargo" ]; then
			export PATH="$prefix/bin:$PATH"
			brew_prefix="$prefix"
			if [[ -d $brew_prefix/Cellar ]]; then
				local restricted
				restricted="$(find "$brew_prefix/Cellar" -maxdepth 3 -type d ! -perm -o+rx 2>/dev/null | head -1 || true)"
				if [[ -n $restricted ]]; then
					warn "Some Homebrew cellar directories have restricted permissions."
					warn "Run this to fix: run0 find $brew_prefix/Cellar -maxdepth 4 -type d ! -perm -o+rx -exec chmod o+rx {} \\;"
				fi
			fi
			return 0
		fi
	done

	return 1
}

ensure_rust() {
	ensure_brew_path || true

	if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
		log "Rust and cargo are already installed."
		return
	fi

	if command -v brew-proxy >/dev/null 2>&1 || command -v brew >/dev/null 2>&1; then
		local brew_cmd
		brew_cmd="$(command -v brew-proxy 2>/dev/null || command -v brew 2>/dev/null || true)"
		log "Homebrew detected ($brew_cmd), installing Rust..."
		if "$brew_cmd" list rust >/dev/null 2>&1; then
			log "Rust already installed with Homebrew, attempting upgrade..."
			"$brew_cmd" upgrade rust || log "$brew_cmd upgrade rust failed or was not needed."
		else
			"$brew_cmd" install rust
		fi

		ensure_brew_path

		if command -v cargo >/dev/null 2>&1; then
			log "Using cargo at: $(command -v cargo)"
			return
		fi

		warn "Rust is installed via Homebrew but cargo is not accessible."
		warn "Falling back to rustup for user-local Rust installation."
	fi

	log "Installing Rust via rustup..."
	if ! command -v curl >/dev/null 2>&1; then
		error "curl is required to install rustup but is not installed."
		exit 1
	fi
	local rustup_script
	rustup_script="$(mktemp rustup-init.XXXXXX.sh)"
	TMP_FILES+=("$rustup_script")
	log "Downloading rustup installer..."
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$rustup_script"
	log "Running rustup installer..."
	sh "$rustup_script" -y

	if [ -f "$HOME/.cargo/env" ]; then
		# shellcheck source=/dev/null
		. "$HOME/.cargo/env"
	else
		export PATH="$HOME/.cargo/bin:$PATH"
	fi

	if command -v cargo >/dev/null 2>&1; then
		log "Using cargo at: $(command -v cargo)"
		return
	fi

	error "Rust installation seems to have failed (cargo not found in PATH)."
	exit 1
}

ensure_git() {
	if ! command -v git >/dev/null 2>&1; then
		error "git is required but not installed. Please install git and rerun."
		exit 1
	fi
}

get_installed_cargo_version() {
	local crate="$1"
	cargo install --list 2>/dev/null |
		awk -v crate="$crate" '$1==crate {print $2}' |
		sed -E 's/^v//; s/:$//' |
		head -n1
}

cargo_np() {
	env -u LD_PRELOAD cargo "$@"
}

latest_git_tag() {
	local repo="$1"
	local pattern="${2:-refs/tags/*}"

	git ls-remote --tags --sort="version:refname" "$repo" "$pattern" 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s#\^{}##' |
		uniq |
		tail -n1
}

install_or_update_arti() {
	local crate="arti"
	local updated=0
	log "Checking $crate version (git tags from $REPO_ARTI)..."

	local installed latest_tag latest_ver
	installed="$(get_installed_cargo_version "$crate" || true)"
	latest_tag="$(latest_git_tag "$REPO_ARTI" 'refs/tags/arti-v*' || true)"

	if [[ -z $latest_tag ]]; then
		error "Could not determine latest arti tag; installing from repo without explicit tag."
		cargo_np install --locked --features=full --git "$REPO_ARTI" "$crate"
		updated=1
	else
		latest_ver="${latest_tag#arti-v}"
		if [[ $installed == "$latest_ver" ]]; then
			log "arti is already at the latest version ($installed, tag $latest_tag). Skipping reinstall."
			updated=0
		else
			log "Installing/updating arti to version $latest_ver (tag $latest_tag) with --features=full..."
			cargo_np install --locked --features=full --git "$REPO_ARTI" --tag "$latest_tag" "$crate"
			updated=1
		fi
	fi

	if [[ $updated -eq 1 ]]; then
		if [[ -x "$CARGO_BIN_DIR/arti" ]]; then
			log "Installing arti binary into /usr/local/bin (may require root)..."
			run_root install -m 0755 "$CARGO_BIN_DIR/arti" /usr/local/bin/
		else
			error "arti binary not found at $CARGO_BIN_DIR/arti. Check previous error messages."
			return 1
		fi
	else
		log "arti already up to date; skipping install to /usr/local/bin."
	fi
}

install_or_update_oniux() {
	ujust set-unconfined-userns off >/dev/null 2>&1 || true
	local crate="oniux"
	local updated=0
	log "Checking $crate version (git tags from $REPO_ONIUX)..."

	local installed latest_tag latest_ver
	installed="$(get_installed_cargo_version "$crate" || true)"
	latest_tag="$(latest_git_tag "$REPO_ONIUX" 'refs/tags/v*' || true)"

	if [[ -z $latest_tag ]]; then
		error "Could not determine latest oniux tag; installing from repo without explicit tag."
		cargo_np install --locked --git "$REPO_ONIUX" "$crate"
		updated=1
	else
		latest_ver="${latest_tag#v}"
		if [[ $installed == "$latest_ver" ]]; then
			log "oniux is already at the latest version ($installed, tag $latest_tag). Skipping reinstall."
			updated=0
		else
			log "Installing/updating oniux to version $latest_ver (tag $latest_tag)..."
			cargo_np install --locked --git "$REPO_ONIUX" --tag "$latest_tag" "$crate"
			updated=1
		fi
	fi

	if [[ $updated -eq 1 ]]; then
		if [[ -x "$CARGO_BIN_DIR/oniux" ]]; then
			log "Installing oniux binary into /usr/local/bin (may require root)..."
			run_root install -m 0755 "$CARGO_BIN_DIR/oniux" /usr/local/bin/
		else
			error "oniux binary not found at $CARGO_BIN_DIR/oniux. Check previous error messages."
			return 1
		fi
	else
		log "oniux already up to date; skipping install to /usr/local/bin."
	fi
}

check_prereqs() {
	detect_root_cmd
	require_cmd install
	require_cmd mkdir
	require_cmd awk
	require_cmd mktemp
	ensure_rust
	ensure_git
}

run_update() {
	mkdir -p "$CARGO_BIN_DIR"
	install_or_update_arti
	install_or_update_oniux
	log "Done. Make sure /usr/local/bin is in your PATH."
}

main() {
	check_prereqs
	run_update
}

main "$@"
