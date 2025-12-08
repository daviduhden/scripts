#!/bin/bash
set -euo pipefail

# Interactive helper to convert an ext4 filesystem inside a LUKS-encrypted device
# to Btrfs in-place using run0 for privilege escalation.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Simple colors for messages
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log()    { printf '%s %b[INFO]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s %b[WARN]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s %b[ERROR]%b %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; exit 1; }

# --- Elevate with run0 if needed -------------------------------------------

# 1. Ensure run0 exists
if ! command -v run0 >/dev/null 2>&1; then
    error "'run0' not found in PATH. Install it (on Fedora it comes from systemd) and try again."
fi

# 2. If not running as root, re-exec via run0
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "This script requires elevated privileges."
    log "Re-running with: run0 \"$0\" $*"
    exec run0 -- "$0" "$@"
fi

# --- Helpers ---------------------------------------------------------------

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt [y/N]: " answer || true
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command '$cmd' not found in PATH."
        fi
    done
}

print_header() {
    log "=================================================="
    log "$1"
    log "=================================================="
}

select_device() {
    print_header "Available block devices"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
    read -r -p "Enter the LUKS *partition* device (e.g. /dev/sdb1): " LUKS_DEV
    if [[ ! -b "$LUKS_DEV" ]]; then
        error "'$LUKS_DEV' is not a block device."
    fi
}

ensure_luks() {
    local type
    type=$(blkid -s TYPE -o value "$LUKS_DEV" || true)
    if [[ "$type" != "crypto_LUKS" ]]; then
        warn "'$LUKS_DEV' is not detected as crypto_LUKS (TYPE='$type')."
        warn "This script assumes you are using a LUKS-encrypted partition."
        if ! ask_yes_no "Continue anyway?"; then
            exit 1
        fi
    fi
}

open_luks() {
    read -r -p "Enter a name for the opened LUKS mapper (e.g. ext_btrfs): " LUKS_NAME
    LUKS_NAME=${LUKS_NAME:-ext_btrfs}

    MAPPER_DEV="/dev/mapper/$LUKS_NAME"

    if [[ -b "$MAPPER_DEV" ]]; then
        log "LUKS mapper '$MAPPER_DEV' already exists, assuming it's already opened."
    else
        print_header "Opening LUKS volume"
        log "You will be prompted for the LUKS passphrase for $LUKS_DEV"
        cryptsetup open "$LUKS_DEV" "$LUKS_NAME"
    fi

    if [[ ! -b "$MAPPER_DEV" ]]; then
        error "Mapper device '$MAPPER_DEV' not found after cryptsetup open."
    fi
}

check_mapper_fs() {
    print_header "Checking filesystem inside LUKS volume"
    lsblk -f "$MAPPER_DEV"
    local fstype
    fstype=$(blkid -s TYPE -o value "$MAPPER_DEV" || true)
    log "Detected filesystem type inside $MAPPER_DEV: ${fstype:-unknown}"

    if [[ "$fstype" != "ext4" ]]; then
        warn "Filesystem is not ext4. btrfs-convert is intended for ext2/3/4."
        if ! ask_yes_no "Continue anyway?"; then
            exit 1
        fi
    fi
}

umount_if_mounted() {
    print_header "Checking if $MAPPER_DEV is mounted"
    local mounts
    mounts=$(lsblk -no MOUNTPOINT "$MAPPER_DEV" | grep -v '^$' || true)
    if [[ -n "$mounts" ]]; then
        log "Device is currently mounted at:"
        log "$mounts"
        if ask_yes_no "Unmount all these mountpoints now?"; then
            while read -r mp; do
                [[ -z "$mp" ]] && continue
                log "Unmounting $mp ..."
                umount "$mp"
            done <<< "$mounts"
        else
            warn "Cannot continue while the device is mounted."
            exit 1
        fi
    else
        log "Device is not mounted. OK."
    fi
}

run_fsck_ext4() {
    print_header "Optional: fsck.ext4 check"
    log "It is recommended to run fsck.ext4 -f before converting."
    if ask_yes_no "Run fsck.ext4 -f on $MAPPER_DEV now?"; then
        fsck.ext4 -f "$MAPPER_DEV"
    else
        log "Skipping fsck.ext4 at your request."
    fi
}

run_btrfs_convert() {
    print_header "Converting ext4 → Btrfs with btrfs-convert"
    log "This will modify the filesystem *inside* $MAPPER_DEV."
    log "The LUKS layer on $LUKS_DEV is NOT changed."
    log "A backup subvolume (ext2_saved) will be created so you can revert"
    log "if needed, as long as you don't delete it later."
    warn "!!! RISK WARNING !!!"
    warn "Power loss, hardware issues, or bugs may still cause DATA LOSS."

    if ! ask_yes_no "Do you REALLY want to run btrfs-convert on $MAPPER_DEV?"; then
        warn "Aborting conversion."
        exit 1
    fi

    btrfs-convert "$MAPPER_DEV"
}

