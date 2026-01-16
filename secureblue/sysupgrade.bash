#!/bin/bash
set -euo pipefail

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
#   6. Secureblue debug information collection
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Resolve the real path to this script (follow symlinks)
if command -v readlink >/dev/null 2>&1; then
	SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
	# Fallback: may be relative, but still usable as long as CWD is unchanged
	SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

# Basic PATH (important when run from cron)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Add Homebrew to PATH if present (typical multi-user Linuxbrew locations)
if [[ -d /var/home/linuxbrew/.linuxbrew/bin ]]; then
	PATH="/var/home/linuxbrew/.linuxbrew/bin:$PATH"
elif [[ -d /var/home/linuxbrew/bin ]]; then
	PATH="/var/home/linuxbrew/bin:$PATH"
fi

export PATH

# Force predictable US English output (useful for logs/parsing)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Non-root user for any actions that require a user session (Flatpak --user,
# ujust, brew). This MUST be explicitly configured (no auto-detection).
#
# Configure via either:
#   - CLI: --user USERNAME
#   - Env: SYSUPGRADE_USER=USERNAME
NONROOT_USER="${SYSUPGRADE_USER:-}"

run_as_user() {
	local user="$1"
	shift
	runuser -u "$user" -- "$@"
}

user_home_dir() {
	local user="$1"
	getent passwd "$user" | cut -d: -f6
}

user_uid() {
	local user="$1"
	getent passwd "$user" | cut -d: -f3
}

run_as_user_env() {
	local user="$1"
	shift

	local home uid runtime_dir bus_path
	home="$(user_home_dir "$user" || true)"
	uid="$(user_uid "$user" || true)"

	if [[ -z ${home:-} || -z ${uid:-} ]]; then
		warn "Could not determine HOME/UID for user '$user'; skipping command: $*"
		return 1
	fi

	runtime_dir="/run/user/${uid}"
	bus_path="${runtime_dir}/bus"

	local -a env_vars
	env_vars=(
		"HOME=${home}"
		"USER=${user}"
		"LOGNAME=${user}"
		"PATH=${PATH}"
		"LANG=${LANG}"
		"LC_ALL=${LC_ALL}"
	)

	if [[ -d $runtime_dir ]]; then
		env_vars+=("XDG_RUNTIME_DIR=${runtime_dir}")
		if [[ -S $bus_path ]]; then
			env_vars+=("DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}")
		fi
	fi

	runuser -u "$user" -- env "${env_vars[@]}" "$@"
}

# Simple colors for messages
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
	GREEN="\033[32m"
	YELLOW="\033[33m"
	RED="\033[31m"
	RESET="\033[0m"
else
	GREEN=""
	YELLOW=""
	RED=""
	RESET=""
fi

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

trap 'error "Execution interrupted."; exit 1' INT

# ---- Helpers ---------------------------------------------------------------

# Usage:
#   require_cmd cmd1 cmd2 ...        # required: exits on missing
#   require_cmd --check cmd1 cmd2    # optional check: returns 0/1, no exit
require_cmd() {
	local mode="fatal"
	if [[ ${1:-} == "--check" ]]; then
		mode="check"
		shift
	fi

	local missing=()
	local cmd

	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			if [[ $mode == "fatal" ]]; then
				error "Required command '$cmd' not found in PATH."
			fi
			missing+=("$cmd")
		fi
	done

	if [[ $mode == "fatal" ]]; then
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
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		return 0
	fi

	if require_cmd --check run0; then
		log "Re-executing this script via run0 to gain root privileges..."
		exec run0 -- "$SCRIPT_PATH" "$@"
	else
		error "This script must be run as root and 'run0' was not found. Please run as root or install run0."
		exit 1
	fi
}

