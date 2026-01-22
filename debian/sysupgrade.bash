#!/bin/bash

set -euo pipefail

# Automated apt maintenance script
# - Updates package lists
# - Runs full-upgrade with non-interactive config file handling
# - Backs up /etc before the upgrade
# - Runs autoremove and autoclean
# - Reloads systemd and restarts services (if needrestart is available)
# - Collects system information to /var/log/sysupgrade (rotates weekly)
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Force predictable US English output (useful for logs/parsing)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APT_BIN="/bin/apt"

INFO_LOG_DIR="/var/log/debian"

BACKUP_ROOT="/var/backups/apt-config-backups"

# Non-interactive apt
export DEBIAN_FRONTEND=noninteractive

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

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root (sudo)."
		exit 1
	fi
}

backup_etc() {
	local ts backup_dir archive baseline_root baseline_etc changes_manifest
	local old_umask

	ts="$(date +%Y%m%d-%H%M%S)"
	backup_dir="${BACKUP_ROOT}/${ts}"
	baseline_root="${BACKUP_ROOT}/.baseline"
	baseline_etc="${baseline_root}/etc"
	archive="${backup_dir}/etc-changes.tar.gz"
	changes_manifest="${backup_dir}/etc-changes.rsync.txt"

	old_umask="$(umask)"
	umask 077

	mkdir -p "$backup_dir"
	chmod 0700 "$BACKUP_ROOT" 2>/dev/null || true
	chmod 0700 "$backup_dir" 2>/dev/null || true

	if ! command -v rsync >/dev/null 2>&1; then
		warn "rsync not found; falling back to full /etc backup."
		archive="${backup_dir}/etc-full.tar.gz"
		log "Backing up /etc to ${archive}..."
		tar --numeric-owner --xattrs --acls -cpzf "$archive" -C / etc
		chmod 0600 "$archive" 2>/dev/null || true
		umask "$old_umask"
		log "Backup completed."
		return 0
	fi

	# First run: no baseline exists yet, so take a full backup and create the baseline.
	if [[ ! -d "$baseline_etc" ]] || ! find "$baseline_etc" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
		archive="${backup_dir}/etc-full.tar.gz"
		log "No baseline found; creating initial full /etc backup at ${archive}..."
		tar --numeric-owner --xattrs --acls -cpzf "$archive" -C / etc
		chmod 0600 "$archive" 2>/dev/null || true

		mkdir -p "$baseline_etc"
		chmod 0700 "$baseline_root" 2>/dev/null || true
		chmod 0700 "$baseline_etc" 2>/dev/null || true
		log "Creating baseline snapshot at ${baseline_etc}..."
		rsync -aHAX --numeric-ids --delete /etc/ "$baseline_etc/" >/dev/null
		umask "$old_umask"
		log "Backup completed (initial full + baseline created)."
		return 0
	fi

	log "Detecting modified /etc files vs baseline (${baseline_etc})..."
	# This is effectively a 'diff' of /etc vs the baseline, expressed via rsync itemized changes.
	# It includes new/changed files and deletions (as '*deleting').
	if ! rsync -aHAX --numeric-ids --delete --dry-run --itemize-changes /etc/ "$baseline_etc/" >"$changes_manifest"; then
		warn "Change detection failed; falling back to full /etc backup."
		archive="${backup_dir}/etc-full.tar.gz"
		log "Backing up /etc to ${archive}..."
		tar --numeric-owner --xattrs --acls -cpzf "$archive" -C / etc
		chmod 0600 "$archive" 2>/dev/null || true
		umask "$old_umask"
		log "Backup completed."
		return 0
	fi

	# Copy only new/modified files into a staging directory, then archive that.
	# (We don't copy unchanged files; deletions are only recorded in the manifest.)
	mkdir -p "${backup_dir}/etc"
	chmod 0700 "${backup_dir}/etc" 2>/dev/null || true

	log "Backing up only changed /etc files to ${archive}..."
	# --compare-dest skips files identical to the baseline.
	rsync -aHAX --numeric-ids --compare-dest="$baseline_etc" /etc/ "${backup_dir}/etc/" >/dev/null || true

	# If nothing changed, avoid producing a misleading archive.
	if ! find "${backup_dir}/etc" -type f -print -quit 2>/dev/null | grep -q .; then
		log "No modified /etc files detected; nothing to back up."
		rm -rf -- "${backup_dir:?}/etc"
		chmod 0600 "$changes_manifest" 2>/dev/null || true
		umask "$old_umask"
		return 0
	fi

	# Archive the staging tree; paths remain under 'etc/'.
	tar --numeric-owner --xattrs --acls -cpzf "$archive" -C "$backup_dir" etc
	chmod 0600 "$archive" 2>/dev/null || true
	chmod 0600 "$changes_manifest" 2>/dev/null || true
	# Remove the staging directory after archiving to save space.
	rm -rf -- "${backup_dir:?}/etc"

	log "Updating baseline snapshot..."
	rsync -aHAX --numeric-ids --delete /etc/ "$baseline_etc/" >/dev/null

	umask "$old_umask"
	log "Backup completed (incremental)."
}

