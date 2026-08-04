#!/bin/bash

set -euo pipefail

# Automated apt maintenance script
# - Updates package lists
# - Runs full-upgrade with non-interactive config file handling
# - Backs up /etc before the upgrade
# - Runs autoremove and clean
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

BACKUP_ROOT="/var/backups/apt-config-backups"

# Prefer preserving local configuration files.
# Force defend-against-confold by not overwriting local config.
APT_CONF_OPTS=(
	-o Dpkg::Options::="--force-confdef"
	-o Dpkg::Options::="--force-confold"
	-o APT::Get::Assume-Yes=true
)

log() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	printf '%s [INFO] %s\n' "$ts" "$*"
}
warn() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	printf '%s [WARN] %s\n' "$ts" "$*" >&2
}
error() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	printf '%s [ERROR] %s\n' "$ts" "$*" >&2
}

run_phase_cmd() {
	local label="$1"
	shift

	printf '\n=== %s ===\n\n' "$label"
	if "$@"; then
		return 0
	fi

	return 1
}

apt_suite_enabled() {
	local target="$1"

	# Prefer APT policy metadata when available;
	# it exposes the exact suite name.
	if apt-cache policy 2>/dev/null |
		grep -Eq "release .*n=${target}([, ]|$)"; then
		return 0
	fi

	# Fall back to configured APT source files so we still
	# detect enabled backports before package lists are
	# refreshed or when policy output is sparse.
	if grep -RqsE \
		"^[[:space:]]*Suites:.*(^|[[:space:]])${target}([[:space:]]|$)" \
		/etc/apt/sources.list \
		/etc/apt/sources.list.d 2>/dev/null; then
		return 0
	fi

	if grep -RqsE \
		"^[[:space:]]*deb[[:space:]].*[[:space:]]${target}([[:space:]]|/|$)" \
		/etc/apt/sources.list \
		/etc/apt/sources.list.d 2>/dev/null; then
		return 0
	fi

	return 1
}

declare -a PHASE_ORDER=()
declare -A PHASE_STATUS=()
declare -A PHASE_KIND=()
declare -A PHASE_LABEL=()

record_phase_status() {
	local phase="$1" kind="$2" label="$3" status="$4"
	PHASE_ORDER+=("$phase")
	PHASE_KIND["$phase"]="$kind"
	PHASE_LABEL["$phase"]="$label"
	PHASE_STATUS["$phase"]="$status"
}

run_phase() {
	local phase="$1" kind="$2" label="$3" phase_fn="$4"
	if "$phase_fn"; then
		record_phase_status "$phase" "$kind" "$label" "SUCCESS"
	else
		record_phase_status "$phase" "$kind" "$label" "FAILED"
		if [[ $kind == "mandatory" ]]; then
			error "Mandatory phase failed: ${label}"
		else
			warn "Optional phase failed: ${label}"
		fi
	fi
}