validate_nonroot_user() {
	if [[ -z ${NONROOT_USER:-} ]]; then
		error "Non-root user is not configured. Set SYSUPGRADE_USER or pass --user USERNAME."
		exit 1
	fi

	if [[ ${NONROOT_USER} == "root" ]]; then
		error "Refusing to use 'root' as the configured non-root user."
		exit 1
	fi

	local passwd_line uid home shell
	passwd_line="$(getent passwd "$NONROOT_USER" || true)"
	if [[ -z ${passwd_line:-} ]]; then
		error "Configured non-root user '$NONROOT_USER' does not exist (getent passwd failed)."
		exit 1
	fi

	uid="$(printf '%s' "$passwd_line" | cut -d: -f3)"
	home="$(printf '%s' "$passwd_line" | cut -d: -f6)"
	shell="$(printf '%s' "$passwd_line" | cut -d: -f7)"

	if [[ -z ${uid:-} || ${uid} -lt 1000 || ${uid} -ge 60000 ]]; then
		warn "Configured user '$NONROOT_USER' has uid='$uid' (expected a normal user uid between 1000 and 59999)."
	fi

	if [[ -z ${home:-} || ! -d ${home} ]]; then
		warn "Configured user '$NONROOT_USER' has HOME='${home}', which is missing. Some per-user actions may fail."
	fi

	if [[ -n ${shell:-} && ${shell} =~ (false|nologin)$ ]]; then
		warn "Configured user '$NONROOT_USER' has shell='${shell}'. Some per-user actions may fail."
	fi
}

# Print usage and exit
usage() {
	cat <<'USAGE'
Usage: sysupgrade.bash [OPTIONS]

Options:
	--user USERNAME    Non-root user for per-user actions (required)
	                  (or set SYSUPGRADE_USER=USERNAME)
  --skip-audit       Skip running the Lynis security audit phase
  --skip-collect     Skip collecting Secureblue system information
  --help             Show this help message
USAGE
	exit 0
}

# Parse CLI arguments (set SKIP_AUDIT and SKIP_COLLECT)
parse_args() {
	while [[ ${1:-} != "" ]]; do
		case "$1" in
		--user)
			shift
			if [[ -z ${1:-} ]]; then
				error "--user requires a username argument."
				exit 1
			fi
			NONROOT_USER="$1"
			shift
			;;
		--skip-audit)
			SKIP_AUDIT=1
			shift
			;;
		--skip-collect)
			SKIP_COLLECT=1
			shift
			;;
		--help | -h)
			usage
			;;
		*)
			# Unknown or positional arg — stop parsing
			break
			;;
		esac
	done
}

# ---- Maintenance phases ----------------------------------------------------

update_system_image() {
	if ! require_cmd --check rpm-ostree; then
		warn "rpm-ostree not found, skipping system image update."
		return
	fi
	disk_usage=$(
		{
			printf '\n=== Disk Usage (df -h) ===\n\n'
			if require_cmd --check df; then
				df -h
			else
				printf 'df not available.\n'
			fi
		} 2>&1 || true
	)

	log "Updating system via rpm-ostree (non-interactive)..."
	rpm-ostree update || warn "rpm-ostree update failed (continuing)."
	rpm-ostree upgrade || warn "rpm-ostree upgrade failed (continuing)."
	rpm-ostree cleanup -bm || warn "rpm-ostree cleanup failed (continuing)."
}

update_firmware() {
	if ! require_cmd --check fwupdmgr; then
		warn "fwupdmgr not found, skipping firmware."
		return
	fi

	log "Updating firmware via fwupdmgr (non-interactive)..."
	fwupdmgr refresh --force || warn "fwupdmgr refresh failed (continuing)."
	fwupdmgr get-updates || warn "fwupdmgr get-updates failed (continuing)."
	fwupdmgr update -y --no-reboot-check || warn "fwupdmgr update failed (continuing)."
}