apt_update() {
	log "Updating package lists..."
	"$APT_BIN" update
}

apt_full_upgrade() {
	local codename target
	log "Running full-upgrade using backports (when available)..."

	codename="$(
		. /etc/os-release 2>/dev/null || true
		printf '%s' "${VERSION_CODENAME:-}"
	)"
	if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
		codename="$(lsb_release -sc 2>/dev/null || true)"
	fi
	if [[ -z "$codename" ]]; then
		warn "Could not determine Debian codename; running full-upgrade without backports."
		"$APT_BIN" -y \
			-o Dpkg::Options::="--force-confdef" \
			-o Dpkg::Options::="--force-confnew" \
			-o Dpkg::Options::="--force-confmiss" \
			-o APT::Get::Assume-Yes=true \
			full-upgrade
		return 0
	fi

	target="${codename}-backports"

	# Only use -t if backports is actually configured.
	if apt-cache policy 2>/dev/null | grep -Fq "$target"; then
		log "Using target release: ${target}"
		"$APT_BIN" -y \
			-o Dpkg::Options::="--force-confdef" \
			-o Dpkg::Options::="--force-confnew" \
			-o Dpkg::Options::="--force-confmiss" \
			-o APT::Get::Assume-Yes=true \
			full-upgrade -t "$target"
	else
		warn "Backports (${target}) not found in APT policy; running full-upgrade without -t."
		"$APT_BIN" -y \
			-o Dpkg::Options::="--force-confdef" \
			-o Dpkg::Options::="--force-confnew" \
			-o Dpkg::Options::="--force-confmiss" \
			-o APT::Get::Assume-Yes=true \
			full-upgrade
	fi
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

run_security_audit() {
	local audit_dir audit_ts audit_log audit_report syscheck_log
	audit_dir="$INFO_LOG_DIR"
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

	if command -v systemcheck >/dev/null 2>&1; then
		audit_ts="$(date +%Y%m%d-%H%M%S)"
		syscheck_log="${audit_dir}/systemcheck-${audit_ts}.log"
		log "Running systemcheck (log: ${syscheck_log})..."
		if systemcheck --quiet >"$syscheck_log" 2>&1; then
			chmod 0600 "$syscheck_log" || true
			log "systemcheck completed."
		else
			warn "systemcheck encountered errors. See ${syscheck_log} for details."
		fi
	else
		warn "systemcheck not found; skipping systemcheck run."
	fi

	if find "$audit_dir" -type f \( -name 'lynis-audit-*.log' -o -name 'lynis-report-*.dat' -o -name 'systemcheck-*.log' \) -mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old security audit logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old security audit logs in ${audit_dir}."
	fi
}

collect_system_info_and_upload() {
	mkdir -p "$INFO_LOG_DIR"

	local info_log
	info_log="${INFO_LOG_DIR}/sysupgrade-info-$(date +%Y%m%d-%H%M%S).log"

	log "Collecting system info to ${info_log}..."

	print_section() {
		printf '\n---\n\n=== %s ===\n\n' "$1"
	}

	local sysinfo hardware_info upgrades recent_events last_boot_events failed_services disk_usage uptime_info mount_info inet_info inode_usage top_procs content tmpfile

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

	if mv "$tmpfile" "$info_log"; then
		chmod 0600 "$info_log" || true
		log "System info written to ${info_log}."
	else
		warn "Failed to write system info to ${info_log}."
		rm -f "$tmpfile"
	fi

	if find "$INFO_LOG_DIR" -type f -name 'sysupgrade-info-*.log' -mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old sysupgrade info logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old sysupgrade info logs in ${INFO_LOG_DIR}."
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
	run_security_audit
	collect_system_info_and_upload
	log "Debian maintenance run completed successfully."
}

main "$@"
