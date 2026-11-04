#!/bin/bash
# SecureBlue xerj install/update helper.
#
# Installs a checksum-verified static release into ~/.local/bin without root.
# Optional client flags register stdio MCP with Codex, Crush, or OpenCode.
# The engine must be started separately; no service is installed or started.
# Requires curl, Python 3, sha256sum, and standard GNU utilities.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
set -euo pipefail
export PATH="${HOME}/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
TMP_DIR=''
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
		--codex|--crush|--opencode)
			CLIENTS+=("${1#--}")
			shift
			;;
		--version|--url)
			(($# >= 2)) || error "Missing value for $1"
			case "$1" in
			--version) VERSION="$2" ;;
			--url) NODE_URL="$2" ;;
			esac
			shift 2
			;;
		--help|-h)
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
	aarch64|arm64) arch=aarch64 ;;
	*) error 'Unsupported architecture' ;;
	esac
	if [[ -z $version ]]; then
		version=$(curl --fail --silent --show-error --location --proto '=https' \
			https://api.github.com/repos/xerj-org/xerj/releases/latest |
			python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
	fi
	tag="v${version#v}"
	[[ $tag =~ ^v[0-9][A-Za-z0-9.+-]*$ ]] || error 'Invalid release tag'
	asset="xerj-${tag#v}-${arch}-unknown-linux-musl.tar.gz"
	base="https://github.com/xerj-org/xerj/releases/download/$tag"
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/update-xerj.XXXXXX")
	trap 'if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi' EXIT
	for client in "$asset" "$asset.sha256"; do
		curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
			"$base/$client" -o "$TMP_DIR/$client"
	done
	digest=$(sha256sum "$TMP_DIR/$asset")
	digest=${digest%% *}
	[[ $digest =~ ^[0-9a-f]{64}$ ]] || error 'Invalid SHA-256 digest'
	tr -d '\r' <"$TMP_DIR/$asset.sha256" | grep -xF -e "$digest  $asset" -e "$digest *$asset" >/dev/null || error 'SHA-256 mismatch'
	# Extract only the expected regular binary, never archive paths or links.
	python3 - "$TMP_DIR/$asset" "$TMP_DIR/xerj" "${asset%.tar.gz}/xerj" <<'PY'
import shutil, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    member = archive.getmember(sys.argv[3])
    if not member.isfile():
        raise ValueError("Expected a regular binary")
    with archive.extractfile(member) as source, open(sys.argv[2], "wb") as target:
        shutil.copyfileobj(source, target)
PY
	mkdir -p -- "${binary%/*}"
	install -m 0755 "$TMP_DIR/xerj" "$binary.new"
	mv -f -- "$binary.new" "$binary"
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
			python3 - "$client" "$binary" "$url" <<'PY'
import datetime, json, os, pathlib, shlex, shutil, sys, tempfile
client, binary, url = sys.argv[1:]
root = pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or pathlib.Path.home() / ".config")
path = root / client / ("crushrc" if client == "crush" else "opencode.json")
old = path.read_text() if path.exists() else ""
if client == "crush":
    begin, end = "# BEGIN xerj managed", "# END xerj managed"
    import re
    if old.count(begin) != old.count(end) or old.count(begin) > 1:
        raise ValueError("Malformed xerj managed block")
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", old, flags=re.S)
    text = text.rstrip() + "\n" + begin + "\n" + "mcp add xerj --type stdio --command " + shlex.quote(binary) + " --args mcp --args --url --args " + shlex.quote(url) + "\n" + end + "\n"
else:
    if path.with_suffix(".jsonc").exists():
        raise ValueError("Merge xerj into existing opencode.jsonc manually; refusing ambiguous configuration")
    data = json.loads(old) if old.strip() else {}
    data.setdefault("mcp", {})["xerj"] = {"type": "local", "command": [binary, "mcp", "--url", url], "enabled": True}
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    shutil.copy2(path, str(path) + ".bak." + datetime.datetime.now().strftime("%Y%m%d%H%M%S%f"))
fd, name = tempfile.mkstemp(prefix=".xerj-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(text)
    os.replace(name, path)
finally:
    if os.path.exists(name):
        os.unlink(name)
print("Configured " + str(path))
PY
		fi
	done
}

main() {
	local client
	parse_args "$@"
	[[ $EUID -ne 0 ]] || error 'Run as the desktop user, without run0.'
	for client in curl python3 sha256sum install; do
		require_cmd "$client"
	done
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
