#!/bin/bash
# Install or update the official xerj Debian package.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail
XERJ_USER_PATH=$PATH
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
readonly RELEASES=https://github.com/xerj-org/xerj/releases
readonly TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
readonly DEPENDS_PATTERN='^libc6( \(>= ([0-9]+(\.[0-9]+)+)\))?(, libgcc-s1)?$'
readonly XERJ_BIN=/usr/bin/xerj
VERSION=''
VERIFY_ATTESTATION=0
APT_REFRESHED=0
STAGE=''

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]:-$0}")
CLIENT_HELPER=${SCRIPT_PATH%/*}/xerj-clients
if [[ ! -f $CLIENT_HELPER ]]; then
	CLIENT_HELPER=${SCRIPT_PATH%/*}/../scripts/xerj-clients.bash
fi
# shellcheck source=scripts/xerj-clients.bash
. "$CLIENT_HELPER"

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
}

usage() {
	cat <<'EOF'
Usage: update-xerj [all | AGENT ...] [options]

Install or update xerj on Debian 13 or later via APT.
By default use the release marked Latest by the publisher.

  --version TAG       Use the specified upstream tag.
  --verify-attestation
                      Also require GitHub attestation verification with an
                      authenticated gh that supports release verify-asset.
                      With sudo, use the invoking user's gh configuration.
  -h, --help          Show this help.
EOF
	xerj_client_help
}

parse_args() {
	while (($#)); do
		case "$1" in
		all | --binary-only | opencode | codex | crush | copilot-cli | claude | --opencode | --codex | --crush | --copilot-cli | --claude)
			xerj_select "$1"
			;;
		--version)
			(($# >= 2)) || xerj_usage_error 'Missing value for --version'
			VERSION="v${2#v}"
			[[ $VERSION =~ $TAG_PATTERN ]] || xerj_usage_error 'Invalid release tag'
			shift
			;;
		--url)
			(($# >= 2)) || xerj_usage_error 'Missing value for --url'
			NODE_URL=$2
			XERJ_URL_SELECTED=1
			shift
			;;
		--verify-attestation) VERIFY_ATTESTATION=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*) xerj_usage_error 'Unknown argument' ;;
		esac
		shift
	done
	xerj_validate_selection
}

ensure_debian() {
	[[ -r /etc/os-release ]] || error 'Could not identify the operating system'
	# shellcheck source=/dev/null
	. /etc/os-release
	[[ ${ID:-} == debian && ${VERSION_ID:-} =~ ^([0-9]+)(\.[0-9]+)*$ ]] ||
		error 'Debian 13 or later is required'
	((10#${BASH_REMATCH[1]} >= 13)) || error 'Debian 13 or later is required'
}

refresh_apt() {
	((APT_REFRESHED == 0)) || return 0
	apt-get -o APT::Update::Error-Mode=any update
	APT_REFRESHED=1
}

installed_version() {
	local result
	result=$(dpkg-query -W -f='${Status}\t${Version}' "$1" 2>/dev/null) || return 1
	[[ $result == "install ok installed"$'\t'* ]] || return 1
	printf '%s\n' "${result#*$'\t'}"
}

ensure_download_tools() {
	if ! installed_version curl >/dev/null || ! installed_version ca-certificates >/dev/null; then
		refresh_apt
		apt-get --assume-yes --no-install-recommends --no-remove install curl ca-certificates
	fi
	require_cmd curl
	[[ -s /etc/ssl/certs/ca-certificates.crt ]] || error 'System TLS certificates are unavailable'
}

ensure_archive_tools() {
	# release-verify uses core modules shipped in Debian's perl package.
	if ! installed_version perl >/dev/null; then
		refresh_apt
		apt-get --assume-yes --no-install-recommends --no-remove install perl
	fi
	require_cmd perl
}

release_curl() {
	curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--connect-timeout 15 --max-time 300 "$@"
}

get_latest_tag() {
	local uri tag
	uri=$(release_curl --head --output /dev/null --write-out '%{url_effective}' "$RELEASES/latest") ||
		error 'Could not resolve the latest xerj release'
	tag=${uri#"$RELEASES/tag/"}
	[[ $tag =~ $TAG_PATTERN ]] || error 'Unexpected latest release URL'
	printf '%s\n' "$tag"
}

verify_attestation() {
	local archive=$1 tag=$2
	local gh_path
	gh_path=$(command -v gh) || error 'GitHub CLI is required for attestation verification'
	local -a verifier=("$gh_path")
	if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
		# Allow read-only access to this verified public artifact. Keep control
		# of the directory and package with root while APT will use the file.
		chmod 0711 "$STAGE"
		chmod 0644 "$archive"
		verifier=(sudo -H -u "$SUDO_USER" -- "$gh_path")
	fi
	GH_PROMPT_DISABLED=1 GH_DEBUG='' "${verifier[@]}" release verify-asset \
		-R github.com/xerj-org/xerj "$tag" "$archive" ||
		error 'GitHub release attestation verification failed'
}

download_asset() {
	local archive=$1 tag=$2 digest asset=${1##*/}
	release_curl --max-filesize 536870912 "$RELEASES/download/$tag/$asset" --output "$archive"
	release_curl --max-filesize 65536 "$RELEASES/download/$tag/$asset.sha256" --output "$archive.sha256"
	digest=$(sha256sum <"$archive") || error 'Could not hash the downloaded package'
	digest=${digest%% *}
	[[ $digest =~ ^[0-9a-f]{64}$ ]] || error 'Invalid SHA-256 digest'
	tr -d '\r' <"$archive.sha256" |
		grep -xF -e "$digest  $asset" -e "$digest *$asset" >/dev/null ||
		error 'SHA-256 mismatch'
	if ((VERIFY_ATTESTATION)); then
		verify_attestation "$archive" "$tag"
	fi
}

