#!/bin/bash
set -euo pipefail

# Hardened malloc global install/update script for Debian 13
# Downloads, builds and globally installs
# hardened_malloc from GrapheneOS,
# both the default (maximum security) and light (balanced) variants.
# Configures /etc/ld.so.preload for global preloading.
#
# Supports amd64 (x86_64) and arm64 (aarch64).
#
# Requirements: Debian 13 (ID=debian, VERSION_ID=13), root privileges,
# network access, git, gmake, install, uname, and nproc. Missing build
# dependencies (git, clang, make, build-essential) are installed through
# apt.
#
# Side effects:
#  - Clones or updates the source under $HOME/.local/src/hardened_malloc
#    and checks out the latest version tag
#  - Installs both variants into /usr/local/lib
#  - Writes /etc/sysctl.d/80-hardened_malloc.conf and applies it
#  - Runs ldconfig
#  - Backs up /etc/ld.so.preload when present, then rewrites it to
#    preload the default variant globally
#  - Records the installed tag in /usr/local/lib/.hardened_malloc_version
#
# The preload applies to every dynamically linked program after a
# reboot or new process start. When /etc/ld.so.preload already exists,
# it is backed up as /etc/ld.so.preload.bak.<timestamp>. This is an
# install or update script; it does not provide an uninstall path.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO_URL="https://github.com/GrapheneOS/hardened_malloc.git"
BUILD_DIR="${HOME}/.local/src/hardened_malloc"
INSTALL_DIR="/usr/local/lib"
PRELOAD_CONF="/etc/ld.so.preload"
SYSCTL_CONF="/etc/sysctl.d/80-hardened_malloc.conf"
VERSION_FILE="${INSTALL_DIR}/.hardened_malloc_version"

# Which variant to preload globally by default
DEFAULT_PRELOAD_VARIANT="default"

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || error "Run as root (sudo $0)"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		error "Required command '$1' not found."
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# Accept exactly Debian 13; derivative IDs and other releases are
# rejected even if they provide the same toolchain.
ensure_debian13() {
	if [ -f /etc/os-release ]; then
		# shellcheck source=/dev/null
		. /etc/os-release
		case "${ID:-}:${VERSION_ID:-}" in
		debian:13) return 0 ;;
		esac
	fi
	error "This script targets Debian 13" \
		"(ID=${ID:-} VERSION_ID=${VERSION_ID:-})"
}

# Validate the machine type and print its canonical name. The build
# itself uses the native compiler, so this only acts as a guard and a
# log value.
detect_arch() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
	x86_64) echo "x86_64" ;;
	aarch64) echo "aarch64" ;;
	*) error "Unsupported architecture: $arch" \
		"(only amd64/x86_64 and arm64/aarch64" \
		"are supported)" ;;
	esac
}

# Collect packages that are not installed (regardless of version) and
# install only those. When all four are present, apt is not invoked.
install_build_deps() {
	local missing=()
	for pkg in git clang make build-essential; do
		if ! dpkg -s "$pkg" >/dev/null 2>&1; then
			missing+=("$pkg")
		fi
	done

	if [ "${#missing[@]}" -eq 0 ]; then
		return
	fi

	log "Installing build dependencies: ${missing[*]}"
	apt-get update -qq
	apt-get install -y -qq "${missing[@]}"
}

# Use a version-aware tag sort and take the last entry, after stripping
# peeled-tag (^{}) suffixes. Prints nothing if the remote cannot be read.
get_latest_tag() {
	git ls-remote --tags \
		--sort='version:refname' \
		"$REPO_URL" 'refs/tags/[0-9]*' \
		2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s#\^{}##' |
		uniq |
		tail -n1
}

get_installed_version() {
	if [ -f "$VERSION_FILE" ]; then
		cat "$VERSION_FILE"
	fi
}

# Clone the repository on first use, then always fetch tags and check
# out the requested tag, leaving the work tree in detached HEAD state.
clone_or_update_repo() {
	local latest_tag="$1"
	mkdir -p "$(dirname "$BUILD_DIR")"

	if [ ! -d "$BUILD_DIR/.git" ]; then
		log "Cloning hardened_malloc repository..."
		git clone --quiet "$REPO_URL" "$BUILD_DIR"
	fi

	cd "$BUILD_DIR"
	log "Fetching tags..."
	git fetch --quiet --tags --prune origin

	log "Checking out tag $latest_tag..."
	git checkout --quiet "tags/$latest_tag"
}

# Build one variant with upstream's gmake targets. "default" uses the
# plain target and "light" passes VARIANT=light; each writes to a
# distinct output directory and library name.
build_variant() {
	local variant="$1"
	local so_name out_dir

	if [ "$variant" = "default" ]; then
		out_dir="out"
		so_name="libhardened_malloc.so"
		log "Building default variant (maximum security)..."
	else
		out_dir="out-$variant"
		so_name="libhardened_malloc-$variant.so"
		log "Building light variant (balanced)..."
	fi

	if [ "$variant" = "default" ]; then
		gmake -j"$(nproc)"
	else
		gmake "VARIANT=$variant" -j"$(nproc)"
	fi

	if [ ! -f "$out_dir/$so_name" ]; then
		error "Build failed: $out_dir/$so_name not found"
	fi

	log "Built $out_dir/$so_name"
}

install_variant() {
	local variant="$1"
	local so_name out_dir

	if [ "$variant" = "default" ]; then
		out_dir="out"
		so_name="libhardened_malloc.so"
	else
		out_dir="out-$variant"
		so_name="libhardened_malloc-$variant.so"
	fi

	log "Installing $so_name to $INSTALL_DIR/"
	install -m 0755 "$out_dir/$so_name" "$INSTALL_DIR/"
}

