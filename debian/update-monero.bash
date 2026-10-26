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
# - Optionally build/install monero-lws release tag
# - Configure monerod ZMQ and monero-lws public REST
#   endpoints for Debian
#
# Requirements: root privileges, systemd, network access, curl, tar,
# awk, install, sha256sum, and gpg. useradd is needed unless
# --skip-service-and-user-setup is used. --install-lws additionally
# requires git, cmake, make, and a C++ compiler; missing LWS build
# packages are installed through apt.
#
# Usage: update-monero.bash [--skip-service-and-user-setup]
# [--install-lws]. Environment variables are documented by --help.
#
# Side effects:
#  - Downloads the CLI tarball into /tmp, verifies it against the
#    GPG-signed hashes.txt with the binaryFate key, and installs the
#    binaries into /usr/bin
#  - Creates the monero system user and data/log directories
#  - Creates /etc/monerod.conf when absent, then updates its keys
#    during a full run (existing values are replaced in place)
#  - Stops monerod before replacing binaries when it is running, and
#    restarts it afterward
#  - Installs the upstream systemd unit with paths rewritten to
#    /usr/bin and /etc/monerod.conf
#  - With --install-lws: builds monero-lws in /tmp, installs its
#    binaries, writes /etc/monero-lws/monero-lws.conf and the
#    monero-lws unit, optionally edits torrc/tunnels.conf, and adds
#    runtime nftables rules for FIREWALL_TCP_PORTS
#
# The GPG home and source/build directories are temporary and removed
# by an EXIT trap. Firewall rules added by this script are runtime-only
# and are not saved to the nftables configuration. The monerod
# configuration is edited without a backup. On systems where monerod is
# already at the latest tag and LWS is not requested, the script exits
# early without refreshing the configuration or the unit.
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
BINARYFATE_KEY_URL="https://raw.githubusercontent.com"
BINARYFATE_KEY_URL="${BINARYFATE_KEY_URL}/monero-project/monero/master"
BINARYFATE_KEY_URL="${BINARYFATE_KEY_URL}/utils/gpg_keys/binaryfate.asc"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com"
SYSTEMD_UNIT_URL="${SYSTEMD_UNIT_URL}/monero-project/monero/master"
SYSTEMD_UNIT_URL="${SYSTEMD_UNIT_URL}/utils/systemd/monerod.service"
LWS_REPO="vtnerd/monero-lws"
LWS_REPO_URL="https://github.com/${LWS_REPO}.git"

INSTALL_DIR="/usr/bin"
MONERO_USER="monero"
# Account that runs monero-lws. Empty means auto-detect: use an existing
# "monero-lws" system user when present, otherwise the monerod user.
LWS_USER="${LWS_USER:-}"
LWS_GROUP="${LWS_GROUP:-}"
# Whether monero-lws accepts created/imported accounts automatically.
LWS_AUTO_ACCEPT_CREATION="${LWS_AUTO_ACCEPT_CREATION:-1}"
LWS_AUTO_ACCEPT_IMPORT="${LWS_AUTO_ACCEPT_IMPORT:-1}"
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
FIREWALL_TCP_PORTS="${FIREWALL_TCP_PORTS:-18080 8443}"
LWS_BUILD_PACKAGES="build-essential cmake git pkg-config"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libboost-all-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libunbound-dev libzmq3-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libsodium-dev liblzma-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libreadline-dev libldns-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libexpat1-dev libpgm-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libnorm-dev libudev-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libunwind-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libusb-1.0-0-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} libprotobuf-dev"
LWS_BUILD_PACKAGES="${LWS_BUILD_PACKAGES} protobuf-compiler"
SKIP_SERVICE_AND_USER_SETUP=0
INSTALL_OR_UPDATE_LWS=0

usage() {
	cat <<'EOF'
Usage: update-monero.bash [OPTIONS]

Options:
  --skip-service-and-user-setup
        Skip monero/monero-lws user and
        systemd install/enable steps.
  --install-lws
        Build/install monero-lws and configure
        monerod+lws to run together.
  -h, --help
        Show this help message and exit.

Environment:
  LWS_USER        Account that runs monero-lws. Default: an
                  existing 'monero-lws' user if present,
                  otherwise the monerod user.
  LWS_GROUP       Group for monero-lws. Default: LWS_USER's
                  primary group.
  LWS_DATA_DIR    monero-lws database directory. Default:
                  /var/lib/monero-lws/light_wallet_server.
  LWS_REST_ADDR, LWS_ADMIN_REST_ADDR
                  monero-lws REST bind addresses.
  LWS_AUTO_ACCEPT_CREATION, LWS_AUTO_ACCEPT_IMPORT
                  Auto-accept created/imported accounts (0/1,
                  default 1).
  MONERO_DATA_DIR Monerod data directory. Default:
                  /var/lib/monero.
  FIREWALL_TCP_PORTS
                  TCP ports to allow in the host firewall
                  (nftables). Default: 18080 8443.
  NFT_TABLE, NFT_CHAIN
                  nftables family/table and chain to edit.
                  Default: auto-detect (inet mainfw or
                  inet filter) with chain "input".
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
			warn "CLI flag detected;" \
				"using non-default options" \
				"instead of standard behavior."
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
		warn "CLI flag detected;" \
			"using non-default options" \
			"instead of standard behavior."
	fi
}

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root." \
			"Try: sudo $0"
	fi
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not" \
			"installed or not in PATH."
	fi
}

