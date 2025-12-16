#!/bin/bash

if [[ -z ${ZSH_VERSION:-} ]] && command -v zsh >/dev/null 2>&1; then
	exec zsh "$0" "$@"
fi

# Simple log helpers
# -- Silent runner for scripts: capture stdout/stderr and only print on error.
# Also provides simple log helpers and a package installer for Debian and Fedora.
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
warn() { printf '%b\n' "${YELLOW}⚠️ ${RESET}%s" "$*" >&2; }
error() { printf '%b\n' "${RED}❌ ${RESET}%s" "$*" >&2; }

_SILENT_OUT=""
_SILENT_ERR=""

silent_trap() {
	local _code=$?
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
	if [[ -n $_SILENT_OUT && -n $_SILENT_ERR ]]; then
		exec 1>&3 2>&4
		rm -f "$_SILENT_OUT" "$_SILENT_ERR" || true
		unset _SILENT_OUT _SILENT_ERR
		trap - EXIT
	fi
}
