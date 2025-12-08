#!/usr/bin/env bash
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
  tar --numeric-owner --xattrs --acls -cpzf "$archive" /etc
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

  local sysinfo upgrades recent_events last_boot_events failed_services disk_usage content tmpfile upload_url expires_ms

  sysinfo=$(
    {
      printf '\n=== System Info ===\n\n'
      uname -a
      printf '\n'
      if [[ -f /etc/os-release ]]; then
        cat /etc/os-release
      fi
    } 2>&1 || true
  )

  upgrades=$(
    {
      printf '\n=== Upgradable Packages ===\n\n'
      apt list --upgradable 2>/dev/null
    } 2>&1 || true
  )

  last_boot_events=$(
    {
      printf '\n=== Previous Boot Journal (warnings/errors) ===\n\n'
      journalctl -b -1 -p warning..alert
    } 2>&1 || true
  )

  recent_events=$(
    {
      printf '\n=== Recent Journal (warnings/errors, last hour) ===\n\n'
      journalctl -p warning..alert --since "1 hour ago"
    } 2>&1 || true
  )

  failed_services=$(
    {
      printf '\n=== Failed Systemd Services ===\n\n'
      systemctl list-units --state=failed
    } 2>&1 || true
  )

  disk_usage=$(
    {
      printf '\n=== Disk Usage (df -h) ===\n\n'
      df -h
    } 2>&1 || true
  )

  content="${sysinfo}${upgrades}${last_boot_events}${recent_events}${failed_services}${disk_usage}"

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
  log "Apt maintenance run completed successfully."
}

main "$@"
