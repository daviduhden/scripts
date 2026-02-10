# shellcheck shell=bash
# ==================================================
# Custom aliases & functions
# Loaded from ~/.bashrc.d
# ==================================================
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# --------------------------------------------------
# LS and navigation
# --------------------------------------------------
alias ll='ls -lah --group-directories-first'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# --------------------------------------------------
# Safety
# --------------------------------------------------
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -Iv'
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'

# --------------------------------------------------
# Editors
# --------------------------------------------------
alias edit='msedit'
alias nano='nano -l'
alias vi='vim'
alias svi='run0 vim'

# --------------------------------------------------
# System information
# --------------------------------------------------
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='ss -tulpn'
alias top='htop'

# --------------------------------------------------
# Networking
# --------------------------------------------------
alias ipinfo='ip -c a'
alias ping='ping -c 5'
alias wget='wget -c'

# ==================================================
# Functions
# ==================================================

# Full system upgrade helper
sysupgrade-all() {
	echo "🔄 Starting full system upgrade..."
	sysupgrade --user david --skip-audit &&
		update-krohnkite &&
		update-arti-oniux &&
		update-lyrebird &&
		update-xd-torrent &&
		pipx upgrade-all &&
		echo "✅ System upgrade completed successfully."
}

# --------------------------------------------------
# Universal archive extractor
# Usage: extract file.ext
# --------------------------------------------------
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
			echo "❌ Cannot extract '$1'"
			return 1
			;;
		esac
	else
		echo "❌ Invalid file"
		return 1
	fi
}

# --------------------------------------------------
# Quick info helpers
# --------------------------------------------------
alias myip='curl -s ifconfig.me'
alias weather='curl wttr.in'
