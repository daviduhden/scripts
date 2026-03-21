#!/usr/bin/env bash
set -euo pipefail

# SecureBlue sudo-wrapper script
# Compatibility shim that redirects sudo calls to run0
# and wraps visudo via run0, and sudoedit via run0edit (safe graphical/root editor).
#
# This script is intended to be installed as /usr/local/bin/sudo
# so that it appears earlier in $PATH than /usr/bin/sudo.
#
# You can also symlink it as:
#   - /usr/local/bin/visudo   → visudo goes through run0
#   - /usr/local/bin/sudoedit → sudoedit goes through run0edit
#
# Any script or program that runs "sudo ..." (without an absolute path)
# will effectively use run0 instead.
#
# Notes:
# - This does NOT modify /usr/bin/sudo or /usr/sbin/visudo.
# - Scripts that call /usr/bin/sudo explicitly will still use the real sudo (if it exists).
# - Permission handling is controlled by polkit (run0), not /etc/sudoers.
# - sudoedit here uses run0edit, which provides safe/graphical editing as root.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found in PATH."
}

handle_visudo() {
	local real_visudo="$1"
	if [[ ! -x $real_visudo ]]; then
		error "sudo-wrapper error: could not locate the real 'visudo' binary. Expected /usr/sbin/visudo or another executable visudo in PATH."
	fi
	export VISUDO_VIA_RUN0=1
	exec run0 "$real_visudo" "$@"
}

resolve_real_visudo() {
	local real_visudo="/usr/sbin/visudo"
	if [[ ! -x $real_visudo ]]; then
		local real_visudo_found
		real_visudo_found="$(command -v visudo 2>/dev/null || true)"
		if [[ -n $real_visudo_found && $real_visudo_found != "$0" ]]; then
			real_visudo="$real_visudo_found"
		fi
	fi
	printf '%s\n' "$real_visudo"
}

handle_sudoedit() {
	if [[ $# -lt 1 ]]; then
		error "Usage: sudoedit FILE..."
	fi

	local editor
	editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-}}}"
	local run0edit_args=()
	if [[ -n $editor ]]; then
		run0edit_args+=(--editor "$editor")
	fi

	export SUDOEDIT_VIA_RUN0=1
	exec run0edit "${run0edit_args[@]}" "$@"
}

handle_default_sudo() {
	export SUDO_VIA_RUN0=1
	export SUDO_PREFER_RUN0=1
	exec run0 "$@"
}

dispatch_by_prog_name() {
	local prog_name="$1"
	shift

	if [[ $prog_name == "visudo" ]]; then
		handle_visudo "$(resolve_real_visudo)" "$@"
	fi
	if [[ $prog_name == "sudoedit" ]]; then
		handle_sudoedit "$@"
	fi
	handle_default_sudo "$@"
}

main() {
	local prog_name
	prog_name="$(basename -- "$0")"

	require_cmd run0
	dispatch_by_prog_name "$prog_name" "$@"
}

main "$@"