verify_deb() {
	local archive=$1 arch=$2 version=$3
	[[ $(dpkg-deb -f "$archive" Package) == xerj &&
	$(dpkg-deb -f "$archive" Architecture) == "$arch" &&
	$(dpkg-deb -f "$archive" Version) == "$version" ]] ||
		error 'Unexpected Debian package metadata'
}

native_package_compatible() {
	local package=$1 arch=$2 dependencies installed
	dependencies=$(dpkg-deb -f "$package" Depends) || error 'Could not read package dependencies'
	# Upstream declares libc6 with an optional minimum and optional libgcc-s1.
	# Fail closed if the package's requirements change.
	[[ $dependencies =~ $DEPENDS_PATTERN ]] ||
		error 'Unexpected dependencies in upstream Debian package'
	local floor=${BASH_REMATCH[2]}
	[[ -n $floor ]] || return 0
	installed=$(installed_version "libc6:$arch") || error 'Could not identify the installed libc6 version'
	dpkg --compare-versions "$installed" ge "$floor"
}

build_musl_package() {
	local package=$1 tag=$2 arch=$3 target=$4 version=$5 helper=$6
	local root="$STAGE/package"
	local member basename="xerj-${tag#v}-$target-unknown-linux-musl"
	local archive="$STAGE/$basename.tar.gz" extraction="$STAGE/extract"
	local unpacked="$extraction/$basename"
	ensure_archive_tools
	download_asset "$archive" "$tag"
	mkdir -m 0700 "$extraction"
	perl "$helper" tar-extract-all "$archive" "$extraction" "$basename" 536870912 ||
		error 'Invalid static xerj release archive'
	mkdir -p -- "$root/DEBIAN" "$root/usr/bin" "$root/usr/share/doc/xerj"
	[[ -f $unpacked/xerj && -s $unpacked/xerj ]] || error 'Missing static xerj executable in release archive'
	install -m 0755 "$unpacked/xerj" "$root/usr/bin/xerj"
	for member in LICENSE README.md; do
		[[ -f $unpacked/$member ]] || error "Missing $member in release archive"
		install -m 0644 "$unpacked/$member" "$root/usr/share/doc/xerj/$member"
	done
	cat >"$root/DEBIAN/control" <<EOF
Package: xerj
Version: $version
Architecture: $arch
Maintainer: xerj Contributors <https://github.com/xerj-org/xerj>
Section: net
Priority: optional
Description: xerj search engine (locally packaged upstream static binary)
EOF
	# mktemp protects staging. Package-owned directories must be public.
	chmod 0755 "$root" "$root/DEBIAN" "$root/usr" "$root/usr/bin" \
		"$root/usr/share" "$root/usr/share/doc" "$root/usr/share/doc/xerj"
	chmod 0644 "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$package"
}

