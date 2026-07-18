#!/bin/bash
set -euo pipefail

# SecureBlue arti and oniux update/install script
# Automated script to install or update Rust-based Tor software (arti and oniux)
# - Uses run0 to escalate to root so that Homebrew's Rust binaries are accessible
# - Builds as the invoking user via runuser to preserve their .cargo cache
# - Installs the resulting binaries into /usr/local/bin
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_ARTI="https://gitlab.torproject.org/tpo/core/arti.git"
REPO_ONIUX="https://gitlab.torproject.org/tpo/core/oniux.git"

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
ORIGINAL_USER=""
ORIGINAL_HOME=""
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
		error "Could not determine invoking non-root user. Run this script via run0 from your user account."
		exit 1
	fi

	ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)"
	if [[ -z ${ORIGINAL_HOME:-} ]]; then
		error "Could not determine home directory for user '$ORIGINAL_USER'."
		exit 1
	fi
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
		"PATH=${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:/usr/local/bin:/usr/bin:/bin"
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

cargo_np() {
	run_as_user_env "$ORIGINAL_USER" env -u LD_PRELOAD cargo "$@"
}

ensure_rust() {
	if run_as_user_env "$ORIGINAL_USER" command -v cargo >/dev/null 2>&1; then
		log "Rust toolchain available."
		return
	fi

	error "Cargo not available for user '$ORIGINAL_USER' with PATH=${BREW_PREFIX}/bin."
	error "Ensure Rust is installed via Homebrew (brew-proxy install rust)."
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
	cargo_np install --list 2>/dev/null |
		awk -v crate="$crate" '$1==crate {print $2}' |
		sed -E 's/^v//; s/:$//' |
		head -n1
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
	local cargo_bin_dir="${ORIGINAL_HOME}/.cargo/bin"
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
		if [[ -x "$cargo_bin_dir/arti" ]]; then
			log "Installing arti binary into /usr/local/bin..."
			install -m 0755 "$cargo_bin_dir/arti" /usr/local/bin/
		else
			error "arti binary not found at $cargo_bin_dir/arti. Check previous error messages."
			return 1
		fi
	else
		log "arti already up to date; skipping install to /usr/local/bin."
	fi
}

install_or_update_oniux() {
	local crate="oniux"
	local updated=0
	local cargo_bin_dir="${ORIGINAL_HOME}/.cargo/bin"
	ujust set-unconfined-userns off >/dev/null 2>&1 || true
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
		if [[ -x "$cargo_bin_dir/oniux" ]]; then
			log "Installing oniux binary into /usr/local/bin..."
			install -m 0755 "$cargo_bin_dir/oniux" /usr/local/bin/
		else
			error "oniux binary not found at $cargo_bin_dir/oniux. Check previous error messages."
			return 1
		fi
	else
		log "oniux already up to date; skipping install to /usr/local/bin."
	fi
}

check_prereqs() {
	require_cmd runuser
	require_cmd install
	require_cmd mkdir
	require_cmd awk
	require_cmd mktemp
	ensure_rust
	ensure_git
}

run_update() {
	install_or_update_arti
	install_or_update_oniux
	log "Done. arti and oniux are installed in /usr/local/bin."
}

main() {
	ensure_root "$@"
	init_context
	check_prereqs
	run_update
}

main "$@"
