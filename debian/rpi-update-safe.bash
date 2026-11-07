#!/bin/bash

set -euo pipefail

# Safely update Raspberry Pi 5 firmware and repair the selected boot files.
#
# Usage: rpi-update-safe [--repair-only] [rpi-update arguments...]
#
# Requires root, the official rpi-update utility, device-tree-compiler,
# dracut, and the standard Debian boot/module tools. The updater is invoked
# with rebooting disabled. The script backs up files it replaces but does
# not create a complete rollback of changes made by rpi-update.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Preserve the original path and arguments so require_root can re-exec the
# script through sudo without losing user-supplied options.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	SCRIPT_PATH="${BASH_SOURCE[0]}"
else
	SCRIPT_PATH="$0"
fi
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_ARGS=("$@")
export LC_ALL=C
PERL_CMD="${PERL_CMD:-perl}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
BOOTARGS_HELPER="${BOOTARGS_HELPER:-}"
if [ -z "$BOOTARGS_HELPER" ]; then
	BOOTARGS_HELPER="${SCRIPT_DIR}/bootargs.pl"
	[ -f "$BOOTARGS_HELPER" ] || BOOTARGS_HELPER="${SCRIPT_DIR}/bootargs"
fi

readonly RPI_UPDATE=/usr/bin/rpi-update
readonly BOOT_DIR=/boot/firmware
readonly DTB=${BOOT_DIR}/bcm2712-rpi-5-b.dtb
readonly KERNEL_IMAGE=${BOOT_DIR}/kernel_2712.img
readonly LOCK_FILE=/run/rpi-update-safe.lock

WORK_DIRS=()
NEW_WORK_DIR=

