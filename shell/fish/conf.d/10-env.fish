# ==================================================
# Fish startup: environment variables
# File: 10-env.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: export session-wide env vars and defaults
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

if command -q fish
    set -gx SHELL (command -v fish)
end

if not set -q HOSTNAME
    set -l short_host (hostname -s 2>/dev/null)
    if test -n "$short_host"
        set -gx HOSTNAME $short_host
    else
        set -gx HOSTNAME (hostname 2>/dev/null)
    end
end

set -q EDITOR; or set -gx EDITOR hx
set -gx VISUAL $EDITOR
set -gx FCEDIT $EDITOR
set -gx GIT_EDITOR $EDITOR
set -gx PAGER less
set -gx LESS '-iMRSN -x2 -R'
set -gx MANPAGER 'less -R -N'
set -gx LESS_TERMCAP_mb (printf '\e[1;35m')
set -gx LESS_TERMCAP_md (printf '\e[1;36m')
set -gx LESS_TERMCAP_me (printf '\e[0m')
set -gx LESS_TERMCAP_se (printf '\e[0m')
set -gx LESS_TERMCAP_so (printf '\e[30;47m')
set -gx LESS_TERMCAP_ue (printf '\e[0m')
set -gx LESS_TERMCAP_us (printf '\e[1;33m')
set -gx LC_COLLATE C
set -q LANG; or set -gx LANG en_US.UTF-8
set -q LC_CTYPE; or set -gx LC_CTYPE $LANG
set -gx HOMEBREW_CASK_OPTS --require-sha
set -e HOMEBREW_CASK_OPTS_REQUIRE_SHA
set -gx CLICOLOR 1
set -gx GREP_COLORS 'mt=01;32'

umask 022
