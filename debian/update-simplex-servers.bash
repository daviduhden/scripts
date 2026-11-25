#!/bin/bash
set -euo pipefail

# Install or update the official SimpleX SMP and XFTP server binaries.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
readonly REPO=https://github.com/simplex-chat/simplexmq
readonly API=https://api.github.com/repos/simplex-chat/simplexmq/releases
readonly BIN_DIR=/usr/local/bin UNIT_DIR=/etc/systemd/system
readonly TOR_CONFIG=/etc/tor/torrc TOR_DATA=/var/lib/tor
readonly TOR_UNIT=tor@default.service
readonly XFTP_STORAGE=/srv/xftp
WORK=''
PENDING=''
UNIT_PENDING=''
CONFIG_PENDING=''
INIT_STAGE=''
TOR_PENDING=''
TOR_PREVIOUS=''
PREVIOUS=''
ACTIVATING=0

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null || error "Required command: $1"
}

usage() {
	cat <<'HELP'
Usage: update-simplex-servers {smp|xftp|all} [OPTIONS]

Install or update official SimpleX servers on Debian 13+ (amd64, arm64).
By default, new services remain disabled and updates restart active services.

Options:
  --setup-tor       Initialize new servers, configure Tor onion services
                    and enable and start the selected systemd units.
                    Installs Tor from APT if needed. Requires systemd IP filtering.
  --version TAG     Install a specific stable version (vX.Y.Z).
  -h, --help        Show this help message and exit.
HELP
}

cleanup() {
	local file
	if ((ACTIVATING)) && [[ -n $PREVIOUS ]]; then
		warn "Recovery binary retained at $PREVIOUS"
	else
		if [[ -n $PREVIOUS ]]; then rm -f -- "$PREVIOUS"; fi
	fi
	for file in "$PENDING" "$UNIT_PENDING" "$CONFIG_PENDING" "$TOR_PENDING" "$TOR_PREVIOUS"; do
		if [[ -n $file ]]; then rm -f -- "$file"; fi
	done
	if [[ -n $INIT_STAGE ]]; then rm -rf -- "$INIT_STAGE"; fi
	if [[ -n $WORK ]]; then
		rm -f -- "$WORK/release.json" "$WORK/download" "$WORK/tor-block" \
			"$WORK/tor-policy" "$WORK/init.log"
		rmdir -- "$WORK"
	fi
}

# Validate the full candidate with Debian's Tor defaults. Keep the original
# inode until systemd accepts the reload, so a failed reload can restore torrc.
configure_tor() {
	local name=$1 port=$2 directory=$TOR_DATA/$1 expected block
	local -a verify=(tor --verify-config --defaults-torrc /usr/share/tor/tor-service-defaults-torrc)
	printf 'HiddenServiceDir %s\nHiddenServicePort %s 127.0.0.1:%s\n' \
		"$directory" "$port" "$port" >"$WORK/tor-block"

	expected=$(<"$WORK/tor-block")
	if grep -Fxq "HiddenServiceDir $directory" "$TOR_CONFIG"; then
		# Only reuse the exact mapping written by this updater.
		block=$(sed -n "/^# BEGIN scripts $name\$/,/^# END scripts $name\$/p" "$TOR_CONFIG")
		[[ $block == "# BEGIN scripts $name"$'\n'"$expected"$'\n'"# END scripts $name" ]] ||
			error "Unexpected existing Tor configuration for $name"
		"${verify[@]}" -f "$TOR_CONFIG" >/dev/null || error 'Tor configuration is invalid'
		systemctl start "$TOR_UNIT"
		if [[ -s $directory/hostname ]]; then return; fi
		systemctl reload "$TOR_UNIT"
		return
	fi
	TOR_PENDING=$(mktemp "${TOR_CONFIG}.new.XXXXXXXX")
	cp -p -- "$TOR_CONFIG" "$TOR_PENDING"
	{
		printf '\n# BEGIN scripts %s\n' "$name"
		cat "$WORK/tor-block"
		printf '# END scripts %s\n' "$name"
	} >>"$TOR_PENDING"
	"${verify[@]}" -f "$TOR_PENDING" >/dev/null || error 'Tor configuration is invalid'
	TOR_PREVIOUS=$(mktemp "${TOR_CONFIG}.previous.XXXXXXXX")
	ln -fT -- "$TOR_CONFIG" "$TOR_PREVIOUS"
	mv -Tf -- "$TOR_PENDING" "$TOR_CONFIG"
	TOR_PENDING=''
	if ! systemctl reload-or-restart "$TOR_UNIT"; then
		if ! mv -Tf -- "$TOR_PREVIOUS" "$TOR_CONFIG"; then
			warn "Tor recovery configuration retained at $TOR_PREVIOUS"
			TOR_PREVIOUS=''
			error 'Could not restore the previous Tor configuration'
		fi
		TOR_PREVIOUS=''
		systemctl reload-or-restart "$TOR_UNIT" || warn 'Tor failed to reload its restored configuration'
		error "Tor failed to activate the onion service for $name"
	fi
	rm -f -- "$TOR_PREVIOUS"
	TOR_PREVIOUS=''
}

