#!/bin/bash
set -euo pipefail

#
# Secureblue maintenance script
#
# This script performs a full, non-interactive maintenance run on a
# Secureblue (rpm-ostree-based) system. It is designed to be safe to
# run unattended (e.g. from cron or a systemd timer) and will attempt
# to update all major layers of the system:
#
#   1. System image (rpm-ostree)
#   2. Firmware (fwupdmgr)
#   3. Homebrew packages (brew)
#   4. Flatpak runtimes and applications (system + per-user)
#   5. Storage maintenance (ext4/btrfs filesystems)
#   6. Secureblue debug information (uploaded to fpaste)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Add Homebrew to PATH if present (typical multi-user Linuxbrew locations)
if [[ -d /var/home/linuxbrew/.linuxbrew/bin ]]; then
  PATH="/var/home/linuxbrew/.linuxbrew/bin:$PATH"
elif [[ -d /var/home/linuxbrew/bin ]]; then
  PATH="/var/home/linuxbrew/bin:$PATH"
fi

if [[ -d /home/linuxbrew/.linuxbrew/bin ]]; then
  PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
elif [[ -d /home/linuxbrew/bin ]]; then
  PATH="/home/linuxbrew/bin:$PATH"
fi

export PATH

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

trap 'error "Execution interrupted."; exit 1' INT

# ---- Helpers ---------------------------------------------------------------

