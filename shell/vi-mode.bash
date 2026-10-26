# shellcheck shell=bash
# ==================================================
# Enable vi mode in Bash
# Loaded from ~/.bashrc.d
# ==================================================
# This file is sourced, not executed. Sourcing it changes the current
# interactive shell: it enables vi key bindings and exports EDITOR and VISUAL
# when those variables are not already set.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# If this is not an interactive shell, do nothing. Use return rather than
# exit so sourcing from a non-interactive context does not terminate it.
case $- in
*i*) ;;
*) return 0 ;;
esac

# Make sure we are running in Bash before using Bash-only settings.
[ -n "${BASH_VERSION-}" ] || return 0

# Enable vi mode for command-line editing in this shell.
set -o vi

# Set EDITOR / VISUAL only if they are not defined yet. The := form also
# treats an empty value as unset; export both so child programs inherit them.
: "${EDITOR:=vim}"
: "${VISUAL:=kak}"
export EDITOR VISUAL