# Resolve the monero-lws account once: prefer an existing "monero-lws"
# user, otherwise reuse the monerod user. The group defaults to the
# account's primary group. Explicit LWS_USER/LWS_GROUP overrides win.
resolve_lws_account() {
	if [[ -z ${LWS_USER} ]]; then
		if id -u monero-lws >/dev/null 2>&1; then
			LWS_USER="monero-lws"
		else
			LWS_USER="${MONERO_USER}"
		fi
	fi
	if [[ -z ${LWS_GROUP} ]]; then
		LWS_GROUP="$(id -gn "${LWS_USER}" 2>/dev/null ||
			printf '%s' "${LWS_USER}")"
	fi
}

# Require the base tools plus the conditional ones for user setup and
# LWS builds.
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

# Install only missing monero-lws build packages, and only when LWS was
# requested and the dpkg/apt tooling is available. This is a no-op
# otherwise.
ensure_lws_build_dependencies() {
	local -a missing=()

	[[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]] || return 0
	command -v dpkg-query >/dev/null 2>&1 || return 0
	command -v apt-get >/dev/null 2>&1 || return 0

	for package in $LWS_BUILD_PACKAGES; do
		if ! dpkg-query -W \
			-f='${Status}' "$package" \
			2>/dev/null |
			grep -q 'install ok installed'; then
			missing+=("$package")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		return 0
	fi

	log "Installing missing monero-lws" \
		"build dependencies: ${missing[*]}"
	apt-get update
	apt-get install -y --no-install-recommends \
		"${missing[@]}"
}