# Usage:
#   require_cmd cmd1 cmd2 ...        # required: exits on missing
#   require_cmd --check cmd1 cmd2    # optional check: returns 0/1, no exit
require_cmd() {
  local mode="fatal"
  if [[ "${1:-}" == "--check" ]]; then
    mode="check"
    shift
  fi

  local missing=()
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      if [[ "$mode" == "fatal" ]]; then
        error "Required command '$cmd' not found in PATH."
      fi
      missing+=("$cmd")
    fi
  done

  if [[ "$mode" == "fatal" ]]; then
    if ((${#missing[@]} > 0)); then
      exit 1
    fi
    return 0
  else
    # check mode: success only if none missing
    ((${#missing[@]} == 0))
  fi
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  if require_cmd --check run0; then
    log "Re-executing this script via run0 to gain root privileges..."
    exec run0 -- "$0" "$@"
  else
    error "This script must be run as root and 'run0' was not found. Please run as root or install run0."
    exit 1
  fi
}

get_primary_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return 0
  fi
  # First "normal" user (UID >= 1000 && < 60000, and a real shell)
  awk -F: '$3>=1000 && $3<60000 && $7 !~ /(false|nologin)$/ {print $1; exit}' /etc/passwd || true
}

# ---- Maintenance phases ----------------------------------------------------

update_system_image() {
  if ! require_cmd --check rpm-ostree; then
    warn "rpm-ostree not found, skipping system image update."
    return
  fi

  log "Updating system via rpm-ostree (non-interactive)..."
  rpm-ostree update       || warn "rpm-ostree update failed (continuing)."
  rpm-ostree upgrade      || warn "rpm-ostree upgrade failed (continuing)."
  rpm-ostree cleanup -bm  || warn "rpm-ostree cleanup failed (continuing)."
}

update_firmware() {
  if ! require_cmd --check fwupdmgr; then
    warn "fwupdmgr not found, skipping firmware."
    return
  fi

  log "Updating firmware via fwupdmgr (non-interactive)..."
  fwupdmgr refresh --force                     || warn "fwupdmgr refresh failed (continuing)."
  fwupdmgr get-updates                         || warn "fwupdmgr get-updates failed (continuing)."
  fwupdmgr update -y --no-reboot-check         || warn "fwupdmgr update failed (continuing)."
}

update_homebrew() {
  log "Updating Homebrew applications..."

  if ! require_cmd --check brew; then
    warn "brew not found; skipping Homebrew update."
    return
  fi

  local BREW_PREFIX PREFIX_UID PREFIX_GID BREW_USER

  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  if [[ -z "${BREW_PREFIX:-}" || ! -d "$BREW_PREFIX" ]]; then
    warn "Could not determine a valid Homebrew prefix; skipping Homebrew update."
    return
  fi

  PREFIX_UID="$(stat -c '%u' "$BREW_PREFIX" 2>/dev/null || echo "")"
  PREFIX_GID="$(stat -c '%g' "$BREW_PREFIX" 2>/dev/null || echo "")"

  if [[ -z "$PREFIX_UID" || -z "$PREFIX_GID" ]]; then
    warn "Could not read UID/GID for '$BREW_PREFIX'; running brew as root (not ideal)."
    brew update   || warn "brew update failed (continuing)."
    brew upgrade  || warn "brew upgrade failed (continuing)."
    brew cleanup  || warn "brew cleanup failed (continuing)."
    return
  fi

  BREW_USER="$(getent passwd "$PREFIX_UID" | cut -d: -f1 || true)"
  if [[ -z "${BREW_USER:-}" ]]; then
    warn "Could not map UID=$PREFIX_UID to a username; running brew as root (not ideal)."
    brew update   || warn "brew update failed (continuing)."
    brew upgrade  || warn "brew upgrade failed (continuing)."
    brew cleanup  || warn "brew cleanup failed (continuing)."
    return
  fi

  if require_cmd --check runuser; then
    log "Running brew as Homebrew owner: $BREW_USER"
    runuser -u "$BREW_USER" -- brew update   || warn "brew update failed (continuing)."
    runuser -u "$BREW_USER" -- brew upgrade  || warn "brew upgrade failed (continuing)."
    runuser -u "$BREW_USER" -- brew cleanup  || warn "brew cleanup failed (continuing)."
  else
    warn "'runuser' not available; running brew as root (not ideal)."
    brew update   || warn "brew update failed (continuing)."
    brew upgrade  || warn "brew upgrade failed (continuing)."
    brew cleanup  || warn "brew cleanup failed (continuing)."
  fi
}

update_flatpak() {
  if ! require_cmd --check flatpak; then
    warn "flatpak not found, skipping Flatpak."
    return
  fi

  log "Updating and repairing Flatpak system installation..."
  flatpak repair --system                          || warn "flatpak system repair failed (continuing)."
  flatpak update   --system -y                     || warn "flatpak system update failed (continuing)."
  flatpak uninstall --system --unused -y           || warn "flatpak system cleanup failed (continuing)."

  # Per-user updates (best effort)
  if ! require_cmd --check runuser; then
    warn "'runuser' not available; skipping per-user Flatpak updates/repairs."
    return
  fi

  log "Repairing and updating Flatpak user installations..."
  while IFS=: read -r user _ uid _ home _; do
    [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] || continue
    if [[ -d "$home/.local/share/flatpak" ]]; then
      log "  -> Flatpak repair/update for user $user"
      runuser -u "$user" -- flatpak repair --user                 || warn "flatpak user repair failed for $user (continuing)."
      runuser -u "$user" -- flatpak update --user -y              || warn "flatpak user update failed for $user (continuing)."
      runuser -u "$user" -- flatpak uninstall --user --unused -y  || warn "flatpak user cleanup failed for $user (continuing)."
    fi
  done < /etc/passwd
}

maintain_filesystems() {
  if ! require_cmd --check lsblk; then
    warn "lsblk not found; skipping filesystem maintenance."
    return
  fi

  log "Scanning mounted block devices for ext4 and btrfs filesystems..."

  # Associative arrays: device -> mountpoint (one per device)
  declare -A btrfs_dev_mp
  declare -A ext4_dev_mp

  # NAME = device name (sda1, nvme0n1p2, etc.)
  # FSTYPE = filesystem type (ext4, btrfs, xfs...)
  # MOUNTPOINT = where it is mounted
  while read -r name fstype mnt; do
    [[ -z "$mnt" ]] && continue
    [[ "$fstype" != "btrfs" && "$fstype" != "ext4" ]] && continue

    local dev="/dev/$name"

    case "$fstype" in
      btrfs)
        # First mountpoint seen for this device
        if [[ -z "${btrfs_dev_mp[$dev]:-}" ]]; then
          btrfs_dev_mp["$dev"]="$mnt"
        fi
        ;;
      ext4)
        if [[ -z "${ext4_dev_mp[$dev]:-}" ]]; then
          ext4_dev_mp["$dev"]="$mnt"
        fi
        ;;
    esac
  done < <(lsblk -rno NAME,FSTYPE,MOUNTPOINT 2>/dev/null)

  if ((${#btrfs_dev_mp[@]} == 0 && ${#ext4_dev_mp[@]} == 0)); then
    log "No ext4 or btrfs block devices with mountpoints detected; skipping filesystem maintenance."
    return
  fi

  # ----------------- btrfs maintenance -----------------
  if ((${#btrfs_dev_mp[@]} > 0)); then
    if ! require_cmd --check btrfs; then
      warn "btrfs-progs not found; skipping btrfs maintenance."
    else
      local dev mp
      for dev in "${!btrfs_dev_mp[@]}"; do
        mp="${btrfs_dev_mp[$dev]}"
        log "Running non-destructive maintenance on btrfs filesystem $dev (mounted at $mp)..."

        # Scrub: verify data and repair using redundancy if possible
        btrfs scrub start -Bd "$mp" \
          || warn "btrfs scrub failed for $mp (continuing)."

        # Full balance: reorganize all chunks (can be heavy on large disks, but non-destructive)
        btrfs balance start --full-balance "$mp" \
          || warn "btrfs balance failed for $mp (continuing)."

        # Recursive defragmentation (can take a while, but non-destructive)
        btrfs filesystem defragment -r "$mp" \
          || warn "btrfs filesystem defragment failed for $mp (continuing)."
      done
    fi
  fi

  # ----------------- ext4 maintenance ------------------
  if ((${#ext4_dev_mp[@]} > 0)); then
    if ! require_cmd --check e4defrag; then
      warn "e4defrag not found; skipping ext4 online defragmentation."
    else
      local dev mp
      for dev in "${!ext4_dev_mp[@]}"; do
        mp="${ext4_dev_mp[$dev]}"
        log "Running non-destructive maintenance on ext4 filesystem $dev (mounted at $mp)..."

        # Check fragmentation level (non-destructive)
        e4defrag -c "$mp" \
          || warn "e4defrag check failed for $mp (continuing)."

        # Online defragmentation (non-destructive, but can take some time)
        e4defrag "$mp" \
          || warn "e4defrag defragmentation failed for $mp (continuing)."
      done
    fi
  fi
}

collect_secureblue_info() {
  if ! require_cmd --check ujust fpaste; then
    warn "ujust or fpaste not found; skipping Secureblue information collection."
    return
  fi

  # Determine a primary non-root user to run ujust/flatpak/brew as.
  # This avoids collecting information as root when user context is needed.
  local primary_user run_user
  primary_user="$(get_primary_user || true)"

  if [[ -n "${primary_user:-}" ]] && require_cmd --check runuser; then
    # We'll prefix ujust/flatpak/brew with: runuser -u "$primary_user" --
    run_user="runuser -u ${primary_user} --"
    log "Running ujust, flatpak and brew as user: ${primary_user}"
  else
    run_user=""
    if [[ -z "${primary_user:-}" ]]; then
      warn "Could not detect a primary non-root user; running ujust/flatpak/brew as root (not ideal)."
    else
      warn "'runuser' not available; running ujust/flatpak/brew as root (not ideal)."
    fi
  fi

  log "Collecting Secureblue debug information and uploading to fpaste (non-interactive)..."

  local sysinfo rpm_ostree_status flatpaks homebrew_packages
  local audit_results local_overrides recent_events failed_services brew_services
  local content paste_url

  sysinfo=$(
    {
      echo
      fpaste --sysinfo --printonly
    } 2>&1 || true
  )

  rpm_ostree_status=$(
    {
      echo -e "=== Rpm-Ostree Status ===\n"
      if require_cmd --check rpm-ostree; then
        rpm-ostree status --verbose
      else
        echo "rpm-ostree not available."
      fi
    } 2>&1 || true
  )

  flatpaks=$(
    {
      echo "=== Flatpaks Installed ==="
      if require_cmd --check flatpak; then
        if [[ -n "${run_user:-}" ]]; then
          # Run flatpak as the primary non-root user
          $run_user flatpak list --columns=application,version,options
        else
          flatpak list --columns=application,version,options
        fi
      else
        echo "flatpak not available."
      fi
    } 2>&1 || true
  )

  homebrew_packages=$(
    {
      echo -e "\n=== Homebrew Packages Installed ===\n"
      if require_cmd --check brew; then
        if [[ -n "${run_user:-}" ]]; then
          # Run brew as the primary non-root user
          $run_user brew list --versions
        else
          brew list --versions
        fi
      else
        echo "brew not available."
      fi
    } 2>&1 || true
  )

  audit_results=$(
    {
      echo -e "\n=== Audit Results ===\n"
      if [[ -n "${run_user:-}" ]]; then
        # Run ujust as the primary non-root user
        $run_user ujust audit-secureblue
      else
        ujust audit-secureblue
      fi
    } 2>&1 || true
  )

  local_overrides=$(
    {
      echo -e "\n=== Listing Local Overrides ===\n"
      if [[ -n "${run_user:-}" ]]; then
        # Run ujust as the primary non-root user
        $run_user ujust check-local-overrides
      else
        ujust check-local-overrides
      fi
    } 2>&1 || true
  )

  recent_events=$(
    {
      echo -e "\n=== Recent System Events ===\n"
      journalctl -b -p err..alert --since "1 hour ago"
    } 2>&1 || true
  )

  failed_services=$(
    {
      echo -e "\n=== Failed Systemd Services ===\n"
      systemctl list-units --state=failed
    } 2>&1 || true
  )

  brew_services=$(
    {
      echo -e "\n=== Homebrew Services Status ===\n"
      if require_cmd --check brew; then
        if [[ -n "${run_user:-}" ]]; then
          # Run brew services as the primary non-root user
          $run_user brew services list
        else
          brew services list
        fi
      else
        echo "brew not available."
      fi
    } 2>&1 || true
  )

  content="${sysinfo}${rpm_ostree_status}${flatpaks}${homebrew_packages}${audit_results}${local_overrides}${recent_events}${failed_services}${brew_services}"

  paste_url=$(printf "%s\n" "$content" | fpaste --private=1 2>/dev/null || true)

  if [[ -n "${paste_url:-}" ]]; then
    log "Secureblue information uploaded to fpaste: $paste_url"
  else
    warn "Failed to upload Secureblue information to fpaste."
  fi
}

# ---- Main ------------------------------------------------------------------
main() {
  log "Starting update process..."

  update_system_image
  update_firmware
  update_homebrew
  update_flatpak
  maintain_filesystems
  collect_secureblue_info

  log "Update process completed."
}

# Entry point
ensure_root "$@"
# Base tools we use without extra checks
require_cmd awk getent stat journalctl systemctl
main "$@"
