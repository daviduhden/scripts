# ==================================================
# Fish startup: editor and prompt helpers
# File: 03-prompt.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: define editor wrappers and shell launch helpers
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

function vi --description "Edit files with helix"
    if command -q hx
        command hx $argv
    else if set -q EDITOR
        command $EDITOR $argv
    else
        command vi $argv
    end
end

if command -q ksh
    function ksh --description "Start ksh"
        command ksh $argv
    end
end

if command -q ksh93
    function ksh93 --description "Start ksh93"
        command ksh93 $argv
    end
end

function fish_prompt
    set -l pschar '$'
    set -l user_color brcyan
    set -l host_color brblue
    set -l path_color bryellow
    set -l char_color brgreen

    if test (id -u) -eq 0
        set pschar '#'
        set user_color brred
        set host_color brred
        set path_color bryellow
        set char_color brred
    end

    set_color $user_color
    printf '%s' $USER
    set_color normal
    printf '@'
    set_color $host_color
    printf '%s' $HOSTNAME
    set_color normal
    printf ':'
    set_color $path_color
    printf '%s' (prompt_pwd)
    set_color normal
    printf ' '
    set_color $char_color
    printf '%s ' $pschar
    set_color normal
end

function fish_right_prompt
    set_color brblack
    printf '%s' (date '+%a %b %d %H:%M')
    set_color normal
end

function fish_mode_prompt
    switch $fish_bind_mode
        case default
            set_color brgreen
            printf '*'
        case insert
            set_color brblue
            printf 'I'
        case replace_one
            set_color bryellow
            printf 'R'
        case visual
            set_color brmagenta
            printf 'V'
    end
    set_color normal
    printf ' '
end