# Open the service ports in the host firewall with nftables. Ports that the
# active ruleset already allows are left untouched. The family/table/chain is
# taken from NFT_TABLE/NFT_CHAIN, or auto-detected among the common input
# chains (for example "inet mainfw"). Rules are added to the running ruleset
# only and are not persisted across a reboot. Missing nft, a missing chain,
# or a failed rule is reported without failing the run.
open_firewall_ports() {
	if ! command -v nft >/dev/null 2>&1; then
		log "nft is not installed;" \
			"skipping firewall rule updates."
		return 0
	fi

	local family="inet" chain="${NFT_CHAIN:-input}" table=""
	if [[ -n ${NFT_TABLE:-} ]]; then
		if [[ ${NFT_TABLE} == *" "* ]]; then
			family="${NFT_TABLE%% *}"
			table="${NFT_TABLE##* }"
		else
			table="${NFT_TABLE}"
		fi
	else
		local candidate
		for candidate in mainfw filter; do
			if nft list chain "$family" "$candidate" \
				"$chain" >/dev/null 2>&1; then
				table="$candidate"
				break
			fi
		done
	fi
	if [[ -z $table ]] ||
		! nft list chain "$family" "$table" "$chain" \
			>/dev/null 2>&1; then
		log "no nftables input chain found;" \
			"skipping firewall rule updates."
		return 0
	fi

	log "Opening nftables ports in ${family} ${table}" \
		"${chain}..."
	local port rules
	for port in $FIREWALL_TCP_PORTS; do
		rules="$(nft list chain "$family" "$table" "$chain" \
			2>/dev/null || true)"
		# Match the port only as a whole number (80 must not match 18080).
		if printf '%s\n' "$rules" |
			grep -Eq "(^|[^0-9])${port}([^0-9]|$)"; then
			log "nftables already allows ${port}/tcp"
			continue
		fi
		if nft add rule "$family" "$table" "$chain" \
			tcp dport "$port" accept \
			comment "scripts-allow-${port}"; then
			log "nftables: allowed ${port}/tcp" \
				"(runtime rule)"
		else
			warn "failed to add nftables rule" \
				"for ${port}/tcp"
		fi
	done
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# Replace an existing "key=value" line (including leading whitespace)
# or append a new one. The file is edited in place with no backup, and
# a key with a suffix such as "key2" is not matched.
set_config_value() {
	local file key value
	file="$1"
	key="$2"
	value="$3"

	if grep -Eq "^[[:space:]]*${key}=" "$file"; then
		sed -i -E \
			"s#^[[:space:]]*${key}=.*#${key}=${value}#" \
			"$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

# Append a line only when the exact same line is not already present.
append_config_line() {
	local file line
	file="$1"
	line="$2"

	if ! grep -Fqx "$line" "$file"; then
		printf '%s\n' "$line" >>"$file"
	fi
}

# Apply the script's monerod defaults, replacing existing values rather
# than merging with them. Existing tx-proxy and anonymous-inbound lines
# are removed first; they are re-added only when MONERO_TOR_ONION or
# MONERO_I2P_B32 is set. The bind addresses can be overridden with the
# MONEROD_* environment variables read here.
configure_monerod_conf() {
	log "Configuring ${MONEROD_CONF} for" \
		"public clearnet and monero-lws..."
	local p2p_bind_ip="${MONEROD_P2P_BIND_IP:-0.0.0.0}"
	local p2p_bind_ipv6="${MONEROD_P2P_BIND_IPV6:-::}"
	local rpc_bind_ip="${MONEROD_RPC_BIND_IP:-127.0.0.1}"
	local rpc_bind_ipv6="${MONEROD_RPC_BIND_IPV6:-::1}"
	local tor_onion="${MONERO_TOR_ONION:-}"
	local i2p_b32="${MONERO_I2P_B32:-}"

	set_config_value "$MONEROD_CONF" \
		"data-dir" "$MONERO_DATA_DIR"
	set_config_value "$MONEROD_CONF" \
		"log-file" "${MONERO_LOG_DIR}/monerod.log"
	set_config_value "$MONEROD_CONF" "log-level" "0"
	set_config_value "$MONEROD_CONF" \
		"max-log-file-size" "10485760"
	set_config_value "$MONEROD_CONF" \
		"max-log-files" "5"
	set_config_value "$MONEROD_CONF" "no-igd" "1"
	set_config_value "$MONEROD_CONF" \
		"db-sync-mode" "fast:async:250000000bytes"
	set_config_value "$MONEROD_CONF" \
		"p2p-bind-ip" "${p2p_bind_ip}"
	set_config_value "$MONEROD_CONF" \
		"p2p-bind-ipv6-address" "${p2p_bind_ipv6}"
	set_config_value "$MONEROD_CONF" \
		"p2p-bind-port" "18080"
	set_config_value "$MONEROD_CONF" \
		"p2p-bind-port-ipv6" "18080"
	set_config_value "$MONEROD_CONF" \
		"p2p-use-ipv6" "1"
	set_config_value "$MONEROD_CONF" "out-peers" "32"
	set_config_value "$MONEROD_CONF" "in-peers" "64"
	set_config_value "$MONEROD_CONF" \
		"limit-rate-up" "8192"
	set_config_value "$MONEROD_CONF" \
		"limit-rate-down" "32768"
	set_config_value "$MONEROD_CONF" \
		"rpc-bind-ip" "${rpc_bind_ip}"
	set_config_value "$MONEROD_CONF" \
		"rpc-bind-port" "18081"
	set_config_value "$MONEROD_CONF" "rpc-use-ipv6" "1"
	set_config_value "$MONEROD_CONF" \
		"rpc-bind-ipv6-address" "${rpc_bind_ipv6}"
	set_config_value "$MONEROD_CONF" \
		"restricted-rpc" "1"
	set_config_value "$MONEROD_CONF" \
		"confirm-external-bind" "1"
	set_config_value "$MONEROD_CONF" "public-node" "1"
	set_config_value "$MONEROD_CONF" \
		"max-concurrency" "4"
	set_config_value "$MONEROD_CONF" \
		"prep-blocks-threads" "4"
	set_config_value "$MONEROD_CONF" \
		"enable-dns-blocklist" "1"
	set_config_value "$MONEROD_CONF" \
		"enforce-dns-checkpointing" "1"
	set_config_value "$MONEROD_CONF" \
		"zmq-rpc-bind-ip" "$MONEROD_ZMQ_RPC_IP"
	set_config_value "$MONEROD_CONF" \
		"zmq-rpc-bind-port" "$MONEROD_ZMQ_RPC_PORT"
	set_config_value "$MONEROD_CONF" \
		"zmq-pub" "$MONEROD_ZMQ_PUB_ADDR"
	set_config_value "$MONEROD_CONF" \
		"disable-rpc-ban" "1"
	sed -i -E '/^tx-proxy=/d;/^anonymous-inbound=/d' \
		"$MONEROD_CONF"
	if [[ -n ${tor_onion} ]]; then
		append_config_line "$MONEROD_CONF" \
			"tx-proxy=tor,[::1]:9050,10"
		append_config_line "$MONEROD_CONF" \
			"anonymous-inbound=${tor_onion}:18080,127.0.0.1:18080,16"
	fi
	if [[ -n ${i2p_b32} ]]; then
		append_config_line "$MONEROD_CONF" \
			"tx-proxy=i2p,[::1]:4447"
		append_config_line "$MONEROD_CONF" \
			"anonymous-inbound=${i2p_b32},127.0.0.2:18080,16"
	fi
}

configure_monerod_for_lws() {
	configure_monerod_conf
}

# Create the LWS account when it differs from the monerod user, prepare
# the data/log directories, create the config file with mode 0640 if
# absent, and (re)write the hardened systemd unit. Existing config keys
# are replaced in place; the unit is always overwritten. The unit
# requires monerod.service and confines the daemon to the LWS paths.
configure_lws_service() {
	if [[ ${LWS_USER} != "${MONERO_USER}" ]] &&
		! id -u "${LWS_USER}" >/dev/null 2>&1; then
		log "Creating system user '${LWS_USER}'..."
		useradd --system \
			--home-dir "${LWS_DATA_DIR}" \
			--shell /usr/sbin/nologin \
			"${LWS_USER}"
	fi

	log "Preparing monero-lws runtime directories..."
	mkdir -p "$LWS_CONF_DIR" "$LWS_DATA_DIR" \
		"$LWS_LOG_DIR"
	chown -R "${LWS_USER}:${LWS_GROUP}" \
		"$LWS_DATA_DIR" "$LWS_LOG_DIR"

	if [[ ! -f $LWS_CONF_FILE ]]; then
		log "Creating ${LWS_CONF_FILE}..."
		cat >"$LWS_CONF_FILE" <<EOF
# Basic configuration for monero-lws generated by
# update script. Adjust to your needs.
# Check 'monero-lws-daemon --help' for more options.
EOF
		chmod 640 "$LWS_CONF_FILE"
	fi

	set_config_value "$LWS_CONF_FILE" \
		"db-path" "$LWS_DATA_DIR"
	set_config_value "$LWS_CONF_FILE" \
		"daemon" \
		"tcp://${MONEROD_ZMQ_RPC_IP}:${MONEROD_ZMQ_RPC_PORT}"
	set_config_value "$LWS_CONF_FILE" \
		"sub" "$MONEROD_ZMQ_PUB_ADDR"
	set_config_value "$LWS_CONF_FILE" \
		"zmq-pub" "tcp://127.0.0.1:18084"
	set_config_value "$LWS_CONF_FILE" \
		"rest-server" "$LWS_REST_ADDR"
	if [[ -n ${LWS_REST_ADDR_V6} ]]; then
		append_config_line "$LWS_CONF_FILE" \
			"rest-server=${LWS_REST_ADDR_V6}"
	fi
	set_config_value "$LWS_CONF_FILE" \
		"admin-rest-server" "$LWS_ADMIN_REST_ADDR"
	if [[ -n ${LWS_ADMIN_REST_ADDR_V6} ]]; then
		append_config_line "$LWS_CONF_FILE" \
			"admin-rest-server=${LWS_ADMIN_REST_ADDR_V6}"
	fi
	set_config_value "$LWS_CONF_FILE" \
		"confirm-external-bind" "1"
	set_config_value "$LWS_CONF_FILE" \
		"auto-accept-creation" "${LWS_AUTO_ACCEPT_CREATION}"
	set_config_value "$LWS_CONF_FILE" \
		"auto-accept-import" "${LWS_AUTO_ACCEPT_IMPORT}"
	set_config_value "$LWS_CONF_FILE" \
		"max-subaddresses" "500"
	set_config_value "$LWS_CONF_FILE" \
		"scan-threads" "4"
	set_config_value "$LWS_CONF_FILE" \
		"rest-threads" "2"
	set_config_value "$LWS_CONF_FILE" \
		"log-level" "1"
	chown "${LWS_USER}:${LWS_GROUP}" \
		"$LWS_CONF_FILE"

	log "Installing systemd unit:" \
		"${LWS_SERVICE_FILE}..."
	cat >"$LWS_SERVICE_FILE" <<EOF
[Unit]
Description=Monero Light Wallet Server
Wants=network-online.target
After=network-online.target monerod.service
Requires=monerod.service
RequiresMountsFor=${LWS_DATA_DIR}

[Service]
Type=simple
User=${LWS_USER}
Group=${LWS_GROUP}
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

# Add hidden-service ports for LWS and restricted RPC to existing Tor
# and I2P configurations. Each port is added only when the exact line is
# not already present; both services are restarted afterward. This runs
# only when the corresponding config file and command exist.
configure_monero_privacy_transports() {
	if [[ -f $TOR_CONF_FILE ]] &&
		command -v tor >/dev/null 2>&1; then
		local key_line_8443 key_line_18081
		key_line_8443="^HiddenServiceDir"
		key_line_8443="${key_line_8443}"' \/var\/lib\/tor\/monero\/?$'
		key_line_18081="^HiddenServiceDir"
		key_line_18081="${key_line_18081}"' \/var\/lib\/tor\/monero\/?$'
		if ! grep -Fqx \
			'HiddenServicePort 8443 127.0.0.1:8443' \
			"$TOR_CONF_FILE"; then
			log "Adding monero-lws to the" \
				"existing Monero onion service..."
			sed -i -E \
				"/${key_line_8443}/a HiddenServicePort 8443 127.0.0.1:8443" \
				"$TOR_CONF_FILE"
		fi
		if ! grep -Fqx \
			'HiddenServicePort 18081 127.0.0.1:18081' \
			"$TOR_CONF_FILE"; then
			log "Adding monerod restricted RPC" \
				"to the existing Monero onion service..."
			sed -i -E \
				"/${key_line_18081}/a HiddenServicePort 18081 127.0.0.1:18081" \
				"$TOR_CONF_FILE"
		fi
		tor --verify-config -f "$TOR_CONF_FILE" \
			--User debian-tor >/dev/null
		systemctl restart tor
	fi

	if [[ -f $I2PD_TUNNELS_FILE ]] &&
		command -v i2pd >/dev/null 2>&1; then
		if ! grep -Fqx '[MONERO-LWS]' \
			"$I2PD_TUNNELS_FILE"; then
			log "Adding a dedicated monero-lws" \
				"I2P HTTP tunnel..."
			cat >>"$I2PD_TUNNELS_FILE" <<'EOF'

[MONERO-LWS]
type = http
host = 127.0.0.1
port = 8443
inport = 8443
keys = monero-lws.dat
EOF
		fi
		if ! grep -Fqx '[MONERO-RESTRICTED-RPC]' \
			"$I2PD_TUNNELS_FILE"; then
			log "Adding a dedicated monerod" \
				"restricted RPC I2P tunnel..."
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

# Resolve the highest v* tag through git ls-remote, falling back to the
# GitHub releases API when git is unavailable or returns nothing.
get_latest_release() {
	local tag json

	if has_cmd git; then
		tag="$(git ls-remote --tags --refs \
			"$REPO_URL" 'v*' 2>/dev/null |
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
	awk -F'"' '/"tag_name":/ {print $4; exit}' \
		<<<"$json"
}

# Choose the highest strict vN[.N...] tag from the monero-lws remote.
# Non-version tags are filtered out. Returns non-zero without git.
get_latest_lws_tag() {
	if ! has_cmd git; then
		return 1
	fi

	git ls-remote --tags --refs "$LWS_REPO_URL" \
		'refs/tags/v*' 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##' |
		grep -E '^v[0-9]+(\.[0-9]+)*$' |
		sort -uV |
		tail -n1
}

# Resolve the commit for an annotated tag by preferring the peeled
# (^{}) ref, then the plain ref. Prints nothing when neither exists.
get_lws_tag_commit() {
	local tag="$1" refs commit

	refs="$(git ls-remote "$LWS_REPO_URL" \
		"refs/tags/${tag}" \
		"refs/tags/${tag}^{}" 2>/dev/null || true)"
	commit="$(awk 'index($2, "^{}") {print $1; exit}' \
		<<<"$refs")"
	if [[ -z ${commit} ]]; then
		commit="$(awk 'NR==1 {print $1}' <<<"$refs")"
	fi
	[[ -n ${commit} ]] && printf '%s\n' "$commit"
}

# Consider LWS current only when the daemon is installed and the state
# file records the same "tag:commit" pair.
lws_is_current() {
	local tag="$1"
	local ref="$2"
	local installed_ref

	[[ -x "${INSTALL_DIR}/monero-lws-daemon" ]] ||
		return 1
	[[ -f ${LWS_STATE_FILE} ]] || return 1
	installed_ref="$(awk 'NR==1{print}' \
		"${LWS_STATE_FILE}" 2>/dev/null || true)"
	[[ ${installed_ref} == "${tag}:${ref}" ]]
}

# Build and install monero-lws from a shallow tagged clone. The cloned
# HEAD must match the resolved tag commit, submodules are initialized,
# and the build uses a Release cmake configuration. Executable binaries
# named monero-lws* are installed into /usr/bin and the tag/commit pair
# is recorded in LWS_STATE_FILE. The clone directory is assigned to
# LWS_TMP for the run_update cleanup trap rather than given its own
# trap, so the monerod restore logic is not replaced.
install_or_update_lws() {
	local lws_tag lws_ref lws_head lws_tmp lws_build

	log "Checking latest monero-lws" \
		"release tag..."
	lws_tag="$(get_latest_lws_tag || true)"
	if [[ -z ${lws_tag} ]]; then
		error "could not determine latest" \
			"monero-lws release tag."
	fi
	lws_ref="$(get_lws_tag_commit \
		"${lws_tag}" || true)"
	if [[ -z ${lws_ref} ]]; then
		error "could not determine monero-lws" \
			"commit for tag ${lws_tag}."
	fi
	log "Using monero-lws tag: ${lws_tag}"
	if lws_is_current "${lws_tag}" \
		"${lws_ref}"; then
		log "monero-lws is already up to date" \
			"(${lws_tag} @ ${lws_ref})." \
			"Skipping build/install."
		return 0
	fi

	lws_tmp="$(mktemp -d \
		/tmp/monero-lws-src-XXXXXX)"
	lws_build="${lws_tmp}/build"
	# The EXIT trap installed in run_update (cleanup) already removes
	# ${LWS_TMP:-}; do not replace it here or the monerod restore logic is
	# lost for the rest of the run.
	LWS_TMP="$lws_tmp"

	log "Cloning monero-lws (${lws_tag})..."
	if ! git clone --depth 1 \
		--branch "$lws_tag" \
		"$LWS_REPO_URL" "$lws_tmp"; then
		error "failed to clone monero-lws" \
			"tag ${lws_tag}"
	fi

	lws_head="$(git -C "$lws_tmp" \
		rev-parse HEAD 2>/dev/null || true)"
	if [[ ${lws_head} != "${lws_ref}" ]]; then
		error "monero-lws checkout mismatch" \
			"(expected ${lws_ref}," \
			"got ${lws_head:-unknown})"
	fi

	log "Updating monero-lws submodules..."
	if ! git -C "$lws_tmp" submodule update \
		--init --recursive; then
		error "failed to initialize" \
			"monero-lws submodules"
	fi

	mkdir -p "$lws_build"
	log "Configuring monero-lws build..."
	if ! cmake -DCMAKE_BUILD_TYPE=Release \
		-S "$lws_tmp" -B "$lws_build"; then
		error "monero-lws cmake configure failed"
	fi

	log "Building monero-lws..."
	if has_cmd nproc; then
		if ! cmake --build "$lws_build" \
			-j"$(nproc)"; then
			error "monero-lws build failed"
		fi
	else
		if ! cmake --build "$lws_build"; then
			error "monero-lws build failed"
		fi
	fi

	log "Installing monero-lws binaries" \
		"into ${INSTALL_DIR}..."
	local installed_lws_bins=0
	while IFS= read -r -d '' lws_bin; do
		log " -> installing" \
			"$(basename "$lws_bin")"
		install -m 0755 "$lws_bin" \
			"${INSTALL_DIR}/"
		installed_lws_bins=$((installed_lws_bins + 1))
	done < <(
		find "$lws_build/src" -maxdepth 1 \
			-type f -name 'monero-lws*' \
			-perm -111 -print0 2>/dev/null |
			sort -z
	)

	if [[ $installed_lws_bins -eq 0 ]]; then
		error "no monero-lws binaries found" \
			"under build output: ${lws_build}/src"
	fi

	install -d \
		"$(dirname "${LWS_STATE_FILE}")"
	printf '%s:%s\n' "${lws_tag}" \
		"${lws_ref}" >"${LWS_STATE_FILE}"
	chmod 0644 "${LWS_STATE_FILE}"

	log "monero-lws install/update completed" \
		"from ${lws_tag}"
}

# Main flow: resolve the latest tag, short-circuit when monerod already
# matches it, otherwise download and verify the tarball, replace the
# binaries, update configuration and the unit, and optionally set up
# LWS. Verification uses a private, temporary GPG home so the system
# keyring is not modified.
run_update() {
	log "Checking latest Monero CLI release" \
		"from GitHub..."
	LATEST_TAG="$(get_latest_release || true)"

	if [[ -z ${LATEST_TAG} ]]; then
		error "could not fetch latest release" \
			"tag from GitHub."
	fi

	log "Latest available tag: ${LATEST_TAG}"

	CURRENT_VERSION_RAW=""
	if command -v monerod >/dev/null 2>&1; then
		CURRENT_VERSION_RAW="$(monerod --version \
			2>/dev/null | awk 'NR==1{print}')"
		log "Current monerod version line:" \
			"${CURRENT_VERSION_RAW:-unknown}"

		# The version line embeds the tag. Matching with a substring is
		# the script's existing freshness test; without --install-lws
		# the run ends here without touching config or services.
		if [[ -n ${CURRENT_VERSION_RAW} &&
			${CURRENT_VERSION_RAW} == *"${LATEST_TAG}"* ]]; then
			log "Monero CLI already at latest" \
				"version (${LATEST_TAG})."
			if [[ ${INSTALL_OR_UPDATE_LWS} -eq 0 ]]; then
				exit 0
			fi

			install_or_update_lws
			if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
				configure_monerod_for_lws
				configure_lws_service
				open_firewall_ports
				systemctl daemon-reload
				systemctl restart monerod
				systemctl enable monero-lws \
					>/dev/null 2>&1 || true
				systemctl restart monero-lws
			else
				log "Skipping monero-lws service" \
					"and user setup as requested."
			fi
			log "monero-lws install/update" \
				"completed successfully."
			return 0
		fi
	else
		log "Monero CLI is not currently" \
			"installed (or not in PATH)."
	fi

	ARCH="$(uname -m)"
	PLATFORM=""
	case "$ARCH" in
	x86_64 | amd64) PLATFORM="linux-x64" ;;
	i386 | i686) PLATFORM="linux-x86" ;;
	aarch64 | arm64) PLATFORM="linux-armv8" ;;
	armv7l | armv7*) PLATFORM="linux-armv7" ;;
	riscv64) PLATFORM="linux-riscv64" ;;
	*) error "Unsupported architecture: ${ARCH}" ;;
	esac

	TARBALL="monero-${PLATFORM}-${LATEST_TAG}.tar.bz2"
	DOWNLOAD_URL="${DOWNLOAD_BASE}/${TARBALL}"

	log "Detected architecture: ${ARCH}" \
		"-> ${PLATFORM}"
	log "Tarball to download: ${TARBALL}"
	log "Download URL: ${DOWNLOAD_URL}"

	# From here on, the EXIT trap removes both temporary directories and
	# any LWS source tree, and brings monerod back up if this run
	# stopped it and it is not running at exit.
	WORK_DIR="$(mktemp -d /tmp/monero-cli-XXXXXX)"
	GPG_HOME="$(mktemp -d /tmp/monero-gpg-XXXXXX)"
	cleanup() {
		rm -rf "$WORK_DIR" "$GPG_HOME" \
			"${LWS_TMP:-}" 2>/dev/null || true
		# If this run stopped a running monerod and a later
		# step failed before the restart below, bring the
		# node back up instead of leaving it down.
		if [[ ${WAS_ACTIVE:-0} -eq 1 ]] &&
			! systemctl is-active --quiet monerod; then
			systemctl start monerod \
				>/dev/null 2>&1 || true
		fi
	}
	trap cleanup EXIT

	log "Downloading Monero CLI ${LATEST_TAG}..."
	if ! net_curl "${DOWNLOAD_URL}" \
		-o "${WORK_DIR}/${TARBALL}"; then
		error "download failed from ${DOWNLOAD_URL}"
	fi

	# hashes.txt is clearsigned. Import binaryFate's key into the
	# temporary GPG home, verify the signature, then decrypt to get the
	# plain checksum list. Any failure aborts before extraction.
	log "Fetching reference hashes for verification..."
	HASHES_ASC="${WORK_DIR}/hashes.txt"
	HASHES_PLAIN="${WORK_DIR}/hashes-plain.txt"
	BINARYFATE_KEY="${WORK_DIR}/binaryfate.asc"

	if ! net_curl "${HASHES_URL}" \
		-o "${HASHES_ASC}"; then
		error "failed to download hash list" \
			"from ${HASHES_URL}"
	fi

	log "Importing binaryFate signing key" \
		"for hash verification..."
	if ! net_curl "${BINARYFATE_KEY_URL}" \
		-o "${BINARYFATE_KEY}"; then
		error "failed to download" \
			"binaryFate GPG key"
	fi

	if ! gpg --homedir "$GPG_HOME" --batch \
		--import "${BINARYFATE_KEY}" \
		>/dev/null 2>&1; then
		error "failed to import" \
			"binaryFate GPG key"
	fi

	log "Verifying hashes file signature..."
	if ! gpg --homedir "$GPG_HOME" --batch \
		--verify "${HASHES_ASC}" \
		>/dev/null 2>&1; then
		error "hash file signature" \
			"verification failed"
	fi

	if ! gpg --homedir "$GPG_HOME" --batch \
		--output "${HASHES_PLAIN}" \
		--decrypt "${HASHES_ASC}" \
		>/dev/null 2>&1; then
		error "failed to decrypt (strip signature" \
			"from) hashes file"
	fi

	EXPECTED_HASH="$(awk \
		-v fname="${TARBALL}" \
		'$1 ~ /^[0-9a-f]{64}$/ && $2==fname{
			print $1;
			exit}' \
		"${HASHES_PLAIN}")"
	if [[ -z ${EXPECTED_HASH} ]]; then
		error "could not find expected hash for" \
			"${TARBALL} in downloaded hash list"
	fi

	# Compare the signed reference checksum with the downloaded archive
	# before extracting or installing anything.
	ACTUAL_HASH="$(sha256sum \
		"${WORK_DIR}/${TARBALL}" | awk '{print $1}')"
	if [[ ${EXPECTED_HASH} != "${ACTUAL_HASH}" ]]; then
		error "hash mismatch for ${TARBALL}" \
			"(expected ${EXPECTED_HASH}," \
			"got ${ACTUAL_HASH})"
	fi

	log "Hash verified for ${TARBALL}."

	log "Extracting tarball..."
	tar -xjf "${WORK_DIR}/${TARBALL}" -C "$WORK_DIR"

	EXTRACTED_DIR="$(find "$WORK_DIR" -maxdepth 1 \
		-type d -name 'monero-*' | sed -n '1p')"
	if [[ -z ${EXTRACTED_DIR} ]]; then
		error "could not find extracted" \
			"Monero directory."
	fi

	log "Extracted directory: ${EXTRACTED_DIR}"

	# Stop the service before replacing binaries so the running process
	# is not using files that are being overwritten. WAS_ACTIVE drives
	# the later restart and the cleanup trap.
	log "Stopping monerod service if it is running..."
	WAS_ACTIVE=0
	if systemctl is-active --quiet monerod; then
		WAS_ACTIVE=1
		systemctl stop monerod
	fi

	log "Installing binaries into ${INSTALL_DIR}..."

	install -d "${INSTALL_DIR}"

	installed_bins=0
	while IFS= read -r -d '' bin; do
		log " -> installing $(basename "$bin")"
		install -m 0755 "$bin" "${INSTALL_DIR}/"
		installed_bins=$((installed_bins + 1))
	done < <(
		find "$EXTRACTED_DIR" -maxdepth 2 \
			-type f \
			\( -name 'monerod' \
			-o -name 'monero*' \) \
			-perm -111 -print0 2>/dev/null |
			sort -z
	)

	if [[ $installed_bins -eq 0 ]]; then
		error "no Monero binaries found under" \
			"extracted directory: ${EXTRACTED_DIR}"
	fi

	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		log "Ensuring monero system user and" \
			"directories exist..."

		if ! id -u "${MONERO_USER}" \
			>/dev/null 2>&1; then
			log "Creating system user" \
				"'${MONERO_USER}'..."
			useradd --system \
				--home-dir "${MONERO_DATA_DIR}" \
				--shell /usr/sbin/nologin \
				"${MONERO_USER}"
		fi

		mkdir -p "${MONERO_DATA_DIR}" \
			"${MONERO_LOG_DIR}"
		chown -R "${MONERO_USER}:${MONERO_USER}" \
			"${MONERO_DATA_DIR}" \
			"${MONERO_LOG_DIR}"
	else
		log "Skipping monero user creation" \
			"and systemd setup as requested."
	fi

	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		if [[ ! -f ${MONEROD_CONF} ]]; then
			log "Creating basic monerod config" \
				"at ${MONEROD_CONF}..."
			cat >"${MONEROD_CONF}" <<EOF
