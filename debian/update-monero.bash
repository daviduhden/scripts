#!/bin/bash

set -euo pipefail

# Debian Monero CLI update script
# Automatically install/update Monero CLI to the latest stable version
# on Linux systems using official tarballs.
# - Fetch latest tag from GitHub
# - Download CLI tarball from downloads.getmonero.org
# - Install binaries into /usr/bin
# - Ensure "monero" system user and directories exist
# - Download official monerod systemd unit (always replace)
# - Create a basic /etc/monerod.conf if it does not exist
# - Enable and start/restart monerod service
# - Optionally build/install monero-lws release branch (latest release-v*)
# - Configure monerod ZMQ and monero-lws public REST endpoints for Debian
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO="monero-project/monero"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
REPO_URL="https://github.com/${REPO}.git"
DOWNLOAD_BASE="https://downloads.getmonero.org/cli"
HASHES_URL="https://www.getmonero.org/downloads/hashes.txt"
BINARYFATE_KEY_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/systemd/monerod.service"
LWS_REPO="vtnerd/monero-lws"
LWS_REPO_URL="https://github.com/${LWS_REPO}.git"

INSTALL_DIR="/usr/bin"
MONERO_USER="monero"
MONERO_DATA_DIR="${MONERO_DATA_DIR:-/var/lib/monero}"
MONERO_LOG_DIR="/var/log/monero"
MONEROD_CONF="/etc/monerod.conf"
MONEROD_ZMQ_RPC_IP="127.0.0.1"
MONEROD_ZMQ_RPC_PORT="18082"
MONEROD_ZMQ_PUB_ADDR="tcp://127.0.0.1:18083"
LWS_CONF_DIR="/etc/monero-lws"
LWS_CONF_FILE="${LWS_CONF_DIR}/monero-lws.conf"
LWS_SERVICE_FILE="/etc/systemd/system/monero-lws.service"
LWS_DATA_DIR="${LWS_DATA_DIR:-/var/lib/monero-lws/light_wallet_server}"
LWS_LOG_DIR="/var/log/monero-lws"
LWS_STATE_FILE="/var/lib/monero-lws/.installed-release-ref"
LWS_REST_ADDR="${LWS_REST_ADDR:-http://0.0.0.0:8443}"
LWS_REST_ADDR_V6="${LWS_REST_ADDR_V6:-}"
LWS_ADMIN_REST_ADDR="${LWS_ADMIN_REST_ADDR:-http://127.0.0.1:8444}"
LWS_ADMIN_REST_ADDR_V6="${LWS_ADMIN_REST_ADDR_V6:-}"
TOR_CONF_FILE="/etc/tor/torrc"
I2PD_TUNNELS_FILE="/etc/i2pd/tunnels.conf"
UFW_TCP_PORTS="${UFW_TCP_PORTS:-18080 8443}"
LWS_BUILD_PACKAGES="build-essential cmake git pkg-config libboost-all-dev libunbound-dev libzmq3-dev libsodium-dev liblzma-dev libreadline-dev libldns-dev libexpat1-dev libpgm-dev libnorm-dev libudev-dev libunwind-dev libusb-1.0-0-dev libprotobuf-dev protobuf-compiler"
SKIP_SERVICE_AND_USER_SETUP=0
INSTALL_OR_UPDATE_LWS=0

usage() {
	cat <<'EOF'
Usage: update-monero.bash [--skip-service-and-user-setup] [--install-lws]

Options:
  --skip-service-and-user-setup  Skip monero/monero-lws user and systemd install/enable steps.
  --install-lws                  Build/install monero-lws and configure monerod+lws to run together.
  -h, --help                     Show this help message and exit.
EOF
}

parse_args() {
	local flag_used=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--skip-service-and-user-setup)
			flag_used=1
			SKIP_SERVICE_AND_USER_SETUP=1
			;;
		--install-lws)
			flag_used=1
			INSTALL_OR_UPDATE_LWS=1
			;;
		-h | --help)
			flag_used=1
			warn "CLI flag detected; using non-default options instead of standard behavior."
			usage
			exit 0
			;;
		*)
			error "Unknown option: $1"
			;;
		esac
		shift
	done
	if [ "$flag_used" -eq 1 ]; then
		warn "CLI flag detected; using non-default options instead of standard behavior."
	fi
}