update_homebrew() {
	log "Updating Homebrew applications..."

	# Never run "brew" as root. Determine a primary non-root user and
	# execute brew via that user's context using "runuser"/"run_as_user".
	local BREW_PREFIX PREFIX_UID PREFIX_GID BREW_USER

	if ! require_cmd --check runuser; then
		warn "'runuser' not available; skipping Homebrew update to avoid running brew as root."
		return
	fi

	# Check that the user actually has brew available and query its prefix
	if ! runuser -u "$NONROOT_USER" -- bash -lc 'command -v brew >/dev/null 2>&1'; then
		warn "brew not available for configured user '$NONROOT_USER'; skipping Homebrew update."
		return
	fi

	BREW_PREFIX="$(runuser -u "$NONROOT_USER" -- brew --prefix 2>/dev/null || true)"
	if [[ -z ${BREW_PREFIX:-} || ! -d $BREW_PREFIX ]]; then
		warn "Could not determine a valid Homebrew prefix for configured user '$NONROOT_USER'; skipping Homebrew update."
		return
	fi

	PREFIX_UID="$(stat -c '%u' "$BREW_PREFIX" 2>/dev/null || printf '')"
	PREFIX_GID="$(stat -c '%g' "$BREW_PREFIX" 2>/dev/null || printf '')"

	if [[ -z $PREFIX_UID || -z $PREFIX_GID ]]; then
		warn "Could not read UID/GID for '$BREW_PREFIX'; skipping Homebrew update to avoid running as root."
		return
	fi

	BREW_USER="$(getent passwd "$PREFIX_UID" | cut -d: -f1 || true)"
	if [[ -z ${BREW_USER:-} ]]; then
		warn "Could not map UID=$PREFIX_UID to a username; skipping Homebrew update to avoid running as root."
		return
	fi

	if [[ $BREW_USER == "root" ]]; then
		warn "Homebrew prefix at '$BREW_PREFIX' is owned by root; skipping Homebrew update because running brew as root is unsafe."
		return
	fi

	if [[ $BREW_USER != "$NONROOT_USER" ]]; then
		warn "Homebrew prefix owner is '$BREW_USER' but configured non-root user is '$NONROOT_USER'."
		warn "Skipping Homebrew update to keep runuser actions stable. Configure --user '$BREW_USER' or fix prefix ownership."
		return
	fi

	log "Running brew as configured user: $NONROOT_USER"
	run_as_user "$NONROOT_USER" brew update || warn "brew update failed (continuing)."
	run_as_user "$NONROOT_USER" brew upgrade || warn "brew upgrade failed (continuing)."
	run_as_user "$NONROOT_USER" brew cleanup || warn "brew cleanup failed (continuing)."
}

update_flatpak() {
	if ! require_cmd --check flatpak; then
		warn "flatpak not found, skipping Flatpak."
		return
	fi

	log "Updating and repairing Flatpak system installation..."
	flatpak repair --system || warn "flatpak system repair failed (continuing)."
	flatpak update --system -y || warn "flatpak system update failed (continuing)."
	flatpak uninstall --system --unused -y || warn "flatpak system cleanup failed (continuing)."

	# Per-user updates
	if ! require_cmd --check runuser; then
		warn "'runuser' not available; skipping per-user Flatpak updates/repairs."
		return
	fi

	log "Updating and repairing Flatpak user installation for configured user: ${NONROOT_USER}"
	local home
	home="$(user_home_dir "$NONROOT_USER" || true)"
	if [[ -n ${home:-} && -d $home && -d "$home/.local/share/flatpak" ]]; then
		run_as_user_env "$NONROOT_USER" flatpak repair --user || warn "flatpak user repair failed for $NONROOT_USER (continuing)."
		run_as_user_env "$NONROOT_USER" flatpak update --user -y || warn "flatpak user update failed for $NONROOT_USER (continuing)."
		run_as_user_env "$NONROOT_USER" flatpak uninstall --user --unused -y || warn "flatpak user cleanup failed for $NONROOT_USER (continuing)."
	else
		warn "No per-user Flatpak installation detected for '${NONROOT_USER}' (missing ${home:-<unknown>}/.local/share/flatpak); skipping per-user Flatpak maintenance."
	fi
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
		[[ -z $mnt ]] && continue
		[[ $fstype != "btrfs" && $fstype != "ext4" ]] && continue

		local dev="/dev/$name"

		case "$fstype" in
		btrfs)
			# First mountpoint seen for this device
			if [[ -z ${btrfs_dev_mp[$dev]:-} ]]; then
				btrfs_dev_mp["$dev"]="$mnt"
			fi
			;;
		ext4)
			if [[ -z ${ext4_dev_mp[$dev]:-} ]]; then
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
				btrfs scrub start -Bd "$mp" ||
					warn "btrfs scrub failed for $mp (continuing)."

				# Full balance: reorganize all chunks (can be heavy on large disks, but non-destructive)
				btrfs balance start --full-balance "$mp" ||
					warn "btrfs balance failed for $mp (continuing)."

				# Recursive defragmentation (can take a while, but non-destructive)
				btrfs filesystem defragment -r "$mp" ||
					warn "btrfs filesystem defragment failed for $mp (continuing)."
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
				e4defrag -c "$mp" ||
					warn "e4defrag check failed for $mp (continuing)."

				# Online defragmentation (non-destructive, but can take some time)
				e4defrag "$mp" ||
					warn "e4defrag defragmentation failed for $mp (continuing)."
			done
		fi
	fi
}

