#!/bin/bash
set -euo pipefail

# SecureBlue Krohnkite build and install helper.
#
# Builds the latest Krohnkite KWin script from a user-local checkout and
# installs it into the current user's KDE configuration. It does not need root:
# kpackagetool6 writes to the user's package directory.
#
# The checkout lives in ~/.local/src/Krohnkite. On each run it is fetched and
# hard-reset to origin/HEAD, so local modifications in that checkout are
# discarded. If the checkout is already current and the package is installed,
# nothing is rebuilt. Otherwise the script runs `task package` (go-task) and
# installs or upgrades builds/*.kwinscript with kpackagetool6.
#
# Requires git, 7z, go-task, and kpackagetool6. Build commands use the standard
# allocator to avoid hardened_malloc issues. KWin must be restarted or the
# session restarted before a new version is loaded.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

REPO_URL="https://codeberg.org/anametologin/Krohnkite.git"
BUILD_DIR_NAME="builds"
SRC_DIR="$HOME/.local/src/Krohnkite"
REPO_UNCHANGED=0

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
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

prepare_repo() {
	mkdir -p "$(dirname "$SRC_DIR")"

	if [[ -d "$SRC_DIR/.git" ]]; then
		log "Checking Krohnkite repository status..."
		git -C "$SRC_DIR" fetch --quiet
		local local_rev remote_rev
		local_rev="$(git -C "$SRC_DIR" rev-parse HEAD)"
		remote_rev="$(git -C "$SRC_DIR" rev-parse origin/HEAD)"

		if [[ $local_rev == "$remote_rev" ]]; then
			log "Repository already up to date."
			REPO_UNCHANGED=1
			return 0
		fi

		log "Repository updated upstream; syncing..."
		# This is intentionally destructive: the build tree is treated as a
		# disposable checkout, not a development working copy.
		git -C "$SRC_DIR" reset --hard origin/HEAD
	else
		log "Cloning Krohnkite repository into $SRC_DIR..."
		git clone "$REPO_URL" "$SRC_DIR"
	fi
}

# go-task is the upstream build entry point; its `package` task writes the
# installable archive under the repository's builds/ directory.
build_krohnkite() {
	log "Building Krohnkite using task..."

	ensure_brew_path

	cd "$SRC_DIR"
	if ! run_build task package; then
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

	# -s queries the installed package; use -u only when it already exists.
	if kpackagetool6 -t KWin/Script -s krohnkite >/dev/null 2>&1; then
		log "Upgrading Krohnkite..."
		kpackagetool6 -t KWin/Script -u "$pkg"
	else
		log "Installing Krohnkite..."
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

	# Nothing to build if the source is current, but still install when the
	# KWin script is missing (for example after a failed earlier install).
	if [[ $REPO_UNCHANGED -eq 1 ]] &&
		kpackagetool6 -t KWin/Script -s krohnkite >/dev/null 2>&1; then
		log "Krohnkite is already up to date. Nothing to do."
		return 0
	fi

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
