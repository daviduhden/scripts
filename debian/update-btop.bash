#!/bin/bash

set -euo pipefail

# Debian btop++ build/install script
# Builds and installs the latest btop++ from source
# on Debian-based systems.
# - Fetches the latest release tag from GitHub
# - Installs build dependencies if missing
# - Clones the repo at that tag, builds, and installs
#
# Requirements: root privileges, network access, git, make, cmake, and
# nproc. Build dependencies (git, build-essential, cmake,
# libncurses-dev) are requested through APT when needed.
#
# Side effects:
#  - Clones and builds the source in disposable staging as nobody
#  - Publishes selected files under /usr/local
#
# The build runs with LD_PRELOAD unset, so a globally preloaded
# allocator such as hardened_malloc does not affect the build tools.
# If the clone fails, a release tarball is downloaded instead. When the
# installed version already matches the latest tag, the source fetch,
# build, and install are skipped.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
PERL_CMD=/usr/bin/perl
SCRIPT_DIR=${SCRIPT_PATH%/*}
RELEASE_HELPER=""
if [ -z "$RELEASE_HELPER" ]; then
	RELEASE_HELPER=""
	for candidate in "$SCRIPT_DIR/release-verify.pl" "$SCRIPT_DIR/release-verify" "$SCRIPT_DIR/../scripts/release-verify.pl"; do
		if [ -f "$candidate" ]; then
			RELEASE_HELPER="$candidate"
			break
		fi
	done
fi

BUILD_DIR=
BUILD_STAGE=
BUILD_USER=nobody
REPO="aristocratos/btop"
REPO_URL="https://github.com/${REPO}.git"
INSTALL_PREFIX="/usr/local"

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*" >&2; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
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
	runuser -u "$BUILD_USER" -- env -i HOME="${BUILD_DIR:-/nonexistent}" PATH="$PATH" "$@"
}

prepare_build() {
	[[ $(id -u "$BUILD_USER") != 0 ]] || error 'An unprivileged build account is required.'
	BUILD_STAGE=$(mktemp -d /tmp/btop-build.XXXXXX)
	trap 'rm -rf -- "$BUILD_STAGE"' EXIT
	chmod 0711 "$BUILD_STAGE"
	BUILD_DIR=$BUILD_STAGE/work
	install -d -m 0700 -o "$BUILD_USER" "$BUILD_DIR"
	install -m 0644 "$RELEASE_HELPER" "$BUILD_STAGE/release-verify"
}

# Resolve the highest release tag with git. --refs drops peeled-tag
# entries, and sort -Vr handles version ordering.
get_latest_tag() {
	# Use git only
	local tag
	tag="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s/\^{}//' |
		grep -E '^v?[0-9]+(\.[0-9]+)*$' |
		sort -Vr |
		sed -n '1p')"
	[[ -n $tag ]] && printf '%s\n' "$tag"
}

# Extract the first semantic version from btop --version and strip a
# leading "v". Prints nothing when btop is not installed.
get_current_version() {
	local executable
	if executable=$(type -P btop); then
		run_build "$executable" --version 2>/dev/null | awk \
			'match($0,/v?[0-9]+\.[0-9]+\.[0-9]+/){
				ver=substr($0,RSTART,RLENGTH);
				sub(/^v/,"",ver);
				print ver;
				exit}'
	fi
}

# Prefer apt-get, falling back to apt.
install_build_deps() {
	local apt_cmd
	if command -v apt-get >/dev/null 2>&1; then
		apt_cmd="apt-get"
	elif command -v apt >/dev/null 2>&1; then
		apt_cmd="apt"
	else
		error "Neither 'apt-get' nor 'apt' is available."
	fi

	log "Installing build dependencies" \
		"(git build-essential cmake libncurses-dev)..."
	"$apt_cmd" update
	"$apt_cmd" install -y --no-remove git build-essential cmake libncurses-dev
}

# Fetch a tagged source tree into the disposable build directory and
# print the selected source path.
fetch_source() {
	local tag="$1" dest="$2" src_dir=""
	log "Cloning btop tag ${tag} with git..."
	if run_build git clone --depth 1 --branch "$tag" "$REPO_URL" "$dest/btop"; then
		src_dir="$dest/btop"
		printf '%s\n' "$src_dir"
		return 0
	fi

	# Fallback to tarball download
	local tarball_url="https://github.com/${REPO}"
	tarball_url="${tarball_url}/archive/refs/tags/${tag}.tar.gz"
	local tarball="$dest/btop.tar.gz"
	log "Git clone failed, downloading tarball ${tarball_url}..."
	run_build curl -q -fLsS --retry 5 --proto '=https' --proto-redir '=https' "$tarball_url" -o "$tarball" || return 1
	# Extract into a unique tree, with exact root and no archive links/devices.
	local unpack listing
	unpack=$(run_build mktemp -d "$dest/btop-source.XXXXXX") || return 1
	listing=$(run_build tar -tzf "$tarball") || {
		rm -rf -- "$unpack"
		return 1
	}
	if printf '%s\n' "$listing" |
		grep -Eq '(^|/)\.\.(/|$)|^/' ||
		[ -n "$(printf '%s\n' "$listing" | sort | uniq -d)" ] ||
		! run_build tar -tvzf "$tarball" | awk '$1 !~ /^[d-]/ { exit 1 }'; then
		rm -rf -- "$unpack"
		return 1
	fi
	if ! run_build "$PERL_CMD" "$BUILD_STAGE/release-verify" tar-extract-all \
		"$tarball" "$unpack" "btop-${tag#v}" 536870912; then
		rm -rf -- "$unpack"
		return 1
	fi
	src_dir="$unpack/btop-${tag#v}"
	if [[ ! -d $src_dir ]]; then
		rm -rf -- "$unpack"
		return 1
	fi
	printf '%s\n' "$src_dir"
}

# Build with all available cores and install under /usr/local. The
# build runs with LD_PRELOAD unset to keep a global preload out of the
# compiler and build tooling.
build_and_install() {
	local tag="$1"
	local src_dir

	src_dir="$(fetch_source "$tag" "$BUILD_DIR")" ||
		error "Could not fetch source."
	cd "$src_dir"

	log "Building btop..."
	run_build make -j"$(nproc)"

	log "Installing btop..."
	local image=$BUILD_DIR/image file theme
	run_build make PREFIX="$INSTALL_PREFIX" DESTDIR="$image" install
	image+=$INSTALL_PREFIX
	for theme in "$image"/share/btop/themes/*.theme; do
		[[ -f $theme && ! -L $theme ]] || continue
		publish_file "$theme" "$INSTALL_PREFIX/share/btop/themes/${theme##*/}" 0644
	done
	for file in share/doc/btop/README.md share/applications/btop.desktop \
		share/icons/hicolor/48x48/apps/btop.png share/icons/hicolor/scalable/apps/btop.svg \
		share/man/man1/btop.1; do
		if [[ $file == share/man/man1/btop.1 && ! -f $image/$file ]]; then
			continue
		fi
		publish_file "$image/$file" "$INSTALL_PREFIX/$file" 0644
	done
	publish_file "$image/bin/btop" "$INSTALL_PREFIX/bin/btop" 0755

	log "btop ${tag} installed successfully."
}