print_phase_summary() {
	local phase status kind
	local mandatory_failures=0 optional_failures=0 successes=0 skipped=0

	printf '\nPhase summary:\n'
	for phase in "${PHASE_ORDER[@]}"; do
		status="${PHASE_STATUS[$phase]}"
		kind="${PHASE_KIND[$phase]}"
		printf ' - %s [%s]: %s\n' "${PHASE_LABEL[$phase]}" "$kind" "$status"
		case "$status" in
		SUCCESS) ((successes += 1)) ;;
		SKIPPED) ((skipped += 1)) ;;
		FAILED)
			if [[ $kind == "mandatory" ]]; then
				((mandatory_failures += 1))
			else
				((optional_failures += 1))
			fi
			;;
		esac
	done

	log "Phase totals: success=${successes}, skipped=${skipped},"
	log "opt_failed=${optional_failures}, man_failed=${mandatory_failures}"
	if ((mandatory_failures > 0)); then
		return 1
	fi
	return 0
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root (sudo)."
		exit 1
	fi
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
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

	# First run: no baseline exists yet, so take a
	# full backup and create the baseline.
	if [[ ! -d $baseline_etc ]] ||
		! find "$baseline_etc" -mindepth 1 \
			-maxdepth 1 -print -quit 2>/dev/null |
		grep -q .; then
		archive="${backup_dir}/etc-full.tar.gz"
		log "No baseline found; creating initial full"
		log "/etc backup at ${archive}..."
		tar --numeric-owner --xattrs --acls \
			-cpzf "$archive" -C / etc
		chmod 0600 "$archive" 2>/dev/null || true

		mkdir -p "$baseline_etc"
		chmod 0700 "$baseline_root" 2>/dev/null || true
		chmod 0700 "$baseline_etc" 2>/dev/null || true
		log "Creating baseline snapshot at ${baseline_etc}..."
		rsync -aHAX --numeric-ids --delete \
			/etc/ "$baseline_etc/" >/dev/null
		umask "$old_umask"
		log "Backup completed"
		log "(initial full + baseline created)."
		return 0
	fi

	log "Detecting modified /etc files vs"
	log "baseline (${baseline_etc})..."
	# This is a 'diff' of /etc vs the baseline via
	# rsync itemized changes. Includes new/changed
	# files and deletions (as '*deleting').
	if ! rsync -aHAX --numeric-ids --delete \
		--dry-run --itemize-changes \
		/etc/ "$baseline_etc/" \
		>"$changes_manifest"; then
		warn "Change detection failed; falling back to full /etc backup."
		archive="${backup_dir}/etc-full.tar.gz"
		log "Backing up /etc to ${archive}..."
		tar --numeric-owner --xattrs --acls -cpzf "$archive" -C / etc
		chmod 0600 "$archive" 2>/dev/null || true
		umask "$old_umask"
		log "Backup completed."
		return 0
	fi

	# Copy changed files into staging, then archive.
	# Unchanged files are skipped; deletions are only
	# recorded in the manifest.
	mkdir -p "${backup_dir}/etc"
	chmod 0700 "${backup_dir}/etc" 2>/dev/null || true

	log "Backing up only changed /etc files to"
	log "${archive}..."
	# --compare-dest skips files identical to baseline.
	rsync -aHAX --numeric-ids \
		--compare-dest="$baseline_etc" \
		/etc/ "${backup_dir}/etc/" >/dev/null || true

	# Avoid producing a misleading archive when nothing changed.
	if ! find "${backup_dir}/etc" \
		-type f -print -quit 2>/dev/null | grep -q .; then
		log "No modified /etc files detected; nothing to back up."
		rm -rf -- "${backup_dir:?}/etc"
		chmod 0600 "$changes_manifest" 2>/dev/null || true
		umask "$old_umask"
		return 0
	fi

	# Archive the staging tree; paths remain under 'etc/'.
	tar --numeric-owner --xattrs --acls \
		-cpzf "$archive" -C "$backup_dir" etc
	chmod 0600 "$archive" 2>/dev/null || true
	chmod 0600 "$changes_manifest" 2>/dev/null || true
	# Remove the staging directory after archiving to save space.
	rm -rf -- "${backup_dir:?}/etc"

	log "Updating baseline snapshot..."
	rsync -aHAX --numeric-ids --delete /etc/ "$baseline_etc/" >/dev/null

	umask "$old_umask"
	log "Backup completed (incremental)."
}

cleanup_old_backups() {
	if [[ ! -d $BACKUP_ROOT ]]; then
		return 0
	fi

	# Keep baseline data; remove timestamped backup
	# directories older than 7 days.
	if find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
		! -name '.baseline' \
		-regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' \
		-mtime +7 -print0 2>/dev/null | xargs -0r rm -rf --; then
		log "Old /etc backups older than 7 days removed (if any)."
	else
		warn "Failed to clean old /etc backups in ${BACKUP_ROOT}."
	fi
}

apt_update() {
	log "Updating package lists..."
	if ! run_phase_cmd "apt update" "$APT_BIN" update; then
		return 1
	fi
}

