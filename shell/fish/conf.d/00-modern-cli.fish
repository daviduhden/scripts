# ==================================================
# Fish startup: modern CLI compatibility
# File: 00-modern-cli.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: map tool-name differences and helper wrappers
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Modern CLI compatibility layer.
# Loaded only by fish; interactive aliases must not affect scripts.

if status is-interactive

    # Debian compatibility: bat may be called batcat.
    if not command -q bat; and command -q batcat
        function bat --wraps batcat
            batcat $argv
        end
    end

    # Debian compatibility: fd may be called fdfind.
    if not command -q fd; and command -q fdfind
        function fd --wraps fdfind
            fdfind $argv
        end
    end

    if command -q fd
        alias find='fd'
    end

    if command -q procs
        alias ps='procs'
    end

    if command -q delta
        set -gx GIT_PAGER delta
        set -gx DELTA_FEATURES side-by-side
    end

    if command -q fzf
        set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git 2>/dev/null'
        set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
    end

    if command -q zoxide
        zoxide init fish | source
        if functions -q z
            alias cd='z'
        end
    end

    if command -q yazi
        alias fm='yazi'
    end

    if command -q codex
        function codex --wraps codex
            command codex --yolo $argv
        end
    end

    if command -q copilot
        function copilot --wraps copilot
            command copilot --yolo $argv
        end
    end

end
