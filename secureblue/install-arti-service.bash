#!/bin/bash
set -euo pipefail

# SecureBlue arti.service installation helper.
#
# Installs Arti as a systemd *user* service for the account running this
# script: it copies the bundled unit template, creates XDG config/data/state/
# cache directories, fetches the upstream example configuration, and enables
# and starts the unit with systemctl --user. No root or run0 is used, but a
# working user systemd session is required.
#
# The configuration URL follows the installed Arti version (tag
# arti-vX.Y.Z). If the version cannot be determined or the tag download
# fails, it falls back to the main branch. The download is protected by TLS
# but is not checked against a separate checksum or signature. An existing
# configuration is preserved unless --replace-config is selected. Publication
# is rolled back if the unit cannot be activated; Python 3.11+ validates TOML.
#
# If socat is installed, the optional arti-socks-proxy.service bridge is
# installed too; bridge failures are warnings and do not fail the main unit.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not available"
		exit 1
	fi
}

# Fail on HTTP errors, follow redirects, and retry transient network failures.
# TLS verification is left at curl's defaults.
net_curl() {
	curl -fLsS --retry 5 "$@"
}

# Templates are installed next to the scripts as a systemd/ subdirectory, so
# resolve them relative to this file rather than the current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/systemd/arti.service"
BRIDGE_SRC="${SCRIPT_DIR}/systemd/arti-socks-proxy.service"
# The Makefile installs unit templates under PREFIX/lib/systemd/user; keep
# the sibling layout for running directly from a checkout.
if [[ ! -f $SERVICE_SRC ]]; then
	SERVICE_SRC="${SCRIPT_DIR}/../lib/systemd/user/arti.service"
	BRIDGE_SRC="${SCRIPT_DIR}/../lib/systemd/user/arti-socks-proxy.service"
fi
ARTI_HELPER="${SCRIPT_DIR}/arti-config.py"
if [[ ! -f $ARTI_HELPER ]]; then
	ARTI_HELPER="${SCRIPT_DIR}/../libexec/scripts/arti-config.py"
fi
ARTI_REPO_RAW="https://gitlab.torproject.org/tpo/core/arti/-/raw"
ARTI_EXAMPLE_PATH="crates/arti/src/arti-example-config.toml"

# Choose the ref whose example config matches the installed Arti. Prefer the
# release tag for the running version (arti-vX.Y.Z); fall back to main when the
# version cannot be determined.
detect_arti_ref() {
	local arti_bin version
	arti_bin="$(command -v arti 2>/dev/null || true)"
	if [[ -z $arti_bin && -x /usr/local/bin/arti ]]; then
		arti_bin=/usr/local/bin/arti
	fi
	if [[ -n $arti_bin ]]; then
		version="$("$arti_bin" --version 2>/dev/null |
			sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p')"
		if [[ -n $version ]]; then
			printf 'arti-v%s\n' "$version"
			return 0
		fi
	fi
	printf 'main\n'
}

config_url_for_ref() {
	printf '%s/%s/%s\n' "$ARTI_REPO_RAW" "$1" "$ARTI_EXAMPLE_PATH"
}

check_prereqs() {
	require_cmd systemctl
	require_cmd curl
	require_cmd python3
	require_cmd systemd-analyze
	[[ -f $ARTI_HELPER ]] || {
		error "arti-config.py helper not found"
		exit 1
	}
	python3 "$ARTI_HELPER" validate /dev/null || {
		error "Python 3.11+ with tomllib is required"
		exit 1
	}
	if [[ ! -f $SERVICE_SRC ]]; then
		error "service file not found at $SERVICE_SRC"
		exit 1
	fi
}