# Simple colors for messages
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
error() {
	printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2
	exit 1
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi
}

# Helper to ensure required commands exist
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

check_prereqs() {
	require_cmd curl
	require_cmd tar
	require_cmd awk
	require_cmd systemctl
	require_cmd install
	require_cmd sha256sum
	require_cmd gpg
	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		require_cmd useradd
	fi
	if [[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]]; then
		require_cmd git
		require_cmd cmake
		require_cmd make
		require_cmd c++
	fi
}

ensure_lws_build_dependencies() {
	local -a missing=()

	[[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]] || return 0
	command -v dpkg-query >/dev/null 2>&1 || return 0
	command -v apt-get >/dev/null 2>&1 || return 0

	for package in $LWS_BUILD_PACKAGES; do
		if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
			missing+=("$package")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		return 0
	fi

	log "Installing missing monero-lws build dependencies: ${missing[*]}"
	DEBIAN_FRONTEND=noninteractive apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

open_ufw_ports() {
	if ! command -v ufw >/dev/null 2>&1; then
		log "ufw is not installed; skipping firewall rule updates."
		return 0
	fi

	log "Opening UFW ports for clearnet access..."
	for port in $UFW_TCP_PORTS; do
		if ufw status | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
			log "ufw already allows ${port}/tcp"
			continue
		fi
		ufw allow "${port}/tcp"
	done
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

set_config_value() {
	local file key value
	file="$1"
	key="$2"
	value="$3"

	if grep -Eq "^[[:space:]]*${key}=" "$file"; then
		sed -i -E "s#^[[:space:]]*${key}=.*#${key}=${value}#" "$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

append_config_line() {
	local file line
	file="$1"
	line="$2"

	if ! grep -Fqx "$line" "$file"; then
		printf '%s\n' "$line" >>"$file"
	fi
}

configure_monerod_conf() {
	log "Configuring ${MONEROD_CONF} for public clearnet and monero-lws..."
	local p2p_bind_ip="${MONEROD_P2P_BIND_IP:-0.0.0.0}"
	local p2p_bind_ipv6="${MONEROD_P2P_BIND_IPV6:-::}"
	local rpc_bind_ip="${MONEROD_RPC_BIND_IP:-127.0.0.1}"
	local rpc_bind_ipv6="${MONEROD_RPC_BIND_IPV6:-::1}"
	local tor_onion="${MONERO_TOR_ONION:-}"
	local i2p_b32="${MONERO_I2P_B32:-}"

	set_config_value "$MONEROD_CONF" "data-dir" "$MONERO_DATA_DIR"
	set_config_value "$MONEROD_CONF" "log-file" "${MONERO_LOG_DIR}/monerod.log"
	set_config_value "$MONEROD_CONF" "log-level" "0"
	set_config_value "$MONEROD_CONF" "max-log-file-size" "10485760"
	set_config_value "$MONEROD_CONF" "max-log-files" "5"
	set_config_value "$MONEROD_CONF" "no-igd" "1"
	set_config_value "$MONEROD_CONF" "db-sync-mode" "fast:async:250000000bytes"
	set_config_value "$MONEROD_CONF" "p2p-bind-ip" "${p2p_bind_ip}"
	set_config_value "$MONEROD_CONF" "p2p-bind-ipv6-address" "${p2p_bind_ipv6}"
	set_config_value "$MONEROD_CONF" "p2p-bind-port" "18080"
	set_config_value "$MONEROD_CONF" "p2p-bind-port-ipv6" "18080"
	set_config_value "$MONEROD_CONF" "p2p-use-ipv6" "1"
	set_config_value "$MONEROD_CONF" "out-peers" "32"
	set_config_value "$MONEROD_CONF" "in-peers" "64"
	set_config_value "$MONEROD_CONF" "limit-rate-up" "8192"
	set_config_value "$MONEROD_CONF" "limit-rate-down" "32768"
	set_config_value "$MONEROD_CONF" "rpc-bind-ip" "${rpc_bind_ip}"
	set_config_value "$MONEROD_CONF" "rpc-bind-port" "18081"
	set_config_value "$MONEROD_CONF" "rpc-use-ipv6" "1"
	set_config_value "$MONEROD_CONF" "rpc-bind-ipv6-address" "${rpc_bind_ipv6}"
	set_config_value "$MONEROD_CONF" "restricted-rpc" "1"
	set_config_value "$MONEROD_CONF" "confirm-external-bind" "1"
	set_config_value "$MONEROD_CONF" "public-node" "1"
	set_config_value "$MONEROD_CONF" "max-concurrency" "4"
	set_config_value "$MONEROD_CONF" "prep-blocks-threads" "4"
	set_config_value "$MONEROD_CONF" "enable-dns-blocklist" "1"
	set_config_value "$MONEROD_CONF" "enforce-dns-checkpointing" "1"
	set_config_value "$MONEROD_CONF" "zmq-rpc-bind-ip" "$MONEROD_ZMQ_RPC_IP"
	set_config_value "$MONEROD_CONF" "zmq-rpc-bind-port" "$MONEROD_ZMQ_RPC_PORT"
	set_config_value "$MONEROD_CONF" "zmq-pub" "$MONEROD_ZMQ_PUB_ADDR"
	set_config_value "$MONEROD_CONF" "disable-rpc-ban" "1"
	sed -i -E '/^tx-proxy=/d;/^anonymous-inbound=/d' "$MONEROD_CONF"
	if [[ -n ${tor_onion} ]]; then
		append_config_line "$MONEROD_CONF" "tx-proxy=tor,[::1]:9050,10"
		append_config_line "$MONEROD_CONF" "anonymous-inbound=${tor_onion}:18080,127.0.0.1:18080,16"
	fi
	if [[ -n ${i2p_b32} ]]; then
		append_config_line "$MONEROD_CONF" "tx-proxy=i2p,[::1]:4447"
		append_config_line "$MONEROD_CONF" "anonymous-inbound=${i2p_b32},127.0.0.2:18080,16"
	fi
}

configure_monerod_for_lws() {
	configure_monerod_conf
}

configure_lws_service() {
	log "Preparing monero-lws runtime directories..."
	mkdir -p "$LWS_CONF_DIR" "$LWS_DATA_DIR" "$LWS_LOG_DIR"
	chown -R "${MONERO_USER}:${MONERO_USER}" "$LWS_DATA_DIR" "$LWS_LOG_DIR"

	if [[ ! -f $LWS_CONF_FILE ]]; then
		log "Creating ${LWS_CONF_FILE}..."
		cat >"$LWS_CONF_FILE" <<EOF
# Basic configuration for monero-lws generated by update script.
# Adjust to your needs. Check 'monero-lws-daemon --help' for more options.
EOF
		chmod 640 "$LWS_CONF_FILE"
	fi

	set_config_value "$LWS_CONF_FILE" "db-path" "$LWS_DATA_DIR"
	set_config_value "$LWS_CONF_FILE" "daemon" "tcp://${MONEROD_ZMQ_RPC_IP}:${MONEROD_ZMQ_RPC_PORT}"
	set_config_value "$LWS_CONF_FILE" "sub" "$MONEROD_ZMQ_PUB_ADDR"
	set_config_value "$LWS_CONF_FILE" "zmq-pub" "tcp://127.0.0.1:18084"
	set_config_value "$LWS_CONF_FILE" "rest-server" "$LWS_REST_ADDR"
	if [[ -n ${LWS_REST_ADDR_V6} ]]; then
		append_config_line "$LWS_CONF_FILE" "rest-server=${LWS_REST_ADDR_V6}"
	fi
	set_config_value "$LWS_CONF_FILE" "admin-rest-server" "$LWS_ADMIN_REST_ADDR"
	if [[ -n ${LWS_ADMIN_REST_ADDR_V6} ]]; then
		append_config_line "$LWS_CONF_FILE" "admin-rest-server=${LWS_ADMIN_REST_ADDR_V6}"
	fi
	set_config_value "$LWS_CONF_FILE" "confirm-external-bind" "1"
	set_config_value "$LWS_CONF_FILE" "auto-accept-creation" "1"
	set_config_value "$LWS_CONF_FILE" "auto-accept-import" "1"
	set_config_value "$LWS_CONF_FILE" "max-subaddresses" "500"
	set_config_value "$LWS_CONF_FILE" "scan-threads" "4"
	set_config_value "$LWS_CONF_FILE" "rest-threads" "2"
	set_config_value "$LWS_CONF_FILE" "log-level" "1"
	chown "${MONERO_USER}:${MONERO_USER}" "$LWS_CONF_FILE"

	log "Installing systemd unit: ${LWS_SERVICE_FILE}..."
	cat >"$LWS_SERVICE_FILE" <<EOF
[Unit]
Description=Monero Light Wallet Server
Wants=network-online.target
After=network-online.target monerod.service
Requires=monerod.service
RequiresMountsFor=${LWS_DATA_DIR}

[Service]
Type=simple
User=${MONERO_USER}
Group=${MONERO_USER}
ExecStart=${INSTALL_DIR}/monero-lws-daemon --config-file ${LWS_CONF_FILE}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RestrictNamespaces=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=${LWS_DATA_DIR} ${LWS_LOG_DIR}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "$LWS_SERVICE_FILE"
}

configure_monero_privacy_transports() {
	if [[ -f $TOR_CONF_FILE ]] && command -v tor >/dev/null 2>&1; then
		if ! grep -Fqx 'HiddenServicePort 8443 127.0.0.1:8443' "$TOR_CONF_FILE"; then
			log "Adding monero-lws to the existing Monero onion service..."
			sed -i '/^HiddenServiceDir \/var\/lib\/tor\/monero\/?$/a HiddenServicePort 8443 127.0.0.1:8443' "$TOR_CONF_FILE"
		fi
		if ! grep -Fqx 'HiddenServicePort 18081 127.0.0.1:18081' "$TOR_CONF_FILE"; then
			log "Adding monerod restricted RPC to the existing Monero onion service..."
			sed -i '/^HiddenServiceDir \/var\/lib\/tor\/monero\/?$/a HiddenServicePort 18081 127.0.0.1:18081' "$TOR_CONF_FILE"
		fi
		tor --verify-config -f "$TOR_CONF_FILE" --User debian-tor >/dev/null
		systemctl restart tor
	fi

	if [[ -f $I2PD_TUNNELS_FILE ]] && command -v i2pd >/dev/null 2>&1; then
		if ! grep -Fqx '[MONERO-LWS]' "$I2PD_TUNNELS_FILE"; then
			log "Adding a dedicated monero-lws I2P HTTP tunnel..."
			cat >>"$I2PD_TUNNELS_FILE" <<'EOF'

[MONERO-LWS]
type = http
host = 127.0.0.1
port = 8443
inport = 8443
keys = monero-lws.dat
EOF
		fi
		if ! grep -Fqx '[MONERO-RESTRICTED-RPC]' "$I2PD_TUNNELS_FILE"; then
			log "Adding a dedicated monerod restricted RPC I2P tunnel..."
			cat >>"$I2PD_TUNNELS_FILE" <<'EOF'

[MONERO-RESTRICTED-RPC]
type = http
host = 127.0.0.1
port = 18081
inport = 18081
keys = monero-restricted-rpc.dat
EOF
		fi
		systemctl restart i2pd
	fi
}

# Get the latest release tag from GitHub
get_latest_release() {
	local tag json

	# Preferred method: query tags via git.
	if has_cmd git; then
		tag="$(git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null |
			awk '{print $2}' |
			sed 's#refs/tags/##' |
			sed 's/\^{}//' |
			grep -E '^v[0-9]+' |
			sort -uV |
			tail -n1)"
		if [[ -n $tag ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	if ! json="$(net_curl "$API_URL" 2>/dev/null)"; then
		return 1
	fi
	awk -F'"' '/"tag_name":/ {print $4; exit}' <<<"$json"
}

get_latest_lws_release_branch() {
	if ! has_cmd git; then
		return 1
	fi

	git ls-remote --heads "$LWS_REPO_URL" 'release-v*' 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/heads/##' |
		grep -E '^release-v[0-9]+' |
		sort -uV |
		tail -n1
}

get_lws_release_ref() {
	local branch="$1"
	git ls-remote --heads "$LWS_REPO_URL" "refs/heads/${branch}" 2>/dev/null | awk 'NR==1{print $1}'
}

lws_is_current() {
	local branch="$1"
	local ref="$2"
	local installed_ref

	[[ -x "${INSTALL_DIR}/monero-lws-daemon" ]] || return 1
	[[ -f "${LWS_STATE_FILE}" ]] || return 1
	installed_ref="$(awk 'NR==1{print}' "${LWS_STATE_FILE}" 2>/dev/null || true)"
	[[ "${installed_ref}" == "${branch}:${ref}" ]]
}

install_or_update_lws() {
	local lws_branch lws_ref lws_tmp lws_build

	log "Checking latest monero-lws release branch..."
	lws_branch="$(get_latest_lws_release_branch || true)"
	if [[ -z ${lws_branch} ]]; then
		error "could not determine latest monero-lws release-v* branch."
	fi
	lws_ref="$(get_lws_release_ref "${lws_branch}" || true)"
	if [[ -z ${lws_ref} ]]; then
		error "could not determine monero-lws commit for branch ${lws_branch}."
	fi
	log "Using monero-lws branch: ${lws_branch}"
	if lws_is_current "${lws_branch}" "${lws_ref}"; then
		log "monero-lws is already up to date (${lws_branch} @ ${lws_ref}). Skipping build/install."
		return 0
	fi

	lws_tmp="$(mktemp -d /tmp/monero-lws-src-XXXXXX)"
	lws_build="${lws_tmp}/build"
	LWS_TMP="$lws_tmp"

	trap 'rm -rf "${TMPDIR:-}" "${GPG_HOME:-}" "${LWS_TMP:-}" 2>/dev/null || true' EXIT

	log "Cloning monero-lws (${lws_branch})..."
	if ! git clone --depth 1 --branch "$lws_branch" "$LWS_REPO_URL" "$lws_tmp"; then
		error "failed to clone monero-lws branch ${lws_branch}"
	fi

	log "Updating monero-lws submodules..."
	if ! git -C "$lws_tmp" submodule update --init --recursive; then
		error "failed to initialize monero-lws submodules"
	fi

	mkdir -p "$lws_build"
	log "Configuring monero-lws build..."
	if ! cmake -DCMAKE_BUILD_TYPE=Release -S "$lws_tmp" -B "$lws_build"; then
		error "monero-lws cmake configure failed"
	fi

	log "Building monero-lws..."
	if has_cmd nproc; then
		if ! cmake --build "$lws_build" -j"$(nproc)"; then
			error "monero-lws build failed"
		fi
	else
		if ! cmake --build "$lws_build"; then
			error "monero-lws build failed"
		fi
	fi

	log "Installing monero-lws binaries into ${INSTALL_DIR}..."
	local installed_lws_bins=0
	while IFS= read -r -d '' lws_bin; do
		log " -> installing $(basename "$lws_bin")"
		install -m 0755 "$lws_bin" "${INSTALL_DIR}/"
		installed_lws_bins=$((installed_lws_bins + 1))
	done < <(
		find "$lws_build/src" -maxdepth 1 -type f -name 'monero-lws*' -perm -111 -print0 2>/dev/null | sort -z
	)

	if [[ $installed_lws_bins -eq 0 ]]; then
		error "no monero-lws binaries found under build output: ${lws_build}/src"
	fi

	install -d "$(dirname "${LWS_STATE_FILE}")"
	printf '%s:%s\n' "${lws_branch}" "${lws_ref}" >"${LWS_STATE_FILE}"
	chmod 0644 "${LWS_STATE_FILE}"

	log "monero-lws install/update completed from ${lws_branch}"
}

run_update() {
	log "Checking latest Monero CLI release from GitHub..."
	LATEST_TAG="$(get_latest_release || true)"

	if [[ -z ${LATEST_TAG} ]]; then
		error "could not fetch latest release tag from GitHub."
	fi

	log "Latest available tag: ${LATEST_TAG}"

	# Detect currently installed version (if any)
	CURRENT_VERSION_RAW=""
	if command -v monerod >/dev/null 2>&1; then
		CURRENT_VERSION_RAW="$(monerod --version 2>/dev/null | awk 'NR==1{print}')"
		log "Current monerod version line: ${CURRENT_VERSION_RAW:-unknown}"

		# If current version string contains the latest tag, assume it's up to date.
		# Keep going when --install-lws was requested so we can still configure/build LWS.
		if [[ -n ${CURRENT_VERSION_RAW} && ${CURRENT_VERSION_RAW} == *"${LATEST_TAG}"* ]]; then
			log "Monero CLI already at latest version (${LATEST_TAG})."
			if [[ ${INSTALL_OR_UPDATE_LWS} -eq 0 ]]; then
				exit 0
			fi

			install_or_update_lws
			if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
				configure_monerod_for_lws
				configure_lws_service
				open_ufw_ports
				systemctl daemon-reload
				systemctl restart monerod
				systemctl enable monero-lws >/dev/null 2>&1 || true
				systemctl restart monero-lws
			else
				log "Skipping monero-lws service and user setup as requested."
			fi
			log "monero-lws install/update completed successfully."
			return 0
		fi
	else
		log "Monero CLI is not currently installed (or not in PATH)."
	fi

	# Map architecture to CLI tarball platform name
	ARCH="$(uname -m)"
	PLATFORM=""
	case "$ARCH" in
	x86_64 | amd64)
		PLATFORM="linux-x64"
		;;
	i386 | i686)
		PLATFORM="linux-x86"
		;;
	aarch64 | arm64)
		PLATFORM="linux-armv8"
		;;
	armv7l | armv7*)
		PLATFORM="linux-armv7"
		;;
	riscv64)
		PLATFORM="linux-riscv64"
		;;
	*)
		error "Unsupported architecture: ${ARCH}"
		;;
	esac

	TARBALL="monero-${PLATFORM}-${LATEST_TAG}.tar.bz2"
	DOWNLOAD_URL="${DOWNLOAD_BASE}/${TARBALL}"

	log "Detected architecture: ${ARCH} -> ${PLATFORM}"
	log "Tarball to download: ${TARBALL}"
	log "Download URL: ${DOWNLOAD_URL}"

	# Temporary working directory
	TMPDIR="$(mktemp -d /tmp/monero-cli-XXXXXX)"
	GPG_HOME="$(mktemp -d /tmp/monero-gpg-XXXXXX)"
	cleanup() {
		rm -rf "$TMPDIR" "$GPG_HOME" 2>/dev/null || true
	}
	trap cleanup EXIT

	log "Downloading Monero CLI ${LATEST_TAG}..."
	if ! net_curl "${DOWNLOAD_URL}" -o "${TMPDIR}/${TARBALL}"; then
		error "download failed from ${DOWNLOAD_URL}"
	fi

	log "Fetching reference hashes for verification..."
	HASHES_ASC="${TMPDIR}/hashes.txt"
	HASHES_PLAIN="${TMPDIR}/hashes-plain.txt"
	BINARYFATE_KEY="${TMPDIR}/binaryfate.asc"

	if ! net_curl "${HASHES_URL}" -o "${HASHES_ASC}"; then
		error "failed to download hash list from ${HASHES_URL}"
	fi

	log "Importing binaryFate signing key for hash verification..."
	if ! net_curl "${BINARYFATE_KEY_URL}" -o "${BINARYFATE_KEY}"; then
		error "failed to download binaryFate GPG key"
	fi

	if ! gpg --homedir "$GPG_HOME" --batch --import "${BINARYFATE_KEY}" >/dev/null 2>&1; then
		error "failed to import binaryFate GPG key"
	fi

	log "Verifying hashes file signature..."
	if ! gpg --homedir "$GPG_HOME" --batch --verify "${HASHES_ASC}" >/dev/null 2>&1; then
		error "hash file signature verification failed"
	fi

	if ! gpg --homedir "$GPG_HOME" --batch --output "${HASHES_PLAIN}" --decrypt "${HASHES_ASC}" >/dev/null 2>&1; then
		error "failed to decrypt (strip signature from) hashes file"
	fi

	EXPECTED_HASH="$(awk -v fname="${TARBALL}" '$1 ~ /^[0-9a-f]{64}$/ && $2==fname{print $1; exit}' "${HASHES_PLAIN}")"
	if [[ -z ${EXPECTED_HASH} ]]; then
		error "could not find expected hash for ${TARBALL} in downloaded hash list"
	fi

	ACTUAL_HASH="$(sha256sum "${TMPDIR}/${TARBALL}" | awk '{print $1}')"
	if [[ ${EXPECTED_HASH} != "${ACTUAL_HASH}" ]]; then
		error "hash mismatch for ${TARBALL} (expected ${EXPECTED_HASH}, got ${ACTUAL_HASH})"
	fi

	log "Hash verified for ${TARBALL}."

	log "Extracting tarball..."
	tar -xjf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

	EXTRACTED_DIR="$(find "$TMPDIR" -maxdepth 1 -type d -name 'monero-*' | head -n1)"
	if [[ -z ${EXTRACTED_DIR} ]]; then
		error "could not find extracted Monero directory."
	fi

	log "Extracted directory: ${EXTRACTED_DIR}"

	# Stop monerod if it is running
	log "Stopping monerod service if it is running..."
	WAS_ACTIVE=0
	if systemctl is-active --quiet monerod; then
		WAS_ACTIVE=1
		systemctl stop monerod
	fi

	# Install binaries
	log "Installing binaries into ${INSTALL_DIR}..."

	install -d "${INSTALL_DIR}"

	installed_bins=0
	while IFS= read -r -d '' bin; do
		log " -> installing $(basename "$bin")"
		install -m 0755 "$bin" "${INSTALL_DIR}/"
		installed_bins=$((installed_bins + 1))
	done < <(
		find "$EXTRACTED_DIR" -maxdepth 2 -type f \
			\( -name 'monerod' -o -name 'monero*' \) \
			-perm -111 -print0 2>/dev/null | sort -z
	)

	if [[ $installed_bins -eq 0 ]]; then
		error "no Monero binaries found under extracted directory: ${EXTRACTED_DIR}"
	fi

	# Ensure monero user and directories
	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		log "Ensuring monero system user and directories exist..."

		if ! id -u "${MONERO_USER}" >/dev/null 2>&1; then
			log "Creating system user '${MONERO_USER}'..."
			useradd --system --home-dir "${MONERO_DATA_DIR}" --shell /usr/sbin/nologin "${MONERO_USER}"
		fi

		mkdir -p "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"
		chown -R "${MONERO_USER}:${MONERO_USER}" "${MONERO_DATA_DIR}" "${MONERO_LOG_DIR}"
	else
		log "Skipping monero user creation and systemd setup as requested."
	fi

	# Create a basic config file if it does not exist
	if [[ ! -f ${MONEROD_CONF} ]]; then
		log "Creating basic monerod config at ${MONEROD_CONF}..."
		cat >"${MONEROD_CONF}" <<EOF
