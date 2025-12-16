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

# Simple log helpers
# -- Silent runner for scripts: capture stdout/stderr and only print on error.
# Also provides simple log helpers and a package installer for OpenBSD.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# ANSI color and emoji helpers (enabled only when stdout is a tty)
if [ -t 1 ]; then
	RED="\033[31m"
	YELLOW="\033[33m"
	BLUE="\033[34m"
	RESET="\033[0m"
else
	RED=""
	YELLOW=""
	BLUE=""
	RESET=""
fi

log() { printf '%b\n' "${BLUE}ℹ️ ${RESET}%s" "$*"; }
warn() { printf '%b\n' "${YELLOW}⚠️ ${RESET}%s" "$*" 1>&2; }
error() {
	printf '%b\n' "${RED}❌ ${RESET}%s" "$*" 1>&2
	exit 1
}

_SILENT_OUT=""
_SILENT_ERR=""

silent_trap() {
	typeset _code=$?
	exec 1>&3 2>&4
	if [ "$_code" -ne 0 ]; then
		printf "%b\n" "${RED}‼️ Error during command, captured output:${RESET}" >&2
		cat "$_SILENT_OUT" >&1
		cat "$_SILENT_ERR" >&2
	fi
	rm -f "$_SILENT_OUT" "$_SILENT_ERR"
	exit "$_code"
}

start_silence() {
	_SILENT_OUT=$(mktemp) || return 1
	_SILENT_ERR=$(mktemp) || {
		rm -f "$_SILENT_OUT"
		return 1
	}
	exec 3>&1 4>&2
	exec 1>"$_SILENT_OUT" 2>"$_SILENT_ERR"
	trap 'silent_trap' EXIT
}

stop_silence() {
	if [ -n "$_SILENT_OUT" ] && [ -n "$_SILENT_ERR" ]; then
		exec 1>&3 2>&4
		rm -f "$_SILENT_OUT" "$_SILENT_ERR" || true
		_SILENT_OUT=""
		_SILENT_ERR=""
		trap - EXIT
	fi
}