# Resolve every location once so the unit file and the directories created
# below agree even when the user overrides XDG_*_HOME.
setup_paths() {
	SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arti"
	CONFIG_FILE="${CONFIG_DIR}/arti.toml"
	DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/arti"
	STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arti"
	CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arti"
	local directory
	for directory in "$SYSTEMD_USER_DIR" "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"; do
		[[ $directory == /* ]] || {
			error 'XDG paths must be absolute'
			exit 1
		}
	done
}

# Render each complete path as a quoted systemd argument. Percent signs are
# escaped as specifiers, and command arguments also escape dollar expansion.
render_unit() {
	python3 "$ARTI_HELPER" render \
		"$1" "$2" "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"
}

cleanup_arti_stage() {
	if [[ -n ${ARTI_NEW_FILE:-} ]]; then rm -f -- "$ARTI_NEW_FILE"; fi
	rm -rf -- "$ARTI_STAGE"
}

rollback_arti_install() {
	local name
	for name in arti.service arti.toml; do
		local target="$SYSTEMD_USER_DIR/$name"
		[[ $name == arti.toml ]] && target="$CONFIG_FILE"
		if [[ -f $ARTI_STAGE/old-$name ]]; then
			cp -p -- "$ARTI_STAGE/old-$name" "$target" || warn "Could not restore $target"
		elif [[ -f $ARTI_STAGE/new-$name ]]; then
			rm -f -- "$target"
		fi
	done
	systemctl --user daemon-reload || warn 'Could not reload restored unit'
	if [[ $ARTI_WAS_ENABLED == no ]]; then
		systemctl --user disable arti.service || warn 'Could not restore disabled state'
	fi
	if [[ $ARTI_WAS_ACTIVE == yes ]]; then
		systemctl --user restart arti.service || warn 'Could not restart restored Arti'
	else
		systemctl --user stop arti.service || warn 'Could not restore stopped state'
	fi
}

install_arti_unit_and_config() {
	install -d -m 0750 "$SYSTEMD_USER_DIR" "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"
	ARTI_STAGE=$(mktemp -d "$SYSTEMD_USER_DIR/.arti-install.XXXXXX")
	trap 'cleanup_arti_stage' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	render_unit "$SERVICE_SRC" "$ARTI_STAGE/arti.service"
	systemd-analyze --user verify "$ARTI_STAGE/arti.service"
	if [[ -e $CONFIG_FILE && ! -f $CONFIG_FILE ]]; then
		error "Configuration is not a regular file: $CONFIG_FILE"
		return 1
	fi
	if [[ -f $CONFIG_FILE && $REPLACE_CONFIG == 0 ]]; then
		log "Preserving existing configuration: $CONFIG_FILE"
	else
		local arti_ref config_url
		arti_ref=$(detect_arti_ref)
		config_url=$(config_url_for_ref "$arti_ref")
		if ! net_curl "$config_url" -o "$ARTI_STAGE/arti.toml"; then
			config_url=$(config_url_for_ref main)
			net_curl "$config_url" -o "$ARTI_STAGE/arti.toml" || return 1
		fi
	fi
	local config_to_check="$CONFIG_FILE"
	[[ -f $ARTI_STAGE/arti.toml ]] && config_to_check="$ARTI_STAGE/arti.toml"
	python3 "$ARTI_HELPER" validate "$config_to_check"
	ARTI_WAS_ACTIVE=no
	ARTI_WAS_ENABLED=no
	if systemctl --user is-active --quiet arti.service; then ARTI_WAS_ACTIVE=yes; fi
	if systemctl --user is-enabled --quiet arti.service; then ARTI_WAS_ENABLED=yes; fi
	local name target
	for name in arti.service arti.toml; do
		target="$SYSTEMD_USER_DIR/$name"
		[[ $name == arti.toml ]] && target="$CONFIG_FILE"
		[[ -f $ARTI_STAGE/$name ]] || continue
		if [[ -e $target || -L $target ]]; then
			[[ -f $target && ! -L $target ]] || {
				error "Refusing nonregular target $target"
				return 1
			}
			cp -p -- "$target" "$ARTI_STAGE/old-$name"
		fi
	done
	if [[ -f $ARTI_STAGE/old-arti.toml ]]; then
		local backup
		backup=$(mktemp "${CONFIG_FILE}.bak.XXXXXX")
		cp -p -- "$ARTI_STAGE/old-arti.toml" "$backup"
		log "Configuration backup: $backup"
	fi
	# Register rollback before the first publication, including signals.
	trap 'rollback_arti_install; cleanup_arti_stage' EXIT
	for name in arti.toml arti.service; do
		[[ -f $ARTI_STAGE/$name ]] || continue
		target="$SYSTEMD_USER_DIR/$name"
		[[ $name == arti.toml ]] && target="$CONFIG_FILE"
		: >"$ARTI_STAGE/new-$name"
		ARTI_NEW_FILE=$(mktemp "${target}.new.XXXXXX")
		install -m 0640 "$ARTI_STAGE/$name" "$ARTI_NEW_FILE"
		mv -f -- "$ARTI_NEW_FILE" "$target"
		ARTI_NEW_FILE=''
	done
}

enable_arti_service() {
	systemctl --user daemon-reload
	systemctl --user enable --now arti.service
	if [[ $ARTI_WAS_ACTIVE == yes ]]; then systemctl --user restart arti.service; fi
	trap 'cleanup_arti_stage' EXIT
}

# The bridge exposes Arti's TCP SOCKS port through a user-local UNIX socket for
# clients that prefer a socket path; skip it cleanly when socat or the optional
# unit template is absent.
maybe_install_bridge_service() {
	if ! command -v socat >/dev/null 2>&1 || [[ ! -f $BRIDGE_SRC ]]; then
		warn 'socat or bridge template unavailable; skipping optional bridge'
		return
	fi
	local unit="$SYSTEMD_USER_DIR/arti-socks-proxy.service" active=no enabled=no
	local prepared="$ARTI_STAGE/arti-socks-proxy.service"
	if ! render_unit "$BRIDGE_SRC" "$prepared" ||
		! systemd-analyze --user verify "$prepared"; then
		warn 'Could not validate optional bridge; previous unit preserved'
		return
	fi
	if [[ -e $unit || -L $unit ]]; then
		[[ -f $unit && ! -L $unit ]] || {
			warn 'Refusing nonregular bridge unit'
			return
		}
		cp -p -- "$unit" "$ARTI_STAGE/old-bridge"
	fi
	if systemctl --user is-active --quiet arti-socks-proxy.service; then active=yes; fi
	if systemctl --user is-enabled --quiet arti-socks-proxy.service; then enabled=yes; fi
	ARTI_NEW_FILE=$(mktemp "${unit}.new.XXXXXX")
	install -m 0640 "$prepared" "$ARTI_NEW_FILE"
	mv -f -- "$ARTI_NEW_FILE" "$unit"
	ARTI_NEW_FILE=''
	if systemctl --user daemon-reload &&
		systemctl --user enable --now arti-socks-proxy.service &&
		{ [[ $active == no ]] || systemctl --user restart arti-socks-proxy.service; }; then
		log 'Optional bridge enabled and running'
		return
	fi
	warn 'Bridge activation failed; restoring previous optional unit'
	if [[ -f $ARTI_STAGE/old-bridge ]]; then
		cp -p -- "$ARTI_STAGE/old-bridge" "$unit"
	else
		rm -f -- "$unit"
	fi
	systemctl --user daemon-reload || true
	if [[ $enabled == no ]]; then systemctl --user disable arti-socks-proxy.service || true; fi
	if [[ $active == yes ]]; then
		systemctl --user restart arti-socks-proxy.service || true
	else
		systemctl --user stop arti-socks-proxy.service || true
	fi
}

run_install() {
	setup_paths
	install_arti_unit_and_config
	enable_arti_service
	maybe_install_bridge_service
	log "arti.service installed, enabled, and running."
}

main() {
	REPLACE_CONFIG=0
	case "${1:-}" in
	--replace-config)
		REPLACE_CONFIG=1
		shift
		;;
	esac
	[[ $# == 0 ]] || {
		error 'Usage: install-arti-service [--replace-config]'
		exit 1
	}
	check_prereqs
	run_install
}

main "$@"