is_empty_directory() (
	shopt -s nullglob dotglob
	local -a entries=("$1"/*)
	(("${#entries[@]}" == 0))
)

# SOCKS5 CONNECT with a domain address asks Tor to resolve the onion name
# and open the service stream. Read only the reply header and send no data
# to SimpleX. The timeout covers connect, negotiation and rendezvous.
probe_onion() {
	timeout 12s /bin/bash -euo pipefail -s -- "$1" "$2" 2>/dev/null <<'SOCKS'
		exec 3<>/dev/tcp/127.0.0.1/9050
		printf "\005\001\000" >&3
		read -r version status < <(head -c 2 <&3 | od -An -tu1)
		[[ $version == 5 && $status == 0 ]]
		printf "\005\001\000\003\076%s" "$1" >&3
		printf "%b" "\\0$(printf "%03o" "$(($2 / 256))")\\0$(printf "%03o" "$(($2 % 256))")" >&3
		read -r version status reserved address_type < <(head -c 4 <&3 | od -An -tu1)
		[[ $version == 5 && $status == 0 && $reserved == 0 && $address_type =~ ^[134]$ ]]
SOCKS
}

setup_server() {
	local server=$1 config_dir=$2 data_dir=$3 uid=$4 gid=$5
	local name=$1-server ini='smp-server.ini' port=5223 hostname_file onion='' password='' line
	local dropin candidate attempt restart=0 active=0 prefix fresh_ini
	local -a init=(init)
	if [[ $server == xftp ]]; then
		ini='file-server.ini'
		port=443
		init+=(--path "$XFTP_STORAGE" --quota 20gb)
	else
		init+=(--yes --store-log --disable-web)
	fi
	ini=$config_dir/$ini
	dropin=$UNIT_DIR/$name.service.d
	[[ ! -L $dropin ]] || error "Unexpected systemd drop-in directory: $dropin"
	if [[ -e $dropin ]]; then prepare_directory "$dropin" 0 0; fi
	candidate=$WORK/tor-policy
	cat >"$candidate" <<UNIT
[Unit]
Wants=$TOR_UNIT
After=$TOR_UNIT

[Service]
IPAddressDeny=any
IPAddressAllow=localhost
UNIT
	if [[ -e $dropin/tor.conf || -L $dropin/tor.conf ]]; then
		if [[ ! -f $dropin/tor.conf || -L $dropin/tor.conf ]] ||
			! cmp -s "$candidate" "$dropin/tor.conf"; then
			error "Unexpected existing policy: $dropin/tor.conf"
		fi
	else
		if ! is_empty_directory "$config_dir" || ! is_empty_directory "$data_dir"; then
			error "Refusing to initialize $name over existing configuration or data"
		fi
		if [[ $server == xftp ]]; then
			is_empty_directory "$XFTP_STORAGE" || error 'Refusing to initialize over existing XFTP files'
		fi
	fi

	# Obtain the Tor hostname before deriving the SimpleX configuration and
	# certificate common name.
	configure_tor "$name" "$port"
	hostname_file=$TOR_DATA/$name/hostname
	for ((attempt = 0; attempt < 15; attempt++)); do
		if [[ -s $hostname_file ]] && read -r onion <"$hostname_file" &&
			[[ $onion =~ ^[a-z2-7]{56}\.onion$ ]]; then break; fi
		sleep 1
	done
	[[ $onion =~ ^[a-z2-7]{56}\.onion$ ]] || error "Tor did not create a valid hostname for $name"

	if [[ ! -f $ini ]]; then
		if ! is_empty_directory "$config_dir" || ! is_empty_directory "$data_dir"; then
			error "Incomplete initialization for $name, inspect $config_dir and $data_dir"
		fi
		# The vendor initializer can clear its configured directories. Give it
		# disposable paths beside the live config so publication is one rename.
		INIT_STAGE=$(mktemp -d "${config_dir}.init.XXXXXXXX")
		chmod 0711 "$INIT_STAGE"
		install -d -m 0700 -o "$uid" -g "$gid" "$INIT_STAGE/work"
		prefix=${server^^}_SERVER
		runuser -u "$server" -- env "${prefix}_CFG_PATH=$INIT_STAGE/work/config" \
			"${prefix}_LOG_PATH=$INIT_STAGE/work/log" \
			"$BIN_DIR/$name" "${init[@]}" --fqdn "$onion" >"$WORK/init.log" 2>&1 ||
			error "Could not initialize $name"
		fresh_ini=$INIT_STAGE/work/config/${ini##*/}
		[[ -d $INIT_STAGE/work/config && ! -L $INIT_STAGE/work/config &&
			-f $fresh_ini && ! -L $fresh_ini ]] || error "Initializer did not create $ini"
		CONFIG_PENDING=$(mktemp "$INIT_STAGE/config.XXXXXXXX")
		if [[ $server == xftp ]]; then password=$(openssl rand -hex 32); fi
		while IFS= read -r line || [[ -n $line ]]; do
			line=${line//"$INIT_STAGE/work/config"/"$config_dir"}
			line=${line//"$INIT_STAGE/work/log"/"$data_dir"}
			case "$server:$line" in
			'smp:port = 5223,443') line='port = 5223' ;;
			'xftp:[AUTH]')
				printf '%s\n' "$line"
				line="create_password = $password"
				;;
			esac
			printf '%s\n' "$line"
		done <"$fresh_ini" >"$CONFIG_PENDING"
		grep -Fxq "port = $port" "$CONFIG_PENDING" || error "Unexpected transport port in $ini"
		grep -Eq '^create_password = [^[:space:]]+$' "$CONFIG_PENDING" ||
			error "Missing creation password in $ini"
		chown "$uid:$gid" "$CONFIG_PENDING"
		mv -Tf -- "$CONFIG_PENDING" "$fresh_ini"
		CONFIG_PENDING=''
	fi
	prepare_directory "$dropin" 0 0
	if [[ ! -f $dropin/tor.conf ]]; then
		UNIT_PENDING=$(mktemp "$dropin/.tor.XXXXXXXX")
		install -m 0644 -- "$candidate" "$UNIT_PENDING"
		ln -T -- "$UNIT_PENDING" "$dropin/tor.conf"
		rm -f -- "$UNIT_PENDING"
		UNIT_PENDING=''
		restart=1
	fi
	if [[ -n $INIT_STAGE ]]; then
		grep -Fxq "host = $onion" "$fresh_ini" ||
			error "Initializer did not set the onion hostname for $name"
		chmod 0750 "$INIT_STAGE/work/config"
		# GNU mv rejects a nonempty destination, including concurrent edits.
		mv -Tf -- "$INIT_STAGE/work/config" "$config_dir"
		rm -rf -- "$INIT_STAGE"
		INIT_STAGE=''
	fi
	if [[ ! -f $ini || -L $ini ]] ||
		! grep -Fxq "host = $onion" "$ini" || ! grep -Fxq "port = $port" "$ini"; then
		error "Existing configuration for $name does not match its Tor mapping"
	fi
	systemctl daemon-reload
	if systemctl is-active --quiet "$name.service"; then
		active=1
		if ((restart)); then systemctl restart "$name.service"; fi
	else
		systemctl start "$name.service"
	fi
	systemctl is-active --quiet "$name.service" || error "$name did not start"
	for ((attempt = 0; attempt < 5; attempt++)); do
		if probe_onion "$onion" "$port"; then break; fi
		sleep 2
	done
	if ((attempt == 5)); then
		if ((active == 0)); then systemctl stop "$name.service" || warn "Could not stop $name"; fi
		error "Could not connect to $name at $onion:$port through Tor SOCKS on 127.0.0.1:9050"
	fi
	systemctl enable "$name.service"
	log "$name enabled at $onion:$port"
}