# Basic configuration for monerod generated by
# update script. Adjust to your needs.
# Check 'monerod --help' for more options.

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
zmq-rpc-bind-ip=${MONEROD_ZMQ_RPC_IP}
zmq-rpc-bind-port=${MONEROD_ZMQ_RPC_PORT}
zmq-pub=${MONEROD_ZMQ_PUB_ADDR}
disable-rpc-ban=1

# Limit log size
EOF
			chmod 644 "${MONEROD_CONF}"
		fi

		configure_monerod_conf
	fi

	# Download the upstream unit and rewrite its Debian-package paths
	# (/usr/local/bin and /etc/monero) to the locations this script uses.
	if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
		log "Updating systemd unit:" \
			"/etc/systemd/system/monerod.service..."
		install -d /etc/systemd/system

		UNIT_TMP="${WORK_DIR}/monerod.service"
		download_systemd_unit() {
			local out_file="$1"

			if has_cmd git; then
				local git_tmp
				git_tmp="$(mktemp -d \
					/tmp/monero-unit-git-XXXXXX)"
				(
					cd "$git_tmp"
					git init -q
					git remote add \
						origin "$REPO_URL"
					git fetch -q --depth 1 \
						origin master
					git show \
						"FETCH_HEAD:utils/systemd/monerod.service" \
						>"$out_file"
				) >/dev/null 2>&1 &&
					rm -rf -- "$git_tmp" &&
					return 0
				rm -rf -- "$git_tmp" \
					2>/dev/null || true
				warn "git fetch/show for" \
					"systemd unit failed;" \
					"falling back to curl."
			fi

			net_curl "${SYSTEMD_UNIT_URL}" \
				-o "$out_file"
		}

		if ! download_systemd_unit \
			"${UNIT_TMP}"; then
			error "failed to download systemd" \
				"unit (git/curl chain)"
		fi

		# The upstream unit ships Debian-repo paths; rewrite them to the
		# locations this script installs into (/usr/bin + /etc/monerod.conf).
		sed -i \
			-e "s#/usr/local/bin/monerod#${INSTALL_DIR}/monerod#g" \
			-e "s#/etc/monero/monerod.conf#${MONEROD_CONF}#g" \
			"${UNIT_TMP}"

		install -m 0644 "${UNIT_TMP}" \
			/etc/systemd/system/monerod.service

		log "Reloading systemd daemon..."
		systemctl daemon-reload

		log "Enabling monerod service at boot..."
		systemctl enable monerod \
			>/dev/null 2>&1 || true

		if [[ $WAS_ACTIVE -eq 1 ]]; then
			log "Restarting monerod..."
			systemctl restart monerod
		elif [[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]]; then
			log "Starting monerod (required" \
				"for monero-lws integration)..."
			systemctl start monerod
		else
			log "monerod was not running before."
			log "You can start it now with:" \
				"systemctl start monerod"
		fi
	fi

	if command -v monerod >/dev/null 2>&1; then
		log "Installed Monero CLI version:" \
			"$(monerod --version 2>/dev/null | sed -n '1p' || true)"
	fi

	# Optional LWS integration: build/install first, then apply the ZMQ
	# configuration, unit, privacy transports, firewall rules, and
	# restarts. Skipping service setup leaves only the binaries and
	# state file behind.
	if [[ ${INSTALL_OR_UPDATE_LWS} -eq 1 ]]; then
		install_or_update_lws
		if [[ ${SKIP_SERVICE_AND_USER_SETUP} -eq 0 ]]; then
			configure_monerod_for_lws
			configure_lws_service
			configure_monero_privacy_transports
			open_firewall_ports
			log "Reloading systemd daemon..."
			systemctl daemon-reload
			log "Restarting monerod with ZMQ" \
				"settings for monero-lws..."
			systemctl restart monerod
			log "Enabling and restarting" \
				"monero-lws..."
			systemctl enable monero-lws \
				>/dev/null 2>&1 || true
			systemctl restart monero-lws
		else
			log "Skipping monero-lws service" \
				"and user setup as requested."
		fi
		if command -v monero-lws-daemon \
			>/dev/null 2>&1; then
			log "Installed monero-lws-daemon:" \
				"$(command -v monero-lws-daemon)"
		fi
	fi

	log "Monero CLI install/update" \
		"completed successfully."
}

main() {
	parse_args "$@"
	require_root
	resolve_lws_account
	ensure_lws_build_dependencies
	check_prereqs
	run_update
}

main "$@"
