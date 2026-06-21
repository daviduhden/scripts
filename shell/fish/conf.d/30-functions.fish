# ==================================================
# Fish startup: utility functions
# File: 30-functions.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: define reusable helper functions and workflows
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

function sysupgrade-all
    set -l sysupgrade_rc 0
    set -q SECUREBLUE_USER; or set -gx SECUREBLUE_USER (id -un)

    echo "Starting full system upgrade..."
    sysupgrade --user $SECUREBLUE_USER --skip-audit
    or begin
        set sysupgrade_rc $status
        echo "sysupgrade failed with exit code $sysupgrade_rc, continuing with remaining updates..."
    end

    update-krohnkite
    and update-arti-oniux
    and update-lyrebird
    and update-xd-torrent --skip-service-and-user-setup
    and pipx upgrade-all
    and echo "System upgrade completed successfully."
end

function extract
    if test -f "$argv[1]"
        switch "$argv[1]"
            case '*.tar.bz2'
                tar xjf "$argv[1]"
            case '*.tar.gz'
                tar xzf "$argv[1]"
            case '*.bz2'
                bunzip2 "$argv[1]"
            case '*.rar'
                unrar x "$argv[1]"
            case '*.gz'
                gunzip "$argv[1]"
            case '*.tar'
                tar xf "$argv[1]"
            case '*.tbz2'
                tar xjf "$argv[1]"
            case '*.tgz'
                tar xzf "$argv[1]"
            case '*.zip'
                unzip "$argv[1]"
            case '*.Z'
                uncompress "$argv[1]"
            case '*.7z'
                7z x "$argv[1]"
            case '*'
                echo "Cannot extract '$argv[1]'"
                return 1
        end
    else
        echo "Invalid file"
        return 1
    end
end