# Set the global preload entry. Any existing line mentioning
# hardened_malloc is removed first, so switching variants does not leave
# two libraries loaded, and a missing final newline is repaired before
# appending. When the file exists, it is backed up before the rewrite.
configure_preload() {
	local variant="${1:-$DEFAULT_PRELOAD_VARIANT}"
	local so_name so_path

	if [ "$variant" = "default" ]; then
		so_name="libhardened_malloc.so"
	else
		so_name="libhardened_malloc-$variant.so"
	fi

	so_path="${INSTALL_DIR}/${so_name}"

	log "Configuring global preload ($variant variant) in $PRELOAD_CONF..."

	# Remove any existing hardened_malloc entries, keeping unrelated
	# lines and blank lines intact. Back up the loader configuration
	# before the first modification in this run.
	if [ -f "$PRELOAD_CONF" ]; then
		backup="${PRELOAD_CONF}.bak.$(date '+%Y%m%d%H%M%S')"
		cp -a "$PRELOAD_CONF" "$backup" ||
			error "Cannot back up $PRELOAD_CONF to $backup."
		sed -i "\|hardened_malloc|d" "$PRELOAD_CONF"
		# Avoid concatenating the new entry with an unterminated line.
		if [ -n "$(tail -c 1 "$PRELOAD_CONF")" ]; then
			printf '\n' >>"$PRELOAD_CONF"
		fi
	fi

	printf '%s\n' "$so_path" >>"$PRELOAD_CONF"

	log "Preload configured: $so_path"
}

# Raise vm.max_map_count persistently and apply it immediately. The
# configuration file is overwritten on each run.
configure_sysctl() {
	log "Configuring vm.max_map_count for hardened_malloc..."
	cat >"$SYSCTL_CONF" <<'EOF'
# Increased max map count for hardened_malloc guard slabs.
# hardened_malloc creates many PROT_NONE guard mappings between slabs;
# the default 65530 is too low and will cause mmap failures.
vm.max_map_count = 1048576
EOF

	log "Applying sysctl..."
	sysctl -p "$SYSCTL_CONF" >/dev/null
	log "vm.max_map_count set to 1048576 (persistent via $SYSCTL_CONF)"
}

save_version() {
	local version="$1"
	printf '%s\n' "$version" >"$VERSION_FILE"
	log "Saved installed version: $version"
}

run_ldconfig() {
	log "Running ldconfig..."
	ldconfig
	log "ldconfig complete."
}

show_post_install_info() {
	local variant="${1:-$DEFAULT_PRELOAD_VARIANT}"
	local so_name so_path

	if [ "$variant" = "default" ]; then
		so_name="libhardened_malloc.so"
	else
		so_name="libhardened_malloc-$variant.so"
	fi
	so_path="${INSTALL_DIR}/${so_name}"

	cat <<EOF

=== hardened_malloc installed ===

  Variants installed: default + light
  Default variant:     ${INSTALL_DIR}/libhardened_malloc.so
  Light variant:       ${INSTALL_DIR}/libhardened_malloc-light.so
  Active preload:      ${so_path}
  Preload config:      ${PRELOAD_CONF}
  Sysctl config:       ${SYSCTL_CONF}

  To switch to the default (maximum security) variant:
    sed -i '\|hardened_malloc-light|d' ${PRELOAD_CONF}
    echo '${INSTALL_DIR}/libhardened_malloc.so' >> ${PRELOAD_CONF}

  To switch to the light (balanced) variant:
    sed -i '\|hardened_malloc.so|d' ${PRELOAD_CONF}
    echo '${INSTALL_DIR}/libhardened_malloc-light.so' >> ${PRELOAD_CONF}

  To temporarily disable global preloading (e.g. for a build):
    env -u LD_PRELOAD make

  A reboot is recommended to fully apply the preload to all processes.
EOF
}

check_prereqs() {
	require_root
	require_cmd git
	require_cmd gmake
	require_cmd install
	require_cmd uname
	require_cmd nproc
}

# Skip the work when the recorded tag matches the latest tag and both
# libraries are present. Otherwise rebuild both variants and refresh
# the loader and sysctl configuration.
main() {
	local arch installed_version latest_tag

	arch="$(detect_arch)"
	log "Detected architecture: $arch"

	ensure_debian13
	require_root
	install_build_deps
	check_prereqs

	log "Checking latest hardened_malloc release..."
	latest_tag="$(get_latest_tag)"
	[ -n "$latest_tag" ] ||
		error "Could not determine" \
			"latest hardened_malloc tag"
	log "Latest release tag: $latest_tag"

	installed_version="$(get_installed_version || true)"

	if [ "$installed_version" = "$latest_tag" ] &&
		[ -f "${INSTALL_DIR}/libhardened_malloc.so" ] &&
		[ -f "${INSTALL_DIR}/libhardened_malloc-light.so" ]; then
		log "hardened_malloc $latest_tag is already installed. Nothing to do."
		show_post_install_info
		exit 0
	fi

	clone_or_update_repo "$latest_tag"
	cd "$BUILD_DIR"

	build_variant "default"
	build_variant "light"

	install_variant "default"
	install_variant "light"

	configure_sysctl
	run_ldconfig
	configure_preload "$DEFAULT_PRELOAD_VARIANT"

	save_version "$latest_tag"

	show_post_install_info
}

main "$@"
