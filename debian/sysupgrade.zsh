#!/usr/bin/env zsh
set -euo pipefail

# Automated apt maintenance script
# - Updates package lists
# - Runs full-upgrade with non-interactive config file handling
# - Backs up /etc before the upgrade
# - Runs autoremove and autoclean
# - Reloads systemd and restarts services (if needrestart is available)
# - Collects system information and uploads it to 0x0.st (expires in 24 hours)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Force predictable US English output (useful for logs/parsing)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APT_BIN="/bin/apt"

BACKUP_ROOT="/var/backups/apt-config-backups"

# Non-interactive apt
export DEBIAN_FRONTEND=noninteractive

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root (sudo)."
    exit 1
  fi
}

backup_etc() {
  local ts backup_dir archive

  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${ts}"
  archive="${backup_dir}/etc.tar.gz"

  mkdir -p "$backup_dir"

  log "Backing up /etc to ${archive}..."
  # Preserve permissions, ACLs and xattrs where possible
  # Use -C / to avoid tar's leading-slash warning while keeping absolute paths in the archive
  tar --numeric-owner --xattrs --acls -cpzf "$archive" -C / etc
  log "Backup completed."
}

apt_update() {
  log "Updating package lists..."
  "$APT_BIN" update
}

apt_full_upgrade() {
  log "Running full-upgrade (auto-replace old config files)..."
  "$APT_BIN" -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confnew" \
    full-upgrade
}

apt_cleanup() {
  log "Removing unused packages (autoremove)..."
  "$APT_BIN" -y autoremove

  log "Cleaning package cache (autoclean)..."
  "$APT_BIN" -y autoclean
}

restart_services() {
  log "Reloading systemd manager configuration..."
  systemctl daemon-reload || warn "systemctl daemon-reload failed (continuing)."

  if command -v needrestart >/dev/null 2>&1; then
    log "Restarting services using needrestart (automatic mode)..."
    # -r a = automatically restart services when needed
    if needrestart -r a; then
      log "Service restart via needrestart completed."
    else
      warn "needrestart reported an issue while restarting services."
    fi
  else
    warn "needrestart not installed; services may need a manual restart."
  fi
}

collect_system_info_and_upload() {
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping system info upload."
    return
  fi

  log "Collecting system info and uploading to 0x0.st (24h expiry)..."

  print_section() {
    printf '\n---\n\n=== %s ===\n\n' "$1"
  }

  local sysinfo hardware_info upgrades recent_events last_boot_events failed_services disk_usage uptime_info mount_info inet_info inode_usage top_procs content tmpfile upload_url expires_ms

  sysinfo=$(
    {
      print_section "System Info"
      uname -a
      printf '\n'
      if [[ -f /etc/os-release ]]; then
        cat /etc/os-release
      fi
    } 2>&1 || true
  )

  uptime_info=$(
    {
      print_section "Uptime / Load"
      uptime
      printf '\n'
      free -h 2>/dev/null || true
    } 2>&1 || true
  )

  hardware_info=$(
    {
      print_section "CPU"
      lscpu 2>/dev/null || true
      print_section "Memory (MemTotal from /proc/meminfo)"
      grep -E '^Mem(Total|Available):' /proc/meminfo 2>/dev/null || true
      print_section "PCI Devices"
      lspci -nn 2>/dev/null || printf 'lspci not available.\n'
      print_section "USB Devices"
      lsusb 2>/dev/null || printf 'lsusb not available.\n'
    } 2>&1 || true
  )

  upgrades=$(
    {
      print_section "Upgradable Packages"
      apt list --upgradable 2>/dev/null
    } 2>&1 || true
  )

  last_boot_events=$(
    {
      print_section "Previous Boot Journal (warnings/errors)"
      journalctl -b -1 -p warning..alert
    } 2>&1 || true
  )

  recent_events=$(
    {
      print_section "Recent Journal (warnings/errors, last hour)"
      journalctl -p warning..alert --since "1 hour ago"
    } 2>&1 || true
  )

  failed_services=$(
    {
      print_section "Failed Systemd Services"
      systemctl list-units --state=failed
    } 2>&1 || true
  )

  disk_usage=$(
    {
      print_section "Disk Usage (df -h)"
      df -h
    } 2>&1 || true
  )

  inode_usage=$(
    {
      print_section "Inode Usage (df -i)"
      df -i
    } 2>&1 || true
  )

  mount_info=$(
    {
      print_section "Block Devices"
      lsblk -f 2>/dev/null || lsblk 2>/dev/null || true
      print_section "Mounts"
      mount || true
    } 2>&1 || true
  )

  inet_info=$(
    {
      print_section "Network (ip -br a)"
      ip -br a 2>/dev/null || true
      print_section "Routes"
      ip route 2>/dev/null || true
    } 2>&1 || true
  )

  top_procs=$(
    {
      print_section "Top Processes (by RSS)"
      ps -eo pid,ppid,cmd,%mem,%cpu,rss --sort=-rss | head -n 20
    } 2>&1 || true
  )

  content="${sysinfo}${hardware_info}${uptime_info}${upgrades}${last_boot_events}${recent_events}${failed_services}${disk_usage}${inode_usage}${mount_info}${inet_info}${top_procs}"

  tmpfile="$(mktemp /tmp/debian-info.XXXXXX)"
  printf "%s\n" "$content" >"$tmpfile"

  expires_ms=$(( ( $(date +%s) + 24*3600 ) * 1000 ))

  upload_url=$(curl -fLsS --retry 5 -F "file=@${tmpfile}" -F "expires=${expires_ms}" https://0x0.st 2>/dev/null | tr -d '[:space:]' || true)

  rm -f "$tmpfile"

  if [[ -n "${upload_url:-}" ]]; then
    log "System info uploaded to 0x0.st (expires in 24h): $upload_url"
  else
    warn "Failed to upload system info to 0x0.st."
  fi
}

main() {
  require_root

  log "Starting apt maintenance run..."
  backup_etc
  apt_update
  apt_full_upgrade
  apt_cleanup
  restart_services
  collect_system_info_and_upload
  log "Debian maintenance run completed successfully."
}

main "$@"
