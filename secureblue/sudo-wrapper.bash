#!/usr/bin/env bash
set -euo pipefail

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
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

# Detect how this script was called (sudo vs visudo vs sudoedit, etc.)
prog_name="$(basename -- "$0")"

# Optional: fail fast if run0 is not available in PATH.
if ! command -v run0 >/dev/null 2>&1; then
    error "${prog_name}-wrapper error: 'run0' is not installed or not in PATH. Please install or enable run0 before using this wrapper."
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
        error "sudo-wrapper error: could not locate the real 'visudo' binary. Expected /usr/sbin/visudo or another executable visudo in PATH."
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
    #   - Use run0edit for graphical/safe editing as root.
    #
    if [[ "$#" -lt 1 ]]; then
        error "Usage: sudoedit FILE..."
    fi

    # Determine preferred editor (pass to run0edit)
    editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-}}}"
    run0edit_args=()
    if [[ -n "$editor" ]]; then
        run0edit_args+=(--editor "$editor")
    fi

    export SUDOEDIT_VIA_RUN0=1
    exec run0edit "${run0edit_args[@]}" "$@"
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