# Basic configuration for monerod generated by update script.
# Adjust to your needs. Check 'monerod --help' for more options.

data-dir=${MONERO_DATA_DIR}
log-file=${MONERO_LOG_DIR}/monerod.log
log-level=0
max-log-file-size=10485760
max-log-files=5
no-igd=1
db-sync-mode=fast:async:250000000bytes
public-node=1
p2p-bind-ip=0.0.0.0
p2p-bind-port=18080
p2p-use-ipv6=1
p2p-bind-ipv6-address=::
p2p-bind-port-ipv6=18080
out-peers=32
in-peers=64
limit-rate-up=8192
limit-rate-down=32768
rpc-bind-ip=127.0.0.1
rpc-bind-port=18081
rpc-use-ipv6=1
rpc-bind-ipv6-address=::1
restricted-rpc=1
confirm-external-bind=1
max-concurrency=4
prep-blocks-threads=4
enable-dns-blocklist=1
enforce-dns-checkpointing=1
# Optional Tor/I2P transport configuration can be added with environment
# variables when needed.
zmq-rpc-bind-ip=${MONEROD_ZMQ_RPC_IP}
zmq-rpc-bind-port=${MONEROD_ZMQ_RPC_PORT}
zmq-pub=${MONEROD_ZMQ_PUB_ADDR}
disable-rpc-ban=1

