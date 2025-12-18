#!/bin/ksh

# If we are NOT already running under ksh93, try to re-exec with ksh93.
# If ksh93 is not available, fall back to the base ksh (OpenBSD /bin/ksh).
case "${KSH_VERSION-}" in
*93*) : ;; # already ksh93
*)
	if command -v ksh93 >/dev/null 2>&1; then
		exec ksh93 "$0" "$@"
	elif [ -x /usr/local/bin/ksh93 ]; then
		exec /usr/local/bin/ksh93 "$0" "$@"
	elif command -v ksh >/dev/null 2>&1; then
		exec ksh "$0" "$@"
	elif [ -x /bin/ksh ]; then
		exec /bin/ksh "$0" "$@"
	fi
	;;
esac

set -eu

# OpenBSD sudo-wrapper script
# Compatibility shim that redirects sudo calls to doas and wraps visudo/sudoedit
# to be executed via doas as well.
#
# This script is intended to be installed as /usr/local/bin/sudo.
# You can also symlink it as:
#   - /usr/local/bin/visudo   → "visudo" (without an absolute path) goes through doas
#   - /usr/local/bin/sudoedit → "sudoedit" goes through doas
#
# Any script or program that runs "sudo ..." (without an absolute path)
# will effectively use doas instead.
#
# Notes:
# - Scripts that call an absolute sudo path will still use the real sudo
#   (if it exists on the system).
# - Privilege escalation is controlled by /etc/doas.conf, not /etc/sudoers.
# - The sudoedit behavior implemented here is a simplification:
#     * It runs your editor as root on the target files via doas,
#       instead of fully emulating sudoedit's temp-file semantics.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
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

log() { print "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${RESET} ✅ $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${RESET} ⚠️ $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${RESET} ❌ $*" >&2; }

ensure_doas() {
	typeset prog_name
	prog_name="$1"

	if command -v doas >/dev/null 2>&1; then
		return 0
	fi

	error "${prog_name}-wrapper error: 'doas' is not installed or not in PATH."
	error "Please install or enable doas before using this wrapper."
	exit 1
}

handle_visudo() {
	typeset real_visudo candidate

	real_visudo="/usr/local/sbin/visudo"

	if [ ! -x "$real_visudo" ]; then
		if command -v visudo >/dev/null 2>&1; then
			candidate=$(command -v visudo)
			if [ "$candidate" != "$0" ]; then
				real_visudo="$candidate"
			else
				real_visudo=""
			fi
		else
			real_visudo=""
		fi
	fi

	if [ -z "$real_visudo" ] || [ ! -x "$real_visudo" ]; then
		error "sudo-wrapper error: could not locate the real 'visudo' binary."
		error "Expected /usr/local/sbin/visudo or another executable visudo in PATH."
		exit 1
	fi

	export VISUDO_VIA_DOAS=1
	exec doas "$real_visudo" "$@"
}

handle_sudoedit() {
	typeset editor
	typeset -a editor_cmd

	if [ "$#" -lt 1 ]; then
		error "Usage: sudoedit FILE..."
		exit 1
	fi

	editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"

	set -A editor_cmd -- "$editor"

	if [ "${#editor_cmd[@]}" -eq 0 ] || [ -z "${editor_cmd[0]:-}" ]; then
		error "sudo-wrapper error: editor is empty."
		exit 1
	fi

	if ! command -v "${editor_cmd[0]}" >/dev/null 2>&1; then
		error "sudo-wrapper error: editor '${editor_cmd[0]}' not found in PATH."
		exit 1
	fi

	export SUDOEDIT_VIA_DOAS=1
	exec doas "${editor_cmd[@]}" "$@"
}

handle_sudo() {
	export SUDO_VIA_DOAS=1
	export SUDO_PREFER_DOAS=1
	exec doas "$@"
}

main() {
	typeset prog_name
	prog_name=$(basename -- "$0")

	ensure_doas "$prog_name"

	case "$prog_name" in
	visudo)
		handle_visudo "$@"
		;;
	sudoedit)
		handle_sudoedit "$@"
		;;
	*)
		handle_sudo "$@"
		;;
	esac
}

main "$@"
