#!/bin/bash
# SecureBlue xerj install/update helper.
#
# Installs a checksum-verified static release into ~/.local/bin without root.
# Optional client flags register stdio MCP with Codex, Crush, or OpenCode.
# The engine must be started separately; no service is installed or started.
# Requires curl, Perl with core modules, sha256sum, and standard GNU utilities.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
set -euo pipefail
export PATH="${HOME}/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
PERL_CMD="${PERL_CMD:-perl}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
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
XERJ_HELPER="${XERJ_HELPER:-}"
if [ -z "$XERJ_HELPER" ]; then
	XERJ_HELPER="${SCRIPT_DIR}/xerj-config.pl"
	[ -f "$XERJ_HELPER" ] || XERJ_HELPER="${SCRIPT_DIR}/xerj-config"
fi
TMP_DIR=''
BINARY_STAGE=''
VERSION=''
NODE_URL='http://127.0.0.1:9200'
CLIENTS=()

log() {
	printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
Usage: update-xerj.bash [options]

Install or update xerj in ~/.local/bin without elevation.

Options:
  -h, --help       Show this help and exit
      --version TAG
                   Install a specific release (default: latest)
      --codex      Register xerj MCP with installed Codex
      --crush      Register xerj MCP in the global crushrc
      --opencode   Register xerj MCP in global opencode.json
      --url URL    ES-compatible endpoint (default: http://127.0.0.1:9200)

Client flags may be combined. MCP needs a separately running node.
EOF
}

parse_args() {
	while (($#)); do
		case "$1" in
		--codex | --crush | --opencode)
			CLIENTS+=("${1#--}")
			shift
			;;
		--version | --url)
			(($# >= 2)) || error "Missing value for $1"
			case "$1" in
			--version) VERSION="$2" ;;
			--url) NODE_URL="$2" ;;
			esac
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		*) error "Unknown option: $1" ;;
		esac
	done
}

install_xerj() {
	local arch tag asset base digest client
	local version="$VERSION"
	local binary="$HOME/.local/bin/xerj"
	case "$(uname -m)" in
	x86_64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) error 'Unsupported architecture' ;;
	esac
	if [[ -z $version ]]; then
		version=$(curl --fail --silent --show-error --location --proto '=https' \
			https://api.github.com/repos/xerj-org/xerj/releases/latest |
			"$PERL_CMD" "$RELEASE_HELPER" json-tag)
	fi
	tag="v${version#v}"
	[[ $tag =~ ^v[0-9][A-Za-z0-9.+-]*$ ]] || error 'Invalid release tag'
	asset="xerj-${tag#v}-${arch}-unknown-linux-musl.tar.gz"
	base="https://github.com/xerj-org/xerj/releases/download/$tag"
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/update-xerj.XXXXXX")
	trap 'if [[ -n $BINARY_STAGE ]]; then rm -f -- "$BINARY_STAGE"; fi; if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi' EXIT
	for client in "$asset" "$asset.sha256"; do
		curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
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
	BINARY_STAGE=$(mktemp "${binary}.new.XXXXXX")
	install -m 0755 "$TMP_DIR/xerj" "$BINARY_STAGE"
	mv -f -- "$BINARY_STAGE" "$binary"
	BINARY_STAGE=''
	log "Installed $tag: $binary"
}

configure_clients() {
	local client config
	local binary="$HOME/.local/bin/xerj"
	local url="$NODE_URL"
	for client in "${CLIENTS[@]}"; do
		if [[ $client == codex ]]; then
			config="${CODEX_HOME:-$HOME/.codex}/config.toml"
			if [[ -f $config ]]; then cp -p -- "$config" "$config.bak.$(date +%s%N)"; fi
			codex mcp add xerj -- "$binary" mcp --url "$url"
		else
			"$PERL_CMD" "$XERJ_HELPER" "$client" "$binary" "$url"
		fi
	done
}

main() {
	local client
	parse_args "$@"
	[[ $EUID -ne 0 ]] || error 'Run as the desktop user, without run0.'
	for client in curl "$PERL_CMD" sha256sum install; do
		require_cmd "$client"
	done
	[ -f "$RELEASE_HELPER" ] ||
		error "release-verify helper not found: $RELEASE_HELPER"
	[ -f "$XERJ_HELPER" ] ||
		error "xerj-config helper not found: $XERJ_HELPER"
	for client in "${CLIENTS[@]}"; do
		if [[ $client == codex ]]; then
			require_cmd codex
		fi
	done
	install_xerj
	configure_clients
	warn 'MCP requires a running xerj node. See the platform README for startup and authentication.'
}

main "$@"