apt_full_upgrade() {
	local codename target
	local -a apt_opts
	apt_opts=(
		"${APT_CONF_OPTS[@]}"
		-o Dpkg::Options::="--force-confdef"
		-o Dpkg::Options::="--force-confold"
	)

	codename="$(
		. /etc/os-release 2>/dev/null || true
		printf '%s' "${VERSION_CODENAME:-}"
	)"
	if [[ -z $codename ]] && command -v lsb_release >/dev/null 2>&1; then
		codename="$(lsb_release -sc 2>/dev/null || true)"
	fi

	if [[ -n $codename ]]; then
		target="${codename}-backports"
		if apt_suite_enabled "$target"; then
			log "Running full-upgrade with backports (${target})..."
			if ! run_phase_cmd \
				"apt full-upgrade -t ${target}" \
				"$APT_BIN" "${apt_opts[@]}" \
				full-upgrade -t "$target"; then
				return 1
			fi
		else
			log "Backports (${target}) not found; skipping backports pass."
		fi
	else
		warn "Could not determine Debian codename; skipping backports pass."
	fi

	log "Running second full-upgrade pass (all repositories)..."
	if ! run_phase_cmd \
		"apt full-upgrade" \
		"$APT_BIN" "${apt_opts[@]}" \
		full-upgrade; then
		return 1
	fi
}

apt_cleanup() {
	log "Removing unused packages (autoremove)..."
	if ! run_phase_cmd "apt autoremove" "$APT_BIN" -y autoremove; then
		return 1
	fi

	log "Cleaning package cache (clean)..."
	if ! run_phase_cmd "apt clean" "$APT_BIN" -y clean; then
		return 1
	fi
}

restart_services() {
	log "Reloading systemd manager configuration..."
	systemctl daemon-reload ||
		warn "systemctl daemon-reload failed (continuing)."

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
	local audit_ts audit_log audit_report syscheck_log
	audit_ts="$(date +%Y%m%d-%H%M%S)"

	if command -v lynis >/dev/null 2>&1; then
		mkdir -p /tmp/lynis-audit
		audit_log="/tmp/lynis-audit/lynis-${audit_ts}.log"
		audit_report="/tmp/lynis-audit/lynis-${audit_ts}.dat"
		log "Running Lynis security audit..."
		set -o pipefail
		if lynis audit system --quiet \
			--logfile "$audit_log" \
			--report-file "$audit_report" 2>&1 |
			tee "/tmp/lynis-audit/terminal-${audit_ts}.log"; then
			set +o pipefail
			chmod 0600 "$audit_log" "$audit_report" 2>/dev/null || true
			chmod 0600 "/tmp/lynis-audit/terminal-${audit_ts}.log" \
				2>/dev/null || true
			log "Lynis audit saved to /tmp/lynis-audit/lynis-${audit_ts}.log"
		else
			set +o pipefail
			warn "Lynis audit had errors; see /tmp/lynis-audit/."
		fi
	else
		warn "lynis not installed; skipping security audit."
	fi

	if command -v systemcheck >/dev/null 2>&1; then
		syscheck_log="/tmp/systemcheck-${audit_ts}.log"
		local audit_user
		audit_user="${SUDO_USER:-$(logname 2>/dev/null || true)}"
		log "Running systemcheck as ${audit_user:-unknown}..."
		set -o pipefail
		if run_systemcheck_audit "$audit_user" 2>&1 |
			tee "$syscheck_log"; then
			set +o pipefail
			chmod 0600 "$syscheck_log" 2>/dev/null || true
			log "systemcheck saved to ${syscheck_log}"
		else
			set +o pipefail
			warn "systemcheck had errors; see ${syscheck_log}."
		fi
	else
		warn "systemcheck not found; skipping systemcheck run."
	fi

	if find /tmp -maxdepth 1 -type f \
		\( -name 'lynis-audit-*.log' \
		-o -name 'lynis-report-*.dat' \
		-o -name 'systemcheck-*.log' \) \
		-mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old audit logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old audit logs in /tmp."
	fi
}

run_systemcheck_audit() {
	local audit_user="$1" audit_home audit_uid

	if [[ -z $audit_user || $audit_user == "root" ]]; then
		warn "systemcheck skipped: no non-root invoking user found."
		return 1
	fi

	audit_home="$(getent passwd "$audit_user" | cut -d: -f6)"
	audit_uid="$(getent passwd "$audit_user" | cut -d: -f3)"

	if [[ -z $audit_home || -z $audit_uid ]]; then
		warn "systemcheck skipped: cannot resolve HOME/UID"
		warn "for user '$audit_user'."
		return 1
	fi

	if [[ ! -d "/run/user/${audit_uid}" ]] ||
		[[ ! -S "/run/user/${audit_uid}/bus" ]]; then
		warn "systemcheck skipped: user '$audit_user'"
		warn "has no active session bus."
		return 1
	fi

	runuser -u "$audit_user" -- env \
		LANG="$LANG" \
		LC_ALL="$LC_ALL" \
		HOME="$audit_home" \
		USER="$audit_user" \
		LOGNAME="$audit_user" \
		XDG_RUNTIME_DIR="/run/user/${audit_uid}" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${audit_uid}/bus" \
		PATH="$PATH" \
		systemcheck --cli
}

