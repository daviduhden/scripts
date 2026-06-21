# ==================================================
# Fish startup: safe/verbose command wrappers
# File: 25-verbose.fish
# Loaded from ~/.config/fish/conf.d during fish init
# Purpose: wrap risky commands with interactive flags
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

if status is-interactive
    function cp --wraps cp
        command cp -iv $argv
    end

    function mv --wraps mv
        command mv -iv $argv
    end

    function rm --wraps rm
        command rm -Iv $argv
    end

    function chown --wraps chown
        command chown --preserve-root --verbose $argv
    end

    function chmod --wraps chmod
        command chmod --preserve-root --verbose $argv
    end

    function df --wraps df
        command df -h $argv
    end

    if command -q dust
        function du --wraps dust
            command dust $argv
        end
    else
        function du --wraps du
            command du -h $argv
        end
    end

    function free --wraps free
        command free -h $argv
    end

    function ports
        command ss -tulpn $argv
    end

    if command -q btm
        function top --wraps btm
            command btm $argv
        end
    else if command -q htop
        function top --wraps htop
            command htop $argv
        end
    end

    function ipinfo
        command ip -c a $argv
    end

    function ping --wraps ping
        command ping -c 5 $argv
    end

    function wget --wraps wget
        command wget -c $argv
    end
end
