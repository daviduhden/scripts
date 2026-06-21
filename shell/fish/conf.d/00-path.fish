# ==================================================
# Fish startup: path bootstrap
# File: 00-path.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: add user and package-manager bin directories
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

for p in /home/linuxbrew/.linuxbrew/sbin /home/linuxbrew/.linuxbrew/bin $HOME/bin $HOME/.local/bin
    if test -d $p
        fish_add_path -g $p
    end
end

for p in $HOME/.local/share/flatpak/exports/bin /var/lib/flatpak/exports/bin
    if test -d $p
        fish_add_path -g $p
    end
end
