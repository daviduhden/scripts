#!/bin/bash

#
# Compatibility shim that redirects sudo calls to run0
# and wraps visudo and sudoedit to be executed via run0 as well.
#
# This script is intended to be installed as /usr/local/bin/sudo
# so that it appears earlier in $PATH than /usr/bin/sudo.
#
# You can also symlink it as:
#   - /usr/local/bin/visudo   → visudo goes through run0
#   - /usr/local/bin/sudoedit → sudoedit goes through run0
#
# Any script or program that runs "sudo ..." (without an absolute path)
# will effectively use run0 instead.
#
# Notes:
# - This does NOT modify /usr/bin/sudo or /usr/sbin/visudo themselves.
# - Scripts that call /usr/bin/sudo explicitly will still use the real sudo
#   (if it exists on the system).
# - Permission handling is controlled by polkit (run0), not /etc/sudoers.
# - The sudoedit behavior implemented here is a simplification:
#     * It runs your editor as root on the target files via run0,
#       instead of fully emulating sudoedit's temp-file semantics.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Bash safety settings
set -o errexit   # exit on any unhandled error
set -o nounset   # treat use of unset variables as an error
set -o pipefail  # propagate pipeline errors

# Detect how this script was called (sudo vs visudo vs sudoedit, etc.)
prog_name="$(basename -- "$0")"

# Optional: fail fast if run0 is not available in PATH.
if ! command -v run0 >/dev/null 2>&1; then
    echo "${prog_name}-wrapper error: 'run0' is not installed or not in PATH." >&2
    echo "Please install or enable run0 before using this wrapper." >&2
    exit 1
fi

##########################################
# Special handling when called as visudo #
##########################################
if [[ "$prog_name" == "visudo" ]]; then
    #
    # We want to execute the real visudo binary with elevated privileges
    # using run0, while avoiding recursive calls back into this wrapper.
    #

    # Preferred hard-coded path to the real visudo
    real_visudo="/usr/sbin/visudo"

    # If for some reason that path doesn't exist, fall back to command -v,
    # but try to avoid picking up /usr/local/bin/visudo (this wrapper).
    if [[ ! -x "$real_visudo" ]]; then
        # Look up visudo in PATH
        real_visudo_found="$(command -v visudo 2>/dev/null || true)"

        # If command -v returned our own path, we still have a problem,
        # so double-check that it is not this script.
        if [[ -n "$real_visudo_found" && "$real_visudo_found" != "$0" ]]; then
            real_visudo="$real_visudo_found"
        fi
    fi

    # Final sanity check
    if [[ ! -x "$real_visudo" ]]; then
        echo "sudo-wrapper error: could not locate the real 'visudo' binary." >&2
        echo "Expected /usr/sbin/visudo or another executable visudo in PATH." >&2
        exit 1
    fi

    # Optional hint variable
    export VISUDO_VIA_RUN0=1

    # Execute real visudo via run0 as root
    exec run0 "$real_visudo" "$@"
    # We should never reach here
    exit 1
fi

############################################
# Special handling when called as sudoedit #
############################################
if [[ "$prog_name" == "sudoedit" ]]; then
    #
    # Simplified sudoedit emulation:
    #   - Determine the editor from SUDO_EDITOR / VISUAL / EDITOR / vi.
    #   - Run that editor as root via run0 on the given files.
    #
    # This does NOT implement sudoedit's temp-file semantics, but for
    # common "sudoedit /etc/foo" usage it behaves as "edit this file as root".
    #

    if [[ "$#" -lt 1 ]]; then
        echo "Usage: sudoedit FILE..." >&2
        exit 1
    fi

    # Determine preferred editor
    editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"

    # Split editor into argv array (supports things like 'code -w')
    # shellcheck disable=SC2206
    editor_cmd=($editor)

    if [[ "${#editor_cmd[@]}" -eq 0 ]]; then
        echo "sudo-wrapper error: editor is empty." >&2
        exit 1
    fi

    # Check that the base command exists
    if ! command -v "${editor_cmd[0]}" >/dev/null 2>&1; then
        echo "sudo-wrapper error: editor '${editor_cmd[0]}' not found in PATH." >&2
        exit 1
    fi

    # Optional hint variable
    export SUDOEDIT_VIA_RUN0=1

    # Run the editor as root via run0 on the requested files
    # editor_cmd may contain extra arguments (e.g. 'code -w'), then we append file list "$@"
    exec run0 "${editor_cmd[@]}" "$@"
    exit 1
fi

################################
# Default path: called as sudo #
################################

# Export a variable so scripts can detect that sudo is being redirected to run0.
# This is purely informational and has no effect on run0 itself.
export SUDO_VIA_RUN0=1

# Export variable indicating that run0 is preferred over sudo.
# This can also be set globally (e.g. /etc/profile.d), but setting it here
# ensures it is present in environments spawned via this wrapper.
export SUDO_PREFER_RUN0=1

# Optional: log when this wrapper is used, for auditing or debugging.
# Comment this line out if you do not want extra log entries.
# logger -t sudo-wrapper "sudo invoked as run0 by user '${USER:-unknown}' with args: $*"

# Finally, exec run0 with all the arguments passed to sudo.
# 'exec' replaces the current shell process with run0, keeping PID behavior clean.
exec run0 "$@"
