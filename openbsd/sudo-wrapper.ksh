#!/bin/ksh
set -eu

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

# Prefer ksh93 when available; fallback to base ksh
if [ -z "${_KSH93_EXECUTED:-}" ] && command -v ksh93 >/dev/null 2>&1; then
    _KSH93_EXECUTED=1 exec ksh93 "$0" "$@"
fi
_KSH93_EXECUTED=1

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

typeset prog_name real_visudo candidate editor
typeset -a editor_cmd

# Detect how this script was called (sudo vs visudo vs sudoedit, etc.)
prog_name=$(basename -- "$0")

# Fail fast if doas is not available in PATH.
if ! command -v doas >/dev/null 2>&1; then
    error "${prog_name}-wrapper error: 'doas' is not installed or not in PATH."
    error "Please install or enable doas before using this wrapper."
    exit 1
fi

##########################################
# Special handling when called as visudo #
##########################################
if [ "$prog_name" = "visudo" ]; then
    #
    # We want to execute the real visudo binary with elevated privileges
    # using doas, while avoiding recursive calls back into this wrapper.
    #

    # Preferred path for visudo as installed from packages on OpenBSD
    real_visudo="/usr/local/sbin/visudo"

    # If that path doesn't exist, fall back to command -v
    if [ ! -x "$real_visudo" ]; then
        if command -v visudo >/dev/null 2>&1; then
            candidate=$(command -v visudo)
            # Avoid picking ourselves (in case the symlink is found in PATH)
            if [ "$candidate" != "$0" ]; then
                real_visudo="$candidate"
            else
                real_visudo=""
            fi
        else
            real_visudo=""
        fi
    fi

    # Final sanity check
    if [ -z "$real_visudo" ] || [ ! -x "$real_visudo" ]; then
        error "sudo-wrapper error: could not locate the real 'visudo' binary."
        error "Expected /usr/local/sbin/visudo or another executable visudo in PATH."
        exit 1
    fi

    # Export a hint variable for tools/scripts
    export VISUDO_VIA_DOAS=1

    # Execute real visudo via doas as root
    exec doas "$real_visudo" "$@"
    # We should never reach here
    exit 1
fi

############################################
# Special handling when called as sudoedit #
############################################
if [ "$prog_name" = "sudoedit" ]; then
    #
    # Simplified sudoedit emulation:
    #   - Determine the editor from SUDO_EDITOR / VISUAL / EDITOR / vi.
    #   - Run that editor as root via doas on the given files.
    #
    # This does NOT implement sudoedit's temp-file semantics, but for
    # common "sudoedit /etc/foo" usage it behaves as "edit this file as root".
    #

    if [ "$#" -lt 1 ]; then
        error "Usage: sudoedit FILE..."
        exit 1
    fi

    # Determine preferred editor
    editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"

    # Split editor into an argument array (handles things like "code -w")
    # shellcheck disable=SC2086
    set -A editor_cmd -- $editor

    if [ "${#editor_cmd[@]}" -eq 0 ] || [ -z "${editor_cmd[0]:-}" ]; then
        error "sudo-wrapper error: editor is empty."
        exit 1
    fi

    # Check that the base command exists
    if ! command -v "${editor_cmd[0]}" >/dev/null 2>&1; then
        error "sudo-wrapper error: editor '${editor_cmd[0]}' not found in PATH."
        exit 1
    fi

    # Hint variable for scripts/tools
    export SUDOEDIT_VIA_DOAS=1

    # Run the editor as root via doas on the requested files.
    # editor_cmd may contain extra args (e.g. 'code -w'); then we append "$@".
    exec doas "${editor_cmd[@]}" "$@"
    exit 1
fi

################################
# Default path: called as sudo #
################################

# Informational variable so scripts can detect that sudo is being redirected.
export SUDO_VIA_DOAS=1

# Informational variable if you want to standardize on doas.
export SUDO_PREFER_DOAS=1

# Optional: log when this wrapper is used, for auditing or debugging.
# Uncomment the line below if you want syslog entries.
# logger -t sudo-doas-wrapper "sudo invoked as doas by user '${USER:-unknown}' with args: $*"

# Finally, exec doas with all the arguments passed to sudo.
exec doas "$@"