run_security_audit() {
	local audit_dir audit_ts audit_log audit_report
	audit_dir="/var/log/secureblue"
	mkdir -p "$audit_dir"

	if command -v lynis >/dev/null 2>&1; then
		audit_ts="$(date +%Y%m%d-%H%M%S)"
		audit_log="${audit_dir}/lynis-audit-${audit_ts}.log"
		audit_report="${audit_dir}/lynis-report-${audit_ts}.dat"
		log "Running Lynis security audit (log: ${audit_log}, report: ${audit_report})..."
		if lynis audit system --quiet --logfile "$audit_log" --report-file "$audit_report"; then
			chmod 0600 "$audit_log" "$audit_report" || true
			log "Lynis security audit completed."
		else
			warn "Lynis security audit encountered errors. See ${audit_log} for details."
		fi
	else
		warn "lynis not installed; skipping security audit."
	fi

	if find "$audit_dir" -type f \( -name 'lynis-audit-*.log' -o -name 'lynis-report-*.dat' \) -mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old security audit logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old security audit logs in ${audit_dir}."
	fi
}

collect_system_info() {
	if ! require_cmd --check ujust fpaste; then
		warn "ujust or fpaste not found; skipping Secureblue information collection."
		return
	fi

	local info_log_dir info_log
	info_log_dir="/var/log/secureblue"
	mkdir -p "$info_log_dir"
	info_log="${info_log_dir}/secureblue-info-$(date +%Y%m%d-%H%M%S).log"

	# Use a configured non-root user for any user-context commands.
	local run_user
	if require_cmd --check runuser; then
		run_user="runuser -u ${NONROOT_USER} --"
		log "Running ujust/flatpak/brew info as configured user: ${NONROOT_USER}"
	else
		run_user=""
		warn "'runuser' not available; ujust/flatpak will run as root; brew info will be skipped."
	fi

	log "Collecting Secureblue debug information to ${info_log} (non-interactive)..."

	print_section() {
		printf '\n---\n\n=== %s ===\n\n' "$1"
	}

	local sysinfo rpm_ostree_status flatpaks homebrew_packages
	local audit_results local_overrides recent_events last_boot_events failed_services brew_services disk_usage
	local content tmpfile

	sysinfo=$(
		{
			print_section "System Info"
			fpaste --sysinfo --printonly
		} 2>&1 || true
	)

	rpm_ostree_status=$(
		{
			print_section "Rpm-Ostree Status"
			if require_cmd --check rpm-ostree; then
				rpm-ostree status --verbose
			else
				printf 'rpm-ostree not available.\n'
			fi
		} 2>&1 || true
	)

	flatpaks=$(
		{
			print_section "Flatpaks Installed"
			if require_cmd --check flatpak; then
				if [[ -n ${run_user:-} ]]; then
					# Run flatpak as the configured non-root user
					$run_user flatpak list --columns=application,version,options
				else
					flatpak list --columns=application,version,options
				fi
			else
				printf 'flatpak not available.\n'
			fi
		} 2>&1 || true
	)

	homebrew_packages=$(
		{
			print_section "Homebrew Packages Installed"
			if require_cmd --check brew; then
				if [[ -n ${run_user:-} ]]; then
					# Run brew as the configured non-root user
					$run_user brew list --versions
				else
					warn "Skipping brew list --versions because running brew as root is unsafe."
				fi
			else
				printf 'brew not available.\n'
			fi
		} 2>&1 || true
	)

	audit_results=$(
		{
			print_section "Audit Results"
			if [[ -n ${run_user:-} ]]; then
				# Run ujust as the configured non-root user
				$run_user ujust audit-secureblue
			else
				ujust audit-secureblue
			fi
		} 2>&1 || true
	)

	local_overrides=$(
		{
			print_section "Listing Local Overrides"
			if [[ -n ${run_user:-} ]]; then
				# Run ujust as the configured non-root user
				$run_user ujust check-local-overrides
			else
				ujust check-local-overrides
			fi
		} 2>&1 || true
	)

	last_boot_events=$(
		{
			print_section "Previous Boot Events (warnings/errors)"
			journalctl -b -1 -p warning..alert
		} 2>&1 || true
	)

	recent_events=$(
		{
			print_section "Recent System Events (warnings/errors, last hour)"
			journalctl -b -p warning..alert --since "1 hour ago"
		} 2>&1 || true
	)

	failed_services=$(
		{
			print_section "Failed Systemd Services (system)"
			systemctl list-units --state=failed || true

			print_section "Failed Systemd Services (user: ${NONROOT_USER})"
			if require_cmd --check runuser; then
				if ! run_as_user_env "$NONROOT_USER" systemctl --user list-units --state=failed; then
					printf 'Could not query user systemd instance for %s (no session bus / XDG_RUNTIME_DIR?).\n' "$NONROOT_USER"
				fi
			else
				printf "'runuser' not available; skipping user systemd status.\n"
			fi
		} 2>&1 || true
	)

	brew_services=$(
		{
			print_section "Homebrew Services Status"
			if require_cmd --check brew; then
				if [[ -n ${run_user:-} ]]; then
					# Run brew services as the configured non-root user
					$run_user brew services info --all
				else
					warn "Skipping brew services info --all because running brew as root is unsafe."
				fi
			else
				printf 'brew not available.\n'
			fi
		} 2>&1 || true
	)

	disk_usage=$(
		{
			print_section "Disk Usage (df -h)"
			if require_cmd --check df; then
				df -h
			else
				printf 'df not available.\n'
			fi
		} 2>&1 || true
	)

	content="${sysinfo}${rpm_ostree_status}${flatpaks}${homebrew_packages}${audit_results}${local_overrides}${last_boot_events}${recent_events}${failed_services}${brew_services}${disk_usage}"

	tmpfile="$(mktemp /tmp/secureblue-info.XXXXXX)"
	printf "%s\n" "$content" >"$tmpfile"

	if mv "$tmpfile" "$info_log"; then
		chmod 0600 "$info_log" || true
		log "Secureblue information written to ${info_log}."
	else
		warn "Failed to write Secureblue information to ${info_log}."
		rm -f "$tmpfile"
	fi

	if find "$info_log_dir" -type f -name 'secureblue-info-*.log' -mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old Secureblue info logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old Secureblue info logs in ${info_log_dir}."
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
	if [[ -z ${SKIP_AUDIT:-} ]]; then
		run_security_audit
	else
		log "Skipping security audit (flag set)."
	fi

	if [[ -z ${SKIP_COLLECT:-} ]]; then
		collect_system_info
	else
		log "Skipping Secureblue information collection (flag set)."
	fi

	log "Update process completed."
}

# Entry point
ensure_root "$@"
# Parse CLI args (may set SKIP_AUDIT or SKIP_COLLECT)
parse_args "$@"
# Base tools we use without extra checks
require_cmd awk getent stat journalctl systemctl
# Ensure we have an explicit, stable non-root user for runuser actions
validate_nonroot_user
main "$@"
