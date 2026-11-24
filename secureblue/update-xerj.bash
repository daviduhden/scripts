#!/bin/bash
# SecureBlue xerj install/update helper.
#
# Installs a checksum-verified static release into ~/.local/bin without root.
# Registers stdio MCP with installed or explicitly selected clients.
# The engine must be started separately; no service is installed or started.
# Requires curl, Perl with core modules, sha256sum, and standard GNU utilities.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
set -euo pipefail
XERJ_USER_PATH=$PATH
export PATH=/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin
PERL_CMD="${PERL_CMD:-perl}"
SCRIPT_PATH=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]:-$0}")
SCRIPT_DIR=${SCRIPT_PATH%/*}
RELEASE_HELPER="${RELEASE_HELPER:-}"
if [ -z "$RELEASE_HELPER" ]; then
	RELEASE_HELPER=""
	for candidate in "$SCRIPT_DIR/release-verify.pl" "$SCRIPT_DIR/release-verify" "$SCRIPT_DIR/../scripts/release-verify.pl"; do
		if [ -f "$candidate" ]; then
			RELEASE_HELPER="$candidate"
			break
		fi
	done
fi
CLIENT_HELPER=$SCRIPT_DIR/xerj-clients
if [[ ! -f $CLIENT_HELPER ]]; then
	CLIENT_HELPER=$SCRIPT_DIR/../scripts/xerj-clients.bash
fi
# shellcheck source=scripts/xerj-clients.bash
. "$CLIENT_HELPER"
TMP_DIR=''
BINARY_STAGE=''
VERSION=''
EXPECTED_TAG=''

log() {
	printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found."
}

usage() {
	cat <<'EOF'
Usage: update-xerj [all | AGENT ...] [options]

Install or update xerj in ~/.local/bin without elevation.

Options:
  -h, --help       Show this help and exit
      --version TAG
                   Install a specific release (default: latest)
EOF
	xerj_client_help
}

parse_args() {
	while (($#)); do
		case "$1" in
		all | --binary-only | opencode | codex | crush | copilot-cli | claude | swival | --opencode | --codex | --crush | --copilot-cli | --claude | --swival)
			xerj_select "$1"
			shift
			;;
		--version | --url)
			(($# >= 2)) || xerj_usage_error "Missing value for $1"
			case "$1" in
			--version)
				VERSION="$2"
				[[ v${VERSION#v} =~ ^v[0-9][A-Za-z0-9.+-]*$ ]] || xerj_usage_error 'Invalid release tag'
				;;
			--url)
				NODE_URL="$2"
				XERJ_URL_SELECTED=1
				;;
			esac
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		*) xerj_usage_error 'Unknown argument' ;;
		esac
	done
	xerj_validate_selection
}

install_xerj() {
	local arch tag asset base digest client release_url banner max_size
	local version="$VERSION"
	local binary="$HOME/.local/bin/xerj"
	case "$(uname -m)" in
	x86_64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) error 'Unsupported architecture' ;;
	esac
	if [[ -z $version ]]; then
		# Follow the public redirect without consuming the shared GitHub API quota.
		release_url=$(curl --disable --fail --silent --show-error --head --location \
			--connect-timeout 15 --max-time 60 \
			--proto '=https' --proto-redir '=https' --output /dev/null \
			--write-out '%{url_effective}' \
			https://github.com/xerj-org/xerj/releases/latest) ||
			error 'Could not resolve the latest xerj release; retry or use --version TAG'
		[[ $release_url =~ ^https://github\.com/xerj-org/xerj/releases/tag/(v[0-9][A-Za-z0-9.+-]*)$ ]] ||
			error 'Unexpected latest release URL; retry or use --version TAG'
		version="${BASH_REMATCH[1]}"
	fi
	tag="v${version#v}"
	[[ $tag =~ ^v[0-9][A-Za-z0-9.+-]*$ ]] || error 'Invalid release tag'
	EXPECTED_TAG=$tag
	asset="xerj-${tag#v}-${arch}-unknown-linux-musl.tar.gz"
	base="https://github.com/xerj-org/xerj/releases/download/$tag"
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/update-xerj.XXXXXX")
	trap 'if [[ -n $BINARY_STAGE ]]; then rm -f -- "$BINARY_STAGE"; fi; if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	for client in "$asset" "$asset.sha256"; do
		max_size=536870912
		if [[ $client == *.sha256 ]]; then
			max_size=65536
		fi
		curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--connect-timeout 15 --max-time 300 --max-filesize "$max_size" \
			"$base/$client" -o "$TMP_DIR/$client"
	done
	digest=$(sha256sum "$TMP_DIR/$asset")
	digest=${digest%% *}
	[[ $digest =~ ^[0-9a-f]{64}$ ]] || error 'Invalid SHA-256 digest'
	tr -d '\r' <"$TMP_DIR/$asset.sha256" | grep -xF -e "$digest  $asset" -e "$digest *$asset" >/dev/null || error 'SHA-256 mismatch'
	# Extract only the expected regular binary, never archive paths or links.
	"$PERL_CMD" "$RELEASE_HELPER" tar-extract-entry \
		"$TMP_DIR/$asset" "$TMP_DIR/xerj" "${asset%.tar.gz}/xerj" \
		536870912 || error 'Invalid release archive'
	mkdir -p -- "${binary%/*}"
	[[ -s $TMP_DIR/xerj ]] || error 'Empty release executable'
	[[ ! -L $binary && (! -e $binary || -f $binary) ]] ||
		error 'Refusing to replace a symlink or non-regular executable'
	BINARY_STAGE=$(mktemp "${binary}.new.XXXXXX")
	install -m 0755 "$TMP_DIR/xerj" "$BINARY_STAGE"
	if ! banner=$(cd "$TMP_DIR" && timeout --kill-after=3s 15s "$BINARY_STAGE" --version) ||
		[[ $banner != "xerj $tag" ]]; then
		error 'Staged executable failed its version check'
	fi
	if [[ -x $binary ]] && cmp -s -- "$BINARY_STAGE" "$binary"; then
		log "$tag already installed: $binary"
		return
	fi
	mv -fT -- "$BINARY_STAGE" "$binary"
	BINARY_STAGE=''
	log "Installed $tag: $binary"
}

main() {
	local client lock_fd banner status=0
	local bin_dir="$HOME/.local/bin"
	parse_args "$@"
	[[ $EUID -ne 0 ]] || error 'Run as the desktop user, without run0.'
	xerj_find_clients || return 1
	umask 077
	for client in curl "$PERL_CMD" sha256sum cmp install timeout flock; do
		require_cmd "$client"
	done
	[ -f "$RELEASE_HELPER" ] ||
		error "release-verify helper not found: $RELEASE_HELPER"
	mkdir -p -- "$bin_dir"
	[[ ! -L $bin_dir && -O $bin_dir ]] || error 'Unsafe xerj installation directory'
	exec {lock_fd}<"$bin_dir"
	flock -w 600 "$lock_fd" || error 'Another xerj update is still running'
	install_xerj
	xerj_configure_clients "$bin_dir/xerj" || status=$?
	banner=$(timeout --kill-after=3s 15s "$bin_dir/xerj" --version) ||
		error 'Cannot verify the installed xerj executable'
	[[ $banner == "xerj $EXPECTED_TAG" ]] || error 'Installed xerj version did not match the selected release'
	log "Verified $EXPECTED_TAG: $bin_dir/xerj"
	return "$status"
}

main "$@"
