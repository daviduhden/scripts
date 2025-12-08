#!/usr/bin/env bash

# Automated apt maintenance script
# - Updates package lists
# - Runs full-upgrade with non-interactive config file handling
# - Backs up /etc before the upgrade
# - Runs autoremove and autoclean
# - Reloads systemd and restarts services (if needrestart is available)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

APT_BIN="/bin/apt"

# Optional torsocks wrapper for networked apt operations
if command -v torsocks >/dev/null 2>&1; then
  TORSOCKS="torsocks"
else
  TORSOCKS=""
fi

apt_net() {
  if [[ -n "$TORSOCKS" ]]; then
    "$TORSOCKS" "$@"
  else
    "$@"
  fi
}
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
  apt_net "$APT_BIN" update
}

apt_full_upgrade() {
  log "Running full-upgrade (auto-replace old config files)..."
  apt_net "$APT_BIN" -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confnew" \
    full-upgrade
}

apt_cleanup() {
  log "Removing unused packages (autoremove)..."
  apt_net "$APT_BIN" -y autoremove

  log "Cleaning package cache (autoclean)..."
  apt_net "$APT_BIN" -y autoclean
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

main() {
  require_root

  log "Starting apt maintenance run..."
  backup_etc
  apt_update
  apt_full_upgrade
  apt_cleanup
  restart_services
  log "Apt maintenance run completed successfully."
}

main "$@"