verify_install() {
	local version=$1 tag=$2 banner resolved
	[[ $(installed_version xerj) == "$version" ]] || return 1
	# Establish package ownership before invoking the executable as root.
	[[ -x $XERJ_BIN && ! -L $XERJ_BIN ]] || return 1
	resolved=$(dpkg-query -S "$XERJ_BIN") || return 1
	[[ $resolved == "xerj: $XERJ_BIN" ]] || return 1
	banner=$(timeout --kill-after=3s 15s "$XERJ_BIN" --version 2>&1) || return 1
	[[ $banner == "xerj $tag" ]]
}

install_xerj() {
	local arch=$1 target=$2 tag version asset archive installed helper
	tag=${VERSION:-$(get_latest_tag)}
	[[ $tag =~ $TAG_PATTERN ]] || error 'Invalid release tag'
	version=${tag#v}
	# Match upstream's conversion of SemVer prerelease separators to Debian ~.
	if [[ ${version%%+*} == *-* ]]; then
		version="${version%%-*}~${version#*-}"
	fi
	installed=$(installed_version xerj) || installed=''
	if [[ -n $installed ]] && dpkg --compare-versions "$installed" gt "$version"; then
		error "Installed xerj $installed is newer than $version"
	fi
	if ((!VERIFY_ATTESTATION)) && verify_install "$version" "$tag"; then
		log "$tag already installed: $XERJ_BIN"
		return
	fi
	asset="xerj-${tag#v}-$target-unknown-linux-gnu.deb"
	STAGE=$(mktemp -d /tmp/update-xerj.XXXXXX)
	trap 'rm -rf -- "$STAGE"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	archive="$STAGE/$asset"
	download_asset "$archive" "$tag"
	verify_deb "$archive" "$arch" "$version"
	if ! native_package_compatible "$archive" "$arch"; then
		log 'The upstream Debian binary needs a newer libc6. Packaging the official static build.'
		helper="$(readlink -f -- "$0")"
		helper="${helper%/*}/release-verify"
		if [[ ! -f $helper ]]; then
			helper="${helper%/*}/../scripts/release-verify.pl"
		fi
		[[ -f $helper ]] || error 'Could not locate the release-verify helper'
		archive="$STAGE/xerj-static.deb"
		build_musl_package "$archive" "$tag" "$arch" "$target" "$version" "$helper"
		verify_deb "$archive" "$arch" "$version"
	fi
	if verify_install "$version" "$tag"; then
		log "$tag already installed: $XERJ_BIN"
		return
	fi
	refresh_apt
	# --reinstall repairs an installed package with a missing or broken binary.
	# APT still resolves the package's declared shared-library dependencies.
	chmod 0711 "$STAGE"
	chmod 0644 "$archive"
	apt-get --assume-yes --no-install-recommends --no-remove --reinstall install "$archive"
	verify_install "$version" "$tag" || error 'APT completed but xerj failed its version check'
	log "Installed $tag: $XERJ_BIN"
}

main() {
	local arch target
	parse_args "$@"
	ensure_debian
	if ((EUID != 0)); then
		xerj_find_clients || return 1
		require_cmd sudo
		local -a package_args=(--binary-only)
		if [[ -n $VERSION ]]; then package_args+=(--version "$VERSION"); fi
		if ((VERIFY_ATTESTATION)); then package_args+=(--verify-attestation); fi
		sudo -- "$SCRIPT_PATH" "${package_args[@]}"
		if ((${#XERJ_COMMANDS[@]})) && ! installed_version perl >/dev/null; then
			sudo -- /usr/bin/apt-get -o APT::Update::Error-Mode=any update
			sudo -- /usr/bin/apt-get --assume-yes --no-install-recommends --no-remove install perl
		fi
		xerj_configure_clients "$XERJ_BIN"
		return
	fi
	if ((!XERJ_BINARY_ONLY)); then
		error 'Invoke update-xerj as the desktop user for MCP registration or pass --binary-only'
	fi
	require_cmd dpkg
	arch=$(dpkg --print-architecture)
	case "$arch" in
	amd64) target=x86_64 ;;
	arm64) target=aarch64 ;;
	*) error "No official Debian package for $arch" ;;
	esac
	umask 077
	require_cmd apt-get
	require_cmd dpkg-deb
	require_cmd dpkg-query
	require_cmd sha256sum
	require_cmd timeout
	if ((VERIFY_ATTESTATION)); then
		require_cmd gh
		gh release verify-asset --help >/dev/null 2>&1 ||
			error 'GitHub CLI 2.81 or later is required for release attestation verification'
	fi
	ensure_download_tools
	install_xerj "$arch" "$target"
}

main "$@"
