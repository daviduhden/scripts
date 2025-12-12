#!/bin/bash
set -euo pipefail

# Argon One V3 maintenance script
#  - Updates EEPROM (argon-eeprom.sh)
#  - Updates power button & fan control script (argon1.sh)
#  - Can run interactively or from cron (non-interactive)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

EEPROM_URL="https://download.argon40.com/argon-eeprom.sh"
CONTROL_URL="https://download.argon40.com/argon1.sh"

# Reboot mode:
#   "prompt" -> ask (default in interactive mode)
#   "yes"    -> automatically reboot
#   "no"     -> never reboot automatically
AUTO_REBOOT="no"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -r, --auto-reboot   Automatically reboot at the end without prompting.
  -N, --no-reboot     Do not reboot at the end (default in non-interactive).
  -h, --help          Show this help and exit.

Examples:
  # Normal interactive usage
  sudo $0

  # For cron (no automatic reboot)
  sudo $0 --no-reboot

  # For cron with automatic reboot when finished
  sudo $0 --auto-reboot
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--auto-reboot)
        AUTO_REBOOT="yes"
        shift
        ;;
      -N|--no-reboot)
        AUTO_REBOOT="no"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        error "Try: $0 --help"
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s %b[WARN]%b  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

trap 'error "Execution interrupted."; exit 1' INT

# ---- Helpers ---------------------------------------------------------------

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root (sudo)."
    exit 1
  fi
}

net_curl() {
  curl -fLsS --retry 5 "$@"
}

check_network() {
  log "Checking network connectivity to download.argon40.com..."
  if ! net_curl --head "$EEPROM_URL" >/dev/null 2>&1; then
    error "Cannot reach download.argon40.com. Check your Internet connection."
    exit 1
  fi
  log "Network looks OK."
}

run_eeprom_update() {
  log "Running EEPROM update script from Argon40..."
  net_curl "$EEPROM_URL" | bash
  log "EEPROM update script finished."
}

run_control_update() {
  log "Running Argon One V3 control script installer..."
  net_curl "$CONTROL_URL" | bash
  log "Argon One V3 control script finished."
}

ask_reboot() {
  local answer
  # Flags take precedence
  case "$AUTO_REBOOT" in
    yes)
      log "Auto reboot enabled by flag; rebooting now..."
      reboot
      ;;
    no)
      log "Auto reboot disabled by flag. Please reboot manually."
      return 0
      ;;
  esac

  # Non-interactive (cron): never prompt
  if [[ ! -t 0 ]]; then
    log "Non-interactive session detected; skipping reboot. Please reboot manually."
    return 0
  fi

  # Interactive: ask the user
  read -r -p "Reboot now to apply all changes? [y/N] " answer
  case "$answer" in
    [yY][eE][sS]|[yY])
      log "Rebooting..."
      reboot
      ;;
    *)
      log "Reboot skipped. Remember to reboot later to apply EEPROM and control changes."
      ;;
  esac
}

# ---- Main ------------------------------------------------------------------

main() {
  log "Argon One V3 maintenance: EEPROM + control script update"

  require_root
  check_network

  run_eeprom_update
  run_control_update

  log "All Argon One V3 update steps completed."
  ask_reboot
}

main "$@"