log() {
	printf '%s [INFO] rpi-update-safe: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
	printf '%s [ERROR] rpi-update-safe: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
	error "$*"
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Re-exec through sudo when the script was not started as root. SCRIPT_ARGS
# keeps the original command line across the privilege boundary.
ROOT_ENV_VARS=(PERL_CMD BOOTARGS_HELPER)

require_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		error "Root privileges are required and sudo was not found."
		exit 1
	fi
	local -a env_args=()
	local name
	for name in "${ROOT_ENV_VARS[@]}"; do
		if [[ -v $name ]]; then
			env_args+=("$name=${!name}")
		fi
	done
	log "Re-executing this script via sudo to gain root privileges..."
	if ((${#env_args[@]} > 0)); then
		exec sudo -- env "${env_args[@]}" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
	fi
	exec sudo -- "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

cleanup() {
	local work
	for work in "${WORK_DIRS[@]}"; do
		# Remove only temporary directories created under the mounted boot tree.
		case "$work" in
		"${BOOT_DIR}"/.rpi-update-safe.*)
			if [[ -d $work && ! -L $work ]]; then
				rm -rf -- "$work"
			fi
			;;
		esac
	done
}

new_boot_work_dir() {
	NEW_WORK_DIR=$(mktemp -d -- "${BOOT_DIR}/.rpi-update-safe.XXXXXX") ||
		die "cannot create a work directory under ${BOOT_DIR}"
	WORK_DIRS+=("$NEW_WORK_DIR")
}

create_backup() {
	local source=$1
	local timestamp=$2
	local backup
	backup=$(mktemp -- "${source}.bak.${timestamp}.XXXXXX") ||
		die "cannot reserve a backup path for ${source}"
	# Keep a unique, metadata-preserving copy beside the file being replaced.
	if ! cp -a -- "$source" "$backup" || ! cmp -s -- "$source" "$backup"; then
		rm -f -- "$backup"
		die "backup verification failed for ${source}"
	fi
	log "backup created: ${backup}"
}

normalize_bootargs() {
	# Compare argument tokens without treating whitespace formatting as a change.
	printf '%s\n' "$1" |
		"$PERL_CMD" "$BOOTARGS_HELPER" normalize
}

contains_memory_cgroup_arg() {
	[[ $1 =~ (^|[[:space:]])cgroup_disable=memory([[:space:]]|$) ]]
}

check_platform() {
	local model
	# Refuse to update a stale /boot directory or a non-Pi-5 installation.
	[[ -d $BOOT_DIR && ! -L $BOOT_DIR ]] || die "invalid boot directory: ${BOOT_DIR}"
	mountpoint -q -- "$BOOT_DIR" || die "${BOOT_DIR} is not a mounted boot filesystem"
	[[ -r /proc/device-tree/model ]] || die 'cannot identify the Raspberry Pi model'
	model=$(tr -d '\000' </proc/device-tree/model)
	[[ $model == *'Raspberry Pi 5'* ]] || die "unsupported device model: ${model:-unknown}"
	[[ -f $DTB && ! -L $DTB && -s $DTB ]] || die "missing or invalid selected DTB: ${DTB}"
}

repair_dtb() {
	local work dts new before after before_rest after_rest timestamp
	new_boot_work_dir
	work=$NEW_WORK_DIR
	dts=${work}/original.dts
	new=${work}/new.dtb

	dtc -I dtb -O dts -o "$dts" "$DTB" || die "cannot decompile ${DTB}"
	before=$(sed -n 's/^[[:space:]]*bootargs[[:space:]]*=[[:space:]]*"\(.*\)";[[:space:]]*$/\1/p' "$dts")
	[[ -n $before ]] || die "no bootargs property found in ${DTB}"

	if ! contains_memory_cgroup_arg "$before"; then
		log "cgroup_disable=memory is already absent from ${DTB}"
		return 0
	fi

	# Remove only a complete boot argument token from bootargs properties.
	# The token-by-token comparison below rejects any other DTS round-trip change.
	"$PERL_CMD" "$BOOTARGS_HELPER" remove-token "$dts" ||
		die 'cannot remove cgroup_disable=memory from the DTB source'
	dtc -I dts -O dtb -o "$new" "$dts" || die 'cannot compile the repaired DTB'
	after=$(dtc -I dtb -O dts "$new" | sed -n 's/^[[:space:]]*bootargs[[:space:]]*=[[:space:]]*"\(.*\)";[[:space:]]*$/\1/p')
	[[ -n $after ]] || die 'the repaired DTB has no bootargs property'
	if contains_memory_cgroup_arg "$after"; then
		die 'the repaired DTB still contains cgroup_disable=memory'
	fi
	before_rest=$(normalize_bootargs "$before")
	after_rest=$(normalize_bootargs "$after")
	[[ $after_rest == "$before_rest" ]] ||
		die 'bootargs changed beyond removal of cgroup_disable=memory'

	chmod --reference="$DTB" "$new" || die 'cannot preserve DTB permissions'
	chown --reference="$DTB" "$new" || die 'cannot preserve DTB ownership'
	timestamp=$(date '+%Y%m%d-%H%M%S')
	create_backup "$DTB" "$timestamp"
	# The staged DTB is on the same filesystem, so rename replaces it atomically.
	mv -fT -- "$new" "$DTB" || die "cannot atomically replace ${DTB}"
	sync
	log "patched ${DTB}"
}

regenerate_initramfs() {
	local kver work generated timestamp
	[[ -f $KERNEL_IMAGE && ! -L $KERNEL_IMAGE && -s $KERNEL_IMAGE ]] ||
		die "missing or invalid installed kernel image: ${KERNEL_IMAGE}"
	kver=$(gzip -dc "$KERNEL_IMAGE" 2>/dev/null | strings | sed -n 's/^Linux version \([^ ]*\).*/\1/p' | sed -n '1p')
	[[ $kver =~ ^[0-9]+\.[0-9]+\.[0-9]+- ]] || die "cannot identify KVER from ${KERNEL_IMAGE}"
	[[ -d /lib/modules/$kver && ! -L /lib/modules/$kver ]] || die "missing modules directory for ${kver}"

	# Refresh module dependency metadata before building the matching initramfs.
	depmod -a "$kver" || die "depmod failed for ${kver}"
	[[ -f /lib/modules/$kver/modules.dep && -s /lib/modules/$kver/modules.dep ]] ||
		die "depmod did not create modules.dep for ${kver}"

	new_boot_work_dir
	work=$NEW_WORK_DIR
	generated=${work}/initramfs_2712
	dracut --force --kver "$kver" "$generated" || die "dracut failed for ${kver}"
	[[ -f $generated && -s $generated ]] || die 'dracut produced an empty or invalid initramfs'
	lsinitrd "$generated" >/dev/null || die 'generated initramfs failed lsinitrd validation'

	[[ ! -L ${BOOT_DIR}/initramfs_2712 ]] || die 'initramfs_2712 must not be a symlink'
	if [[ -e ${BOOT_DIR}/initramfs_2712 ]]; then
		[[ -f ${BOOT_DIR}/initramfs_2712 ]] ||
			die 'existing initramfs_2712 is not a regular file'
		chmod --reference="${BOOT_DIR}/initramfs_2712" "$generated" ||
			die 'cannot preserve initramfs permissions'
		chown --reference="${BOOT_DIR}/initramfs_2712" "$generated" ||
			die 'cannot preserve initramfs ownership'
		timestamp=$(date '+%Y%m%d-%H%M%S')
		create_backup "${BOOT_DIR}/initramfs_2712" "$timestamp"
	else
		chmod 0644 "$generated" || die 'cannot set initramfs permissions'
	fi

	# The generated image is staged under BOOT_DIR to avoid a cross-filesystem move.
	mv -fT -- "$generated" "${BOOT_DIR}/initramfs_2712" ||
		die 'cannot atomically install the generated initramfs'
	sync
	log "generated initramfs for ${kver}"
}

usage() {
	cat <<'EOF'
Usage: rpi-update-safe [--repair-only] [rpi-update arguments...]

Run the official Raspberry Pi updater with rebooting disabled, then remove
the cgroup_disable=memory boot argument from the Raspberry Pi 5 DTB and
regenerate its initramfs. The script requires root access and re-executes
itself through sudo on a Raspberry Pi 5 with /boot/firmware mounted.

Options:
  --repair-only  Skip rpi-update and repair the current DTB only.
  -h, --help     Show this help and exit.
EOF
}

main() {
	local repair_only=0 command_name
	if [[ ${1:-} == -h || ${1:-} == --help ]]; then
		usage
		return 0
	fi
	if [[ ${1:-} == --repair-only ]]; then
		[[ $# -eq 1 ]] || die '--repair-only does not accept additional arguments'
		repair_only=1
	fi

	require_root
	for command_name in date mountpoint tr dtc perl sed cp cmp mktemp rm mv sync \
		gzip strings dracut lsinitrd depmod flock; do
		require_cmd "$command_name"
	done
	[[ -x $RPI_UPDATE ]] || die "missing official updater: ${RPI_UPDATE}"
	[[ -f $BOOTARGS_HELPER ]] ||
		die "missing bootargs helper: ${BOOTARGS_HELPER}"
	check_platform
	[[ ! -L $LOCK_FILE ]] || die "lock path must not be a symlink: ${LOCK_FILE}"

	# Serialize updates so concurrent runs cannot replace the same boot files.
	exec 9>"$LOCK_FILE"
	flock -n 9 || die 'another rpi-update-safe process is already running'

	if [[ $repair_only -eq 0 ]]; then
		RPI_REBOOT=0 "$RPI_UPDATE" "$@"
		check_platform
	fi

	repair_dtb
	if [[ $repair_only -eq 0 ]]; then
		regenerate_initramfs
	fi
}

trap cleanup EXIT
main "$@"
