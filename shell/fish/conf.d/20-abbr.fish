# ==================================================
# Fish startup: interactive abbreviations
# File: 20-abbr.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: define command abbreviations for daily workflows
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

if status is-interactive
    if command -q eza
        abbr --add ll 'eza -lah --group-directories-first'
        abbr --add la 'eza -a --group-directories-first'
        abbr --add l 'eza -F'
    else
        abbr --add ll 'ls -lh'
        abbr --add la 'ls -A'
        abbr --add l 'ls -CF'
    end

    abbr --add .. 'cd ..'
    abbr --add ... 'cd ../..'
    abbr --add .... 'cd ../../..'

    abbr --add nano 'nano -l'
    abbr --add svi 'run0 hx'
    abbr --add myip 'curl -s ifconfig.me'
    abbr --add weather 'curl wttr.in'
end
