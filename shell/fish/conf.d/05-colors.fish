# ==================================================
# Fish startup: color palette and theme env
# File: 05-colors.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: configure terminal/app colors and fish color vars
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -gx COLORTERM truecolor
set -gx BAT_THEME TwoDark

if command -q dircolors
    set -gx LS_COLORS (dircolors -b | string match -r --groups-only "^LS_COLORS='(.*)'; export LS_COLORS\$")
end

set -g fish_color_normal normal
set -g fish_color_command brcyan
set -g fish_color_param brwhite
set -g fish_color_quote yellow
set -g fish_color_redirection brblue
set -g fish_color_end brmagenta
set -g fish_color_error brred
set -g fish_color_comment brblack
set -g fish_color_match --background=brblue
set -g fish_color_operator brgreen
set -g fish_color_escape bryellow
set -g fish_color_autosuggestion brblack
set -g fish_color_cwd green
set -g fish_color_cwd_root red
set -g fish_color_user brgreen
set -g fish_color_host brcyan
set -g fish_color_host_remote brcyan
set -g fish_color_valid_path --underline
set -q fish_color_keyword; or set -g fish_color_keyword brblue
set -q fish_pager_color_prefix; or set -g fish_pager_color_prefix brblue --bold
set -q fish_pager_color_completion; or set -g fish_pager_color_completion normal
set -q fish_pager_color_description; or set -g fish_pager_color_description brblack
set -q fish_pager_color_selected_background; or set -g fish_pager_color_selected_background brblack

if status is-interactive
    if command -q bat
        function cat --wraps bat
            command bat --style=plain --paging=never $argv
        end
    end

    function ls --wraps ls
        if command -q eza
            command eza --group-directories-first $argv
        else
            command ls $argv
        end
    end

    if command grep --version >/dev/null 2>&1
        function grep --wraps grep
            command grep --color=auto $argv
        end
    end

    if command diff --version >/dev/null 2>&1
        function diff --wraps diff
            command diff --color=auto $argv
        end
    end
end
