# shellcheck shell=bash
# ==================================================
# Custom aliases & functions
# Loaded from ~/.bashrc.d
# ==================================================
# This file is sourced by an interactive Bash session, usually from
# ~/.bashrc.d, and is not a standalone program. Sourcing it changes the
# current shell: command names are replaced by aliases and two functions are
# defined. Alias expansion normally applies only to interactive shells, so
# scripts that call these command names still use the original binaries.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# --------------------------------------------------
# LS and navigation
# --------------------------------------------------
# ll uses GNU options for long, human-readable output with grouped
# directories; la shows almost all entries and l uses classified short
# output. The dotted aliases walk up one, two, or three parent directories.
alias ll='ls -lah --group-directories-first'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# --------------------------------------------------
# Safety
# --------------------------------------------------
# cp and mv run interactively and verbosely, prompting before an overwrite.
# rm -I asks once before recursive or bulk removal, and -v lists removals.
# --preserve-root makes chown and chmod refuse to operate on /.
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -Iv'
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'

# --------------------------------------------------
# AI assistants with max privileges
# --------------------------------------------------
# These aliases start each agent in its automatic/full-permission mode
# (--yolo for Codex and Copilot, --auto for OpenCode), which skips approval
# prompts. The OpenCode alias also sets JavaScriptCoreUseJIT=1 for that
# invocation and uses `command` to run the real executable instead of any
# function of the same name.
alias codex='codex --yolo'
alias copilot='copilot --yolo'
alias opencode='JavaScriptCoreUseJIT=1 command opencode --auto'

# --------------------------------------------------
# Editors
# --------------------------------------------------
# nano shows line numbers, vi maps to vim, and the s-prefixed aliases start
# the editor as root through run0.
alias nano='nano -l'
alias vi='vim'
alias svi='run0 vim'
alias kakoune='kak'
alias skak='run0 kak'

# --------------------------------------------------
# System information
# --------------------------------------------------
# Sizes are human-readable. ports lists listening TCP and UDP sockets with
# process names in numeric form; top maps to htop, which must be installed.
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='ss -tulpn'
alias top='htop'

# --------------------------------------------------
# Networking
# --------------------------------------------------
# ipinfo colorizes interface addresses, ping sends five probes, and wget
# continues partial downloads.
alias ipinfo='ip -c a'
alias ping='ping -c 5'
alias wget='wget -c'

# ==================================================
# Functions
# ==================================================

# Full system upgrade helper. It runs the SecureBlue maintenance helpers in
# order and then upgrades pipx packages. A sysupgrade failure is recorded but
# the remaining updates still run; a failure in the chain stops the chain.
# The sysupgrade status is returned first, then any remaining failure.
sysupgrade-all() {
	local sysupgrade_rc=0
	local remaining_rc=0
	local sysupgrade_user="${SYSUPGRADE_USER:-${USER:-$(id -un)}}"

	echo "Starting full system upgrade..."
	sysupgrade --user "$sysupgrade_user" --skip-audit || {
		sysupgrade_rc=$?
		echo "[WARN] sysupgrade failed with exit code ${sysupgrade_rc}," \
			"continuing with remaining updates..."
	}

	update-krohnkite &&
		update-arti-oniux &&
		update-lyrebird &&
		update-xd-torrent --skip-service-and-user-setup &&
		update-perl-modules &&
		pipx upgrade-all &&
		echo "[OK] System upgrade completed successfully." ||
		remaining_rc=$?

	if ((sysupgrade_rc != 0)); then
		return "$sysupgrade_rc"
	fi
	return "$remaining_rc"
}

# --------------------------------------------------
# Universal archive extractor
# Usage: extract file.ext
# --------------------------------------------------
# Select the tool from the filename suffix. The matching program must be
# installed; a missing file or an unknown suffix prints an error and returns 1.
extract() {
	if [ -f "$1" ]; then
		case "$1" in
		*.tar.bz2) tar xjf "$1" ;;
		*.tar.gz) tar xzf "$1" ;;
		*.bz2) bunzip2 "$1" ;;
		*.rar) unrar x "$1" ;;
		*.gz) gunzip "$1" ;;
		*.tar) tar xf "$1" ;;
		*.tbz2) tar xjf "$1" ;;
		*.tgz) tar xzf "$1" ;;
		*.zip) unzip "$1" ;;
		*.Z) uncompress "$1" ;;
		*.7z) 7z x "$1" ;;
		*)
			echo "[ERROR] Cannot extract '$1'"
			return 1
			;;
		esac
	else
		echo "[ERROR] Invalid file"
		return 1
	fi
}

# --------------------------------------------------
# Quick info helpers
# --------------------------------------------------
# Both helpers need curl and network access: myip queries ifconfig.me, and
# weather renders wttr.in in the terminal.
alias myip='curl -s ifconfig.me'
alias weather='curl wttr.in'