fetch() {
	curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--connect-timeout 15 --max-time 300 --retry 2 "$1" -o "$2"
}

prepare_directory() {
	local directory=$1 user=$2 group=$3
	if [[ -e $directory || -L $directory ]]; then
		[[ -d $directory && ! -L $directory &&
			$(stat -c '%u:%g' -- "$directory") == "$user:$group" ]] ||
			error "Unexpected directory owner or type: $directory"
	else
		install -d -m 0750 -o "$user" -g "$group" -- "$directory"
	fi
}

write_unit() {
	local server=$1 account=$2
	cat <<UNIT
[Unit]
Description=SimpleX ${server^^} server
After=network.target

[Service]
Type=simple
User=$account
Group=$account
ExecStart=$BIN_DIR/$server-server start +RTS -N -RTS
KillSignal=SIGINT
TimeoutStopSec=infinity
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
}

publish_server() {
	local server=$1 tag=$2 arch=$3 helper=$4 setup=${5:-0}
	local name="$1-server" account=$1 data=simplex asset url digest actual banner
	local binary unit uid gid active=0 same=0 mode target
	binary=$BIN_DIR/$name
	unit=$UNIT_DIR/$name.service
	if [[ $server == xftp ]]; then data=simplex-xftp; fi

	asset="$name-ubuntu-24_04-$arch"
	url="$REPO/releases/download/$tag/$asset"
	digest=$(perl "$helper" json-asset-digest "$url" <"$WORK/release.json") ||
		error "Release has no verified asset for $asset"
	[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || error "Missing SHA-256 for $asset"
	for target in "$binary" "$unit"; do
		if [[ -e $target || -L $target ]]; then
			[[ -f $target && ! -L $target && $(stat -c %u -- "$target") == 0 ]] ||
				error "Refusing to use an unexpected destination: $target"
			mode=$(stat -c %a -- "$target")
			(((8#$mode & 022) == 0)) || error "Destination is writable by others: $target"
		fi
	done
	if ((setup)) && [[ -f $unit ]]; then
		write_unit "$server" "$account" | cmp -s "$unit" ||
			error "Use the existing unit to configure $name manually: $unit"
	fi
	if [[ -f $binary ]]; then
		actual=$(sha256sum -- "$binary")
		if [[ ${actual%% *} == "${digest#sha256:}" ]]; then same=1; fi
	fi
	if ((same == 0)); then
		fetch "$url" "$WORK/download" || error "Download failed for $asset"
		actual=$(sha256sum -- "$WORK/download")
		[[ ${actual%% *} == "${digest#sha256:}" ]] || error "SHA-256 mismatch for $asset"
		PENDING=$(mktemp "$BIN_DIR/.$name.XXXXXXXX")
		install -m 0755 -- "$WORK/download" "$PENDING"
		banner=$(timeout --kill-after=2s 15s runuser -u nobody -- "$PENDING" --version 2>&1) ||
			error "$name cannot run on this host: $banner"
		[[ $banner == *"${tag#v}"* ]] || error "$name did not report $tag"
	fi
	if ! id "$account" >/dev/null 2>&1; then
		useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$account"
	fi
	uid=$(id -u "$account")
	gid=$(id -g "$account")
	[[ $uid != 0 && $gid != 0 && $(id -gn "$account") == "$account" ]] ||
		error "Unexpected service account or group: $account"
	prepare_directory "/etc/opt/$data" "$uid" "$gid"
	prepare_directory "/var/opt/$data" "$uid" "$gid"
	if [[ $server == xftp ]]; then prepare_directory "$XFTP_STORAGE" "$uid" "$gid"; fi

	if [[ ! -f $unit ]]; then
		UNIT_PENDING=$(mktemp "$UNIT_DIR/.$name.XXXXXXXX")
		write_unit "$server" "$account" >"$UNIT_PENDING"
		chmod 0644 "$UNIT_PENDING"
		ln -T -- "$UNIT_PENDING" "$unit"
		rm -f -- "$UNIT_PENDING"
		UNIT_PENDING=''
	fi
	systemctl daemon-reload
	if ((same)); then
		log "$name already matches $tag"
		if ((setup)); then setup_server "$server" "/etc/opt/$data" "/var/opt/$data" "$uid" "$gid"; fi
		return
	fi

	if systemctl is-active --quiet "$name.service"; then
		active=1
		[[ -f $binary ]] || error "Active $name has no managed binary at $binary"
	fi
	if [[ -f $binary ]]; then
		PREVIOUS=$(mktemp "$BIN_DIR/.$name.previous.XXXXXXXX")
		ln -fT -- "$binary" "$PREVIOUS"
	fi
	# Cleanup retains the previous inode if interrupted during activation.
	# The explicit rollback below handles a failed systemd restart.
	ACTIVATING=1
	mv -Tf -- "$PENDING" "$binary"
	PENDING=''
	if ((active)) && ! systemctl restart "$name.service"; then
		if ! mv -Tf -- "$PREVIOUS" "$binary"; then
			log "Recovery binary retained at $PREVIOUS"
			PREVIOUS=''
			error "Could not restore $name"
		fi
		PREVIOUS=''
		systemctl restart "$name.service" || error "Previous binary restored, but $name failed to restart"
		error "Update failed; previous $name binary restored"
	fi
	ACTIVATING=0
	if [[ -n $PREVIOUS ]]; then
		rm -f -- "$PREVIOUS"
		PREVIOUS=''
	fi
	log "$name $tag installed at $binary"
	if ((setup)); then setup_server "$server" "/etc/opt/$data" "/var/opt/$data" "$uid" "$gid"; fi
}

main() {
	local selection=${1:-} requested='' setup=0 endpoint tag arch script_dir helper command_name
	local -a arguments=("$@") servers
	case "$selection" in
	'' | --help | -h)
		usage
		return
		;;
	smp | xftp) servers=("$selection") ;;
	all) servers=(smp xftp) ;;
	*)
		usage >&2
		return 2
		;;
	esac
	shift
	while (($#)); do
		case "$1" in
		--setup-tor) setup=1 ;;
		--version)
			if [[ -n $requested || ! ${2:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				usage >&2
				return 2
			fi
			requested=$2
			shift
			;;
		-h | --help)
			usage
			return
			;;
		*)
			usage >&2
			return 2
			;;
		esac
		shift
	done

	# shellcheck disable=SC1091 # System-provided distribution metadata.
	source /etc/os-release
	if [[ ${ID:-} != debian || ! ${VERSION_ID:-} =~ ^[0-9]+$ ]] || ((VERSION_ID < 13)); then
		error 'Debian 13 or newer is required'
	fi
	case "$(dpkg --print-architecture)" in
	amd64) arch=x86-64 ;;
	arm64) arch=aarch64 ;;
	*) error 'Supported Debian architectures are amd64 and arm64' ;;
	esac
	if ((EUID != 0)); then
		exec /usr/bin/sudo -- /bin/bash "$(readlink -f -- "${BASH_SOURCE[0]}")" "${arguments[@]}"
	fi
	for command_name in curl perl sha256sum systemctl useradd runuser timeout flock; do
		require_cmd "$command_name"
	done
	umask 077
	exec 9>/run/update-simplex-servers.lock
	flock -n 9 || error 'Another SimpleX update is running'
	if ((setup)); then
		[[ -f /sys/fs/cgroup/cgroup.controllers ]] || error 'systemd IP filtering requires cgroup v2'
		if ! command -v tor >/dev/null || ! command -v openssl >/dev/null; then
			log 'Installing the Tor and OpenSSL prerequisites from APT'
			apt-get install --no-remove --no-upgrade tor openssl
		fi
		require_cmd tor
		require_cmd openssl
		[[ -f $TOR_CONFIG && ! -L $TOR_CONFIG && $(stat -c %u -- "$TOR_CONFIG") == 0 ]] ||
			error "Expected a regular root-owned Tor configuration at $TOR_CONFIG"
		[[ -r /usr/share/tor/tor-service-defaults-torrc ]] || error 'Install the Debian tor package first'
		[[ $(systemctl show -p LoadState --value "$TOR_UNIT") == loaded ]] ||
			error "Missing Debian Tor unit: $TOR_UNIT"
	fi
	script_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
	helper=$script_dir/release-verify
	if [[ ! -f $helper ]]; then helper=$script_dir/../scripts/release-verify.pl; fi
	[[ -f $helper ]] || error 'Missing release-verify helper'
	WORK=$(mktemp -d /tmp/update-simplex-servers.XXXXXXXX)
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM

	endpoint=$API/latest
	if [[ -n $requested ]]; then endpoint=$API/tags/$requested; fi
	fetch "$endpoint" "$WORK/release.json" || error 'Could not fetch SimpleX release metadata'
	tag=$(perl "$helper" json-tag <"$WORK/release.json") || error 'Invalid release metadata'
	[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && (-z $requested || $tag == "$requested") ]] ||
		error 'Expected a stable SimpleX release tag'
	for server in "${servers[@]}"; do publish_server "$server" "$tag" "$arch" "$helper" "$setup"; done
}

main "$@"
