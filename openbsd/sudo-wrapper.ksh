#!/bin/ksh

set -eu

# OpenBSD sudo-wrapper script
# Compatibility shim that redirects sudo calls to doas
# and wraps visudo/sudoedit to be executed via doas as well.
#
# This script is intended to be installed as /usr/local/bin/sudo.
# You can also symlink it as:
#   - /usr/local/bin/visudo   -> "visudo" (without an absolute
#     path) goes through doas
#   - /usr/local/bin/sudoedit -> "sudoedit" goes through doas
#
# Any script or program that runs "sudo ..." (without an absolute path)
# will effectively use doas instead.
#
# Notes:
# - Scripts that call an absolute sudo path will still use the real sudo
#   (if it exists on the system).
# - Privilege escalation is controlled by /etc/doas.conf,
#   not /etc/sudoers.
# - The sudoedit behavior implemented here is a simplification:
#     * It runs your editor as root on the target files via doas,
#       instead of fully emulating sudoedit's temp-file semantics.
#
# The wrapper always hands control to doas with exec, so authentication,
# authorization, and the exit status come from doas, not from this script.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Timestamped message helpers using ksh's print builtin. Warnings and errors
# go to stderr; progress goes to stdout.
log() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}
warn() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >&2
}
error() {
	print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2
}

# Fail before exec when doas is unavailable, so the caller gets a clear
# error instead of a bare "command not found" for the elevated command.
ensure_doas() {
	typeset prog_name
	prog_name="$1"

	if command -v doas >/dev/null 2>&1; then
		return 0
	fi

	error "${prog_name}-wrapper error:" \
		"'doas' is not installed or not in PATH."
	error "Please install or enable doas before using this wrapper."
	exit 1
}

handle_visudo() {
	typeset real_visudo candidate

	# The real visudo is expected under /usr/local/sbin, the usual
	# location when sudo is installed from ports. If it is missing, fall
	# back to the first visudo in PATH, but reject a result that is this
	# wrapper itself: running doas on the shim again would not open the
	# editor.
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
		error "sudo-wrapper error: could not locate" \
			"the real 'visudo' binary."
		error "Expected /usr/local/sbin/visudo or another" \
			"executable visudo in PATH."
		exit 1
	fi

	# exec replaces this shell with doas, so no wrapper process remains
	# between the caller and the editor and the exit status is doas's.
	export VISUDO_VIA_DOAS=1
	exec doas "$real_visudo" "$@"
}

handle_sudoedit() {
	typeset editor
	typeset editor_cmd

	if [ "$#" -lt 1 ]; then
		error "Usage: sudoedit FILE..."
		exit 1
	fi

	# Editor precedence matches sudoedit: SUDO_EDITOR, then VISUAL, then
	# EDITOR, with vi as the last resort.
	editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"

	# Split the editor string on whitespace so values such as
	# "vi -u NONE" or "code --wait" work, matching the Bash wrapper.
	# shellcheck disable=SC2086
	set -A editor_cmd -- $editor

	if [ -z "${editor_cmd[0]:-}" ]; then
		error "sudo-wrapper error: editor is empty."
		exit 1
	fi

	# Check only the program word; arguments and flags were split above.
	if ! command -v "${editor_cmd[0]}" >/dev/null 2>&1; then
		error "sudo-wrapper error:" \
			"editor '${editor_cmd[0]}' not found in PATH."
		exit 1
	fi

	# The editor runs as root on the real files, so unsaved changes are
	# written in place rather than through sudoedit's temporary copies.
	export SUDOEDIT_VIA_DOAS=1
	exec doas "${editor_cmd[@]}" "$@"
}

# Any other invocation (normally the name sudo) passes its arguments to
# doas unchanged; /etc/doas.conf decides what is permitted.
handle_sudo() {
	export SUDO_VIA_DOAS=1
	export SUDO_PREFER_DOAS=1
	exec doas "$@"
}

main() {
	typeset prog_name
	prog_name=$(basename "$0")

	# The installed name selects the mode, so one script can serve as
	# sudo, visudo, and sudoedit through symlinks. Any other name is
	# treated as sudo.
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