collect_system_info_and_upload() {
	local info_ts info_log
	info_ts="$(date +%Y%m%d-%H%M%S)"
	info_log="/tmp/debian-info-${info_ts}.log"

	log "Collecting system info..."

	print_section() {
		printf '\n---\n\n=== %s ===\n\n' "$1"
	}

	set -o pipefail
	{
		print_section "System Info"
		uname -a
		printf '\n'
		if [[ -f /etc/os-release ]]; then
			cat /etc/os-release
		fi

		print_section "Uptime / Load"
		uptime
		printf '\n'
		free -h 2>/dev/null || true

		print_section "CPU"
		lscpu 2>/dev/null || true

		print_section "Memory (from /proc/meminfo)"
		grep -E '^Mem(Total|Available):' /proc/meminfo 2>/dev/null || true

		print_section "PCI Devices"
		lspci -nn 2>/dev/null || printf 'lspci not available.\n'

		print_section "USB Devices"
		lsusb 2>/dev/null || printf 'lsusb not available.\n'

		print_section "Upgradable Packages"
		apt list --upgradable 2>/dev/null

		print_section "Previous Boot Journal (warnings/errors)"
		journalctl -b -1 -p warning..alert

		print_section "Recent Journal (warnings/errors, last hour)"
		journalctl -p warning..alert --since "1 hour ago"

		print_section "Failed Systemd Services"
		systemctl list-units --state=failed

		print_section "Disk Usage (df -h)"
		df -h

		print_section "Inode Usage (df -i)"
		df -i

		print_section "Block Devices"
		lsblk -f 2>/dev/null || lsblk 2>/dev/null || true

		print_section "Mounts"
		mount || true

		print_section "Network (ip -br a)"
		ip -br a 2>/dev/null || true

		print_section "Routes"
		ip route 2>/dev/null || true

		print_section "Top Processes (by RSS)"
		ps -eo pid,ppid,cmd,%mem,%cpu,rss --sort=-rss | head -n 20
	} 2>&1 | tee "$info_log"
	local rc=$?
	set +o pipefail

	chmod 0600 "$info_log" 2>/dev/null || true
	if [[ $rc -eq 0 ]]; then
		log "System info saved to ${info_log}"
	else
		warn "System info collection had errors; see ${info_log}."
	fi

	if find /tmp -maxdepth 1 -type f \
		-name 'debian-info-*.log' \
		-mtime +7 -print0 2>/dev/null | xargs -0r rm -f; then
		log "Old system info logs older than 7 days removed (if any)."
	else
		warn "Failed to clean old system info logs in /tmp."
	fi
}

check_prereqs() {
	require_cmd date
	require_cmd tar
	require_cmd mktemp
	require_cmd find
	require_cmd chmod
	require_cmd apt-cache
	require_cmd "$APT_BIN"
}

run_maintenance() {
	log "Starting apt maintenance run..."
	PHASE_ORDER=()
	PHASE_STATUS=()
	PHASE_KIND=()
	PHASE_LABEL=()

	run_phase "backup-etc" "mandatory" \
		"Backup /etc" backup_etc
	run_phase "cleanup-old-backups" "optional" \
		"Cleanup old backups" cleanup_old_backups
	run_phase "apt-update" "mandatory" \
		"APT update" apt_update
	run_phase "apt-full-upgrade" "mandatory" \
		"APT full-upgrade" apt_full_upgrade
	run_phase "apt-cleanup" "mandatory" \
		"APT cleanup" apt_cleanup
	run_phase "restart-services" "optional" \
		"Restart services" restart_services
	run_phase "security-audit" "optional" \
		"Security audit" run_security_audit
	run_phase "collect-system-info" "optional" \
		"Collect system info" collect_system_info_and_upload

	if print_phase_summary; then
		log "Debian maintenance run completed."
	else
		error "Debian maintenance run had mandatory phase failures."
		return 1
	fi
}

main() {
	require_root
	check_prereqs
	run_maintenance
}

main "$@"
