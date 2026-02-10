# shellcheck shell=bash
# ==================================================
# Enable vi mode in Bash
# Loaded from ~/.bashrc.d
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# If this is not an interactive shell, do nothing
case $- in
*i*) ;;
*) return 0 ;;
esac

# Make sure we are running in Bash
[ -n "${BASH_VERSION-}" ] || return 0

# Enable vi mode in Bash
set -o vi

# Set EDITOR / VISUAL only if they are not defined yet
: "${EDITOR:=vi}"
: "${VISUAL:=$EDITOR}"
export EDITOR VISUAL
