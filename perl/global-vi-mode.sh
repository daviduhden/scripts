#
# This script is intended to reside in /etc/profile.d/global-vi-mode.sh
# so that it is sourced system-wide for login and interactive shells.
#
# It enables vi-style line editing for bash, zsh and ksh, and sets
# a default EDITOR/VISUAL if they are not already defined.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#


# If this is not an interactive shell, do nothing
case $- in
    *i*) ;;
    *)
        # Use 'return' when sourced, fall back to 'exit' if executed directly
        return 0 2>/dev/null || exit 0
        ;;
esac

####################
# bash integration #
####################
if [ -n "${BASH_VERSION-}" ]; then
    # Enable vi mode for bash readline
    set -o vi
fi

###################
# zsh integration #
###################
if [ -n "${ZSH_VERSION-}" ]; then
    # Enable vi key bindings in zsh
    # 'bindkey -v' switches to vi-style line editing
    bindkey -v 2>/dev/null || true
fi

###################
# ksh integration #
###################
if [ -n "${KSH_VERSION-}" ]; then
    # Enable vi mode in ksh
    set -o vi
fi

########################################
# Set global editor if not defined yet #
########################################
if [ -z "${EDITOR-}" ]; then
    export EDITOR=vi
fi

if [ -z "${VISUAL-}" ]; then
    export VISUAL="$EDITOR"
fi