publish_file() {
	local source=$1 target=$2 mode=$3 stage
	[[ -f $source && ! -L $source ]] || error "Missing regular build output: $source"
	install -d -- "${target%/*}"
	stage=$(mktemp "${target%/*}/.btop.XXXXXX")
	if ! run_build cat -- "$source" >"$stage" ||
		! chmod "$mode" "$stage" || ! mv -fT -- "$stage" "$target"; then
		rm -f -- "$stage"
		error "Cannot publish $target."
	fi
}

check_prereqs() {
	require_root
	require_cmd git
	require_cmd make
	require_cmd cmake
	require_cmd "$PERL_CMD"
	require_cmd tar
	require_cmd mktemp
	require_cmd runuser
	[ -f "$RELEASE_HELPER" ] ||
		error "release-verify helper not found: $RELEASE_HELPER"
}

resolve_latest_tag() {
	local latest_tag

	log "Fetching latest btop release tag..."
	latest_tag="$(get_latest_tag || true)"
	[[ -n $latest_tag ]] || error "Could not determine latest release tag."
	printf '%s\n' "$latest_tag"
}

# Compare the installed version with the tag, accepting either the raw
# tag or the tag without its leading "v". Returns 0 when no build is
# needed.
is_up_to_date() {
	local latest_tag="$1"
	local latest_stripped current

	latest_stripped="${latest_tag#v}"
	current="$(get_current_version || true)"
	if [[ -n $current ]]; then
		log "Currently installed btop version: ${current}"
		if [[ $current == "$latest_stripped" ||
			$current == "$latest_tag" ]]; then
			log "btop is already up to date. Nothing to do."
			return 0
		fi
	else
		log "btop is not currently installed."
	fi

	return 1
}

main() {
	local latest_tag
	require_root
	require_cmd runuser
	# A current installation should not trigger an APT update/install pass.
	if ! command -v git >/dev/null 2>&1; then
		install_build_deps
	fi
	require_cmd git
	latest_tag="$(resolve_latest_tag)"
	if is_up_to_date "$latest_tag"; then
		exit 0
	fi
	install_build_deps
	check_prereqs
	prepare_build
	build_and_install "$latest_tag"
}

main "$@"