mount_btrfs() {
    print_header "Mounting the new Btrfs filesystem"

    read -r -p "Enter mount point (default: /mnt/$LUKS_NAME): " MOUNT_POINT
    MOUNT_POINT=${MOUNT_POINT:-/mnt/$LUKS_NAME}

    if [[ ! -d "$MOUNT_POINT" ]]; then
        log "Creating mount point directory: $MOUNT_POINT"
        mkdir -p "$MOUNT_POINT"
    fi

    mount -t btrfs "$MAPPER_DEV" "$MOUNT_POINT"
    log "Mounted $MAPPER_DEV on $MOUNT_POINT"
    log "Listing top-level files:"
    ls "$MOUNT_POINT" || true
    log "Listing Btrfs subvolumes:"
    btrfs subvolume list "$MOUNT_POINT" || true
}

update_fstab() {
    print_header "Optional: Add /etc/fstab entry"

    if ! ask_yes_no "Add an /etc/fstab entry for this Btrfs filesystem?"; then
        log "Skipping /etc/fstab modification."
        return
    fi

    local uuid
    uuid=$(blkid -s UUID -o value "$MAPPER_DEV" || true)
    if [[ -z "$uuid" ]]; then
        warn "Could not get UUID for $MAPPER_DEV; not touching /etc/fstab."
        return
    fi

    log "Current mount point: $MOUNT_POINT"
    read -r -p "Filesystem options (default: defaults,compress=zstd): " FSTAB_OPTS
    FSTAB_OPTS=${FSTAB_OPTS:-defaults,compress=zstd}

    local fstab_line
    fstab_line="UUID=$uuid  $MOUNT_POINT  btrfs  $FSTAB_OPTS  0  0"

    log "About to append this line to /etc/fstab:"
    log "$fstab_line"

    if ask_yes_no "Proceed and append to /etc/fstab?"; then
        log "Creating backup of /etc/fstab at /etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
        cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
        printf '%s\n' "$fstab_line" >> /etc/fstab
        log "Entry added to /etc/fstab."
    else
        log "Not modifying /etc/fstab."
    fi
}

delete_ext2_saved() {
    print_header "Optional: Remove ext2_saved backup"

    log "Inside the Btrfs filesystem, a subvolume ext2_saved should exist."
    log "As long as ext2_saved exists, you (in theory) can revert to ext4."
    warn "If you delete ext2_saved, you CANNOT revert using btrfs-convert."
    log "It's recommended to keep ext2_saved for some time until you are confident"
    log "everything works fine with Btrfs."

    if ! ask_yes_no "Do you want to delete ext2_saved NOW (NOT recommended early)?"; then
        log "Keeping ext2_saved."
        return
    fi

    if [[ -z "${MOUNT_POINT:-}" ]]; then
        read -r -p "Enter the mount point where the Btrfs FS is mounted: " MOUNT_POINT
    fi

    if [[ ! -d "$MOUNT_POINT" ]]; then
        warn "Mount point '$MOUNT_POINT' does not exist. Aborting."
        return
    fi

    if [[ ! -d "$MOUNT_POINT/ext2_saved" ]]; then
        warn "'$MOUNT_POINT/ext2_saved' does not exist; nothing to delete."
        return
    fi

    if ! ask_yes_no "Final confirmation: delete '$MOUNT_POINT/ext2_saved'?"; then
        warn "Aborted deletion of ext2_saved."
        return
    fi

    btrfs subvolume delete "$MOUNT_POINT/ext2_saved"
    log "ext2_saved deleted."

    log "Running optional defragment and balance on $MOUNT_POINT."
    if ask_yes_no "Run 'btrfs filesystem defragment -r' and 'btrfs balance start'?"; then
        btrfs filesystem defragment -r "$MOUNT_POINT" || true
        btrfs balance start "$MOUNT_POINT" || true
    else
        log "Skipping defragment and balance."
    fi
}

main() {
    print_header "LUKS ext4 → Btrfs in-place converter (run0, external drive friendly)"

    # We are already root here (either real root or via run0)
    require_cmd cryptsetup btrfs-convert btrfs blkid lsblk mount umount fsck.ext4

    select_device
    ensure_luks
    open_luks
    check_mapper_fs
    umount_if_mounted
    run_fsck_ext4
    run_btrfs_convert
    mount_btrfs
    update_fstab

    log "Conversion to Btrfs is done and the filesystem is mounted."
    log "You can start using it now."

    delete_ext2_saved

    log "All done. Remember:"
    log "- LUKS encryption is unchanged."
    log "- You are now using Btrfs inside the LUKS volume."
    log "- If you kept ext2_saved, you still have a way back to ext (in theory)."
}

main "$@"