# Limit log size
EOF
		chmod 644 "${MONEROD_CONF}"
	fi

	configure_monerod_conf

	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		# Update systemd unit from the official repository (always replace)
		log "Updating systemd unit: /etc/systemd/system/monerod.service..."
		install -d /etc/systemd/system

		UNIT_TMP="${TMPDIR}/monerod.service"
		download_systemd_unit() {
			local out_file="$1"

			# Preferred method: use git to fetch the file contents.
			if has_cmd git; then
				local git_tmp
				git_tmp="$(mktemp -d /tmp/monero-unit-git-XXXXXX)"
				(
					cd "$git_tmp"
					git init -q
					git remote add origin "$REPO_URL"
					# Shallow fetch only the default branch tip (master in upstream repo)
					git fetch -q --depth 1 origin master
					git show "FETCH_HEAD:utils/systemd/monerod.service" >"$out_file"
				) >/dev/null 2>&1 && rm -rf -- "$git_tmp" && return 0
				rm -rf -- "$git_tmp" 2>/dev/null || true
				warn "git fetch/show for systemd unit failed; falling back to curl."
			fi

			net_curl "${SYSTEMD_UNIT_URL}" -o "$out_file"
		}

		if ! download_systemd_unit "${UNIT_TMP}"; then
			error "failed to download systemd unit (git/curl chain)"
		fi

		# This always overwrites the target file, whether it exists or not
		install -m 0644 "${UNIT_TMP}" /etc/systemd/system/monerod.service

		log "Reloading systemd daemon..."
		systemctl daemon-reload

		log "Enabling monerod service at boot..."
		systemctl enable monerod >/dev/null 2>&1 || true

		if [[ $WAS_ACTIVE -eq 1 ]]; then
			log "Restarting monerod..."
			systemctl restart monerod
		elif [[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]]; then
			log "Starting monerod (required for monero-lws integration)..."
			systemctl start monerod
		else
			log "monerod was not running before."
			log "You can start it now with: systemctl start monerod"
		fi
	fi

	# Show final version
	if command -v monerod >/dev/null 2>&1; then
		log "Installed Monero CLI version: $(monerod --version | head -n1 || true)"
	fi

	if [[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]]; then
		install_or_update_lws
		if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
			configure_monerod_for_lws
			configure_lws_service
			configure_monero_privacy_transports
			open_ufw_ports
			log "Reloading systemd daemon..."
			systemctl daemon-reload
			log "Restarting monerod with ZMQ settings for monero-lws..."
			systemctl restart monerod
			log "Enabling and restarting monero-lws..."
			systemctl enable monero-lws >/dev/null 2>&1 || true
			systemctl restart monero-lws
		else
			log "Skipping monero-lws service and user setup as requested."
		fi
		if command -v monero-lws-daemon >/dev/null 2>&1; then
			log "Installed monero-lws-daemon: $(command -v monero-lws-daemon)"
		fi
	fi

	log "Monero CLI install/update completed successfully."
}

main() {
	require_root
	parse_args "$@"
	ensure_lws_build_dependencies
	check_prereqs
	run_update
}

main "$@"
