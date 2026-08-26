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
	# Fallback: may be relative, but still usable as long as
	# CWD is unchanged
	SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

# Basic PATH (important when run from cron)
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Force predictable US English output (useful for logs/parsing)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Non-root desktop user for per-user Flatpak/ujust actions and Homebrew through
# brew-proxy. This user MUST be explicitly configured (no auto-detection).
#
# Configure via either:
#   - CLI: --user USERNAME
#   - Env: SYSUPGRADE_USER=USERNAME
NONROOT_USER="${SYSUPGRADE_USER:-}"

run_phase_cmd() {
	local label="$1"
	shift
	printf '\n=== %s ===\n\n' "$label"
	"$@"
}

user_home_dir() {
	local user="$1"
	getent passwd "$user" | cut -d: -f6
}

user_uid() {
	local user="$1"
	getent passwd "$user" | cut -d: -f3
}

# Homebrew stays out of root's PATH. All Homebrew commands use the
# installed brew-proxy client as the configured non-root user.
HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_PROXY_COMMAND="/usr/bin/brew-proxy"
HOMEBREW_USER_HOME=""
HOMEBREW_USER_UID=""
HOMEBREW_ERROR=""

homebrew_available() {
	local dispatcher="${HOMEBREW_PREFIX}/bin/brew"
	local original="${HOMEBREW_PREFIX}/proxy/brew-original"

	HOMEBREW_ERROR=""
	HOMEBREW_USER_HOME="$(user_home_dir "$NONROOT_USER" || true)"
	HOMEBREW_USER_UID="$(user_uid "$NONROOT_USER" || true)"
	if [[ -z $HOMEBREW_USER_HOME || -z $HOMEBREW_USER_UID ||
		$HOMEBREW_USER_UID -eq 0 ]]; then
		HOMEBREW_ERROR="Cannot determine a non-root execution context for '${NONROOT_USER}'."
		return 1
	fi
	if [[ ! -x $BREW_PROXY_COMMAND ]]; then
		HOMEBREW_ERROR="brew-proxy client '${BREW_PROXY_COMMAND}' is missing or not executable."
		return 1
	fi
	if [[ ! -x $dispatcher || ! -x $original ]]; then
		HOMEBREW_ERROR="brew-proxy is not fully configured under '${HOMEBREW_PREFIX}'."
		return 1
	fi
	return 0
}

run_homebrew() {
	if ! homebrew_available; then
		error "Homebrew unavailable: ${HOMEBREW_ERROR}"
		return 1
	fi

	local runtime_dir="/run/user/${HOMEBREW_USER_UID}"
	local bus_path="${runtime_dir}/bus"
	local -a homebrew_env
	homebrew_env=(
		"HOME=${HOMEBREW_USER_HOME}"
		"USER=${NONROOT_USER}"
		"LOGNAME=${NONROOT_USER}"
		"PATH=${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
		"LANG=C.UTF-8"
		"LC_ALL=C.UTF-8"
		"XDG_DATA_DIRS=/home/linuxbrew/.local/share:/usr/local/share:/usr/share"
		"HOMEBREW_CASK_OPTS=--require-sha"
		"HOMEBREW_NO_ASK=1"
		"HOMEBREW_NO_ENV_HINTS=1"
		"BREW_PROXY_NONINTERACTIVE=1"
		"GIT_TERMINAL_PROMPT=0"
	)
	if [[ -d $runtime_dir ]]; then
		homebrew_env+=("XDG_RUNTIME_DIR=${runtime_dir}")
		if [[ -S $bus_path ]]; then
			homebrew_env+=(
				"DBUS_SESSION_BUS_ADDRESS=unix:path=${bus_path}"
			)
		fi
	fi

	# shellcheck disable=SC2016 # Expanded by the delegated shell.
	runuser -u "$NONROOT_USER" -- env -i \
		"${homebrew_env[@]}" /bin/sh -c '
		if [ "$(/usr/bin/id -u)" -eq 0 ]; then
			echo "Refusing to execute Homebrew with EUID 0." >&2
			exit 126
		fi
		cd "$HOME" || exit 126
		exec "$@"
	' sysupgrade-homebrew "$BREW_PROXY_COMMAND" "$@" </dev/null
}

run_as_user_env() {
	local user="$1"
	shift

	local home uid runtime_dir bus_path
	home="$(user_home_dir "$user" || true)"
	uid="$(user_uid "$user" || true)"

	if [[ -z ${home:-} || -z ${uid:-} ]]; then
		warn "Could not determine HOME/UID for" \
			" user '$user'; skipping command: $*"
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

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

trap 'error "Execution interrupted."; exit 1' INT

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

mark_phase_skipped() {
	local phase="$1" kind="$2" label="$3" reason="$4"
	record_phase_status "$phase" "$kind" "$label" "SKIPPED"
	log "Skipping ${label}: ${reason}"
}

print_phase_summary() {
	local phase status kind
	local mandatory_failures=0 optional_failures=0
	local successes=0 skipped=0

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

	log "Phase totals: success=${successes}," \
		"skipped=${skipped}," \
		"optional_failed=${optional_failures}," \
		"mandatory_failed=${mandatory_failures}"
	if ((mandatory_failures > 0)); then
		return 1
	fi
	return 0
}

# ---- Helpers ----

# Usage:
#   require_cmd cmd1 cmd2 ...        # required: exits on missing
#   require_cmd --check cmd1 cmd2
#     optional check: returns 0/1, no exit
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
		error "This script must be run as root and" \
			" 'run0' was not found." \
			" Please run as root or install run0."
		exit 1
	fi
}

validate_nonroot_user() {
	if [[ -z ${NONROOT_USER:-} ]]; then
		error "Non-root user is not configured." \
			" Set SYSUPGRADE_USER or" \
			" pass --user USERNAME."
		exit 1
	fi

	if [[ ${NONROOT_USER} == "root" ]]; then
		error "Refusing to use 'root' as the configured non-root user."
		exit 1
	fi

	local passwd_line uid home shell
	passwd_line="$(getent passwd "$NONROOT_USER" || true)"
	if [[ -z ${passwd_line:-} ]]; then
		error "Configured non-root user" \
			" '$NONROOT_USER' does not exist" \
			" (getent passwd failed)."
		exit 1
	fi

	uid="$(printf '%s' "$passwd_line" | cut -d: -f3)"
	home="$(printf '%s' "$passwd_line" | cut -d: -f6)"
	shell="$(printf '%s' "$passwd_line" | cut -d: -f7)"

	if [[ -z ${uid:-} || ${uid} -lt 1000 || ${uid} -ge 60000 ]]; then
		warn "Configured user '${NONROOT_USER}'" \
			" has uid='${uid}'" \
			" (expected a normal user uid" \
			" between 1000 and 59999)."
	fi

	if [[ -z ${home:-} || ! -d ${home} ]]; then
		warn "Configured user '${NONROOT_USER}'" \
			" has HOME='${home}', which is" \
			" missing. Some per-user actions" \
			" may fail."
	fi

	if [[ -n ${shell:-} && ${shell} =~ (false|nologin)$ ]]; then
		warn "Configured user '${NONROOT_USER}'" \
			" has shell='${shell}'." \
			" Some per-user actions may fail."
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
	local flag_used=0
	while [[ ${1:-} != "" ]]; do
		case "$1" in
		--user)
			flag_used=1
			shift
			if [[ -z ${1:-} ]]; then
				error "--user requires a username argument."
				exit 1
			fi
			NONROOT_USER="$1"
			shift
			;;
		--skip-audit)
			flag_used=1
			SKIP_AUDIT=1
			shift
			;;
		--skip-collect)
			flag_used=1
			SKIP_COLLECT=1
			shift
			;;
		--help | -h)
			flag_used=1
			warn "CLI flag detected; using" \
				" non-default options instead of" \
				" standard behavior."
			usage
			;;
		*)
			# Unknown or positional arg -- stop parsing
			break
			;;
		esac
	done
	if [[ $flag_used -eq 1 ]]; then
		warn "CLI flag detected; using" \
			" non-default options instead of" \
			" standard behavior."
	fi
}

# ---- Maintenance phases ----

update_system_image() {
	local phase_failed=0
	if ! require_cmd --check rpm-ostree; then
		warn "rpm-ostree not found, cannot update system image."
		return 1
	fi

	log "Updating system via rpm-ostree (non-interactive)..."
	if ! rpm-ostree update; then
		warn "rpm-ostree update failed."
		phase_failed=1
	fi
	if ! rpm-ostree upgrade; then
		warn "rpm-ostree upgrade failed."
		phase_failed=1
	fi
	if ! cleanup_inactive_rpm_ostree_requests; then
		warn "Inactive rpm-ostree request cleanup failed."
		phase_failed=1
	fi
	if ! rpm-ostree cleanup -bm; then
		warn "rpm-ostree cleanup failed."
		phase_failed=1
	fi

	((phase_failed == 0))
}

cleanup_inactive_rpm_ostree_requests() {
	local inactive_line
	inactive_line="$(
		rpm-ostree status --verbose 2>/dev/null |
			awk '/InactiveRequests:/ {
				sub(/.*InactiveRequests:[[:space:]]*/, "", $0)
				print
				exit
			}'
	)" || {
		warn "Could not query rpm-ostree status for inactive requests."
		return 1
	}

	if [[ -z ${inactive_line:-} || ${inactive_line} == "(none)" ]]; then
		log "No inactive rpm-ostree requests detected."
		return
	fi

	inactive_line="${inactive_line//,/ }"
	local -a inactive_requests
	read -ra inactive_requests <<<"$inactive_line"
	if ((${#inactive_requests[@]} == 0)); then
		log "No inactive rpm-ostree requests detected."
		return
	fi

	log "Removing inactive rpm-ostree requests: ${inactive_requests[*]}"
	if ! rpm-ostree uninstall "${inactive_requests[@]}"; then
		warn "Failed to remove one or more inactive rpm-ostree requests."
		return 1
	fi
	return 0
}

update_firmware() {
	local phase_failed=0
	local updates_available=1
	if ! require_cmd --check fwupdmgr; then
		warn "fwupdmgr not found, cannot update firmware."
		return 1
	fi

	log "Updating firmware via fwupdmgr (non-interactive)..."
	if ! fwupdmgr refresh --force; then
		warn "fwupdmgr refresh failed."
		phase_failed=1
	fi
	if ! fwupdmgr get-updates; then
		local rc=$?
		if [[ $rc -eq 2 ]]; then
			log "No firmware updates available."
			updates_available=0
		else
			warn "fwupdmgr get-updates failed" \
				" (rc=${rc}); continuing with" \
				" fwupdmgr update as" \
				" authoritative step."
		fi
	fi
	if ((updates_available == 1)); then
		if ! fwupdmgr update -y --no-reboot-check; then
			local rc=$?
			if [[ $rc -eq 2 ]]; then
				log "No firmware updates to apply."
			else
				warn "fwupdmgr update failed."
				phase_failed=1
			fi
		fi
	else
		log "Skipping firmware apply step because no updates are available."
	fi

	((phase_failed == 0))
}

update_homebrew() {
	local phase_failed=0
	log "Updating Homebrew applications..."

	if ! homebrew_available; then
		warn "Homebrew maintenance unavailable: ${HOMEBREW_ERROR}"
		return 1
	fi
	log "Using brew-proxy as non-root user '${NONROOT_USER}'."

	if ! run_phase_cmd "brew update" \
		run_homebrew update; then
		warn "brew update failed."
		phase_failed=1
	fi
	if ! run_phase_cmd "brew upgrade --yes --greedy" \
		run_homebrew upgrade --yes --greedy; then
		warn "brew upgrade failed."
		phase_failed=1
	fi
	if ! run_phase_cmd "brew cleanup" \
		run_homebrew cleanup; then
		warn "brew cleanup failed."
	fi
	if [[ $phase_failed -eq 0 ]]; then
		log "Homebrew maintenance completed."
	fi

	((phase_failed == 0))
}

update_flatpak() {
	local phase_failed=0
	if ! require_cmd --check flatpak; then
		warn "flatpak not found, cannot update Flatpak."
		return 1
	fi

	log "Updating and repairing Flatpak system installation..."
	if ! flatpak repair --system; then
		warn "flatpak system repair failed."
		phase_failed=1
	fi
	if ! flatpak update --system -y; then
		warn "flatpak system update failed."
		phase_failed=1
	fi
	if ! flatpak uninstall --system --unused -y; then
		warn "flatpak system cleanup failed."
		phase_failed=1
	fi

	# Per-user updates
	if ! require_cmd --check runuser; then
		warn "'runuser' not available; cannot" \
			" run per-user Flatpak" \
			" updates/repairs."
		return 1
	fi

	log "Updating and repairing Flatpak user" \
		" installation for configured user:" \
		" ${NONROOT_USER}"
	local home
	home="$(user_home_dir "$NONROOT_USER" || true)"
	if [[ -n ${home:-} && -d $home &&
		-d "$home/.local/share/flatpak" ]]; then
		if ! run_as_user_env "$NONROOT_USER" flatpak repair --user; then
			warn "flatpak user repair failed for $NONROOT_USER."
			phase_failed=1
		fi
		if ! run_as_user_env "$NONROOT_USER" flatpak update --user -y; then
			warn "flatpak user update failed for $NONROOT_USER."
			phase_failed=1
		fi
		if ! run_as_user_env "$NONROOT_USER" \
			flatpak uninstall --user --unused -y; then
			warn "flatpak user cleanup failed for $NONROOT_USER."
			phase_failed=1
		fi
	else
		warn "No per-user Flatpak installation" \
			" detected for '${NONROOT_USER}'" \
			" (missing" \
			" ${home:-<unknown>}/.local/share/flatpak)."
		phase_failed=1
	fi

	((phase_failed == 0))
}

maintain_filesystems() {
	local phase_failed=0
	if ! require_cmd --check lsblk; then
		warn "lsblk not found; cannot run filesystem maintenance."
		return 1
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
		log "No ext4 or btrfs block devices with" \
			" mountpoints detected; skipping" \
			" filesystem maintenance."
		return
	fi

	# ----------------- btrfs maintenance -----------------
	if ((${#btrfs_dev_mp[@]} > 0)); then
		if ! require_cmd --check btrfs; then
			warn "btrfs-progs not found; cannot run btrfs maintenance."
			phase_failed=1
		else
			local dev mp
			for dev in "${!btrfs_dev_mp[@]}"; do
				mp="${btrfs_dev_mp[$dev]}"
				log "Running non-destructive maintenance on" \
					" btrfs filesystem $dev" \
					" (mounted at $mp)..."

				# Scrub: verify data and repair using redundancy if possible
				if ! btrfs scrub start -Bd "$mp"; then
					warn "btrfs scrub failed for $mp."
					phase_failed=1
				fi

				# Full balance: reorganize all chunks
				# (can be heavy on large disks, but
				# non-destructive)
				if ! btrfs balance start --full-balance "$mp"; then
					warn "btrfs balance failed for $mp."
					phase_failed=1
				fi

				# Recursive defragmentation (can take a while, but non-destructive)
				if ! btrfs filesystem defragment -r "$mp"; then
					warn "btrfs filesystem defragment failed for $mp."
					phase_failed=1
				fi
			done
		fi
	fi

	# ----------------- ext4 maintenance ------------------
	if ((${#ext4_dev_mp[@]} > 0)); then
		if ! require_cmd --check e4defrag; then
			warn "e4defrag not found; cannot run ext4 defragmentation."
			phase_failed=1
		else
			local dev mp
			for dev in "${!ext4_dev_mp[@]}"; do
				mp="${ext4_dev_mp[$dev]}"
				log "Running non-destructive maintenance on" \
					" ext4 filesystem $dev" \
					" (mounted at $mp)..."

				# Check fragmentation level (non-destructive)
				if ! e4defrag -c "$mp"; then
					warn "e4defrag check failed for $mp."
					phase_failed=1
				fi

				# Online defragmentation (non-destructive, but can take some time)
				if ! e4defrag "$mp"; then
					warn "e4defrag defragmentation failed for $mp."
					phase_failed=1
				fi
			done
		fi
	fi

	((phase_failed == 0))
}

run_security_audit() {
	local audit_ts audit_log

	if command -v lynis >/dev/null 2>&1; then
		audit_ts="$(date +%Y%m%d-%H%M%S)"
		audit_log="/tmp/lynis-audit-${audit_ts}.log"
		log "Running Lynis security audit..."
		local lynis_rc=0
		lynis audit system --quiet \
			2>&1 | tee "$audit_log" || lynis_rc=$?
		if [[ $lynis_rc -eq 0 ]]; then
			log "Lynis security audit completed."
		else
			warn "Lynis security audit encountered" \
				"errors."
		fi
		log "Report saved to ${audit_log}"
	else
		warn "lynis not installed; skipping" \
			"security audit."
	fi
}

collect_system_info() {
	if ! require_cmd --check ujust fpaste; then
		warn "ujust or fpaste not found; cannot" \
			"collect Secureblue information."
		return 1
	fi

	local run_user
	if require_cmd --check runuser; then
		run_user="runuser -u ${NONROOT_USER} --"
		log "Running ujust/flatpak info as" \
			"configured user: ${NONROOT_USER}"
	else
		run_user=""
		warn "'runuser' not available; ujust/flatpak" \
			"will run as root; Homebrew info will be skipped."
	fi

	local info_log
	info_log="/tmp/secureblue-info-$(date +%Y%m%d-%H%M%S).log"

	log "Collecting Secureblue debug information..."

	print_section() {
		printf '\n---\n\n=== %s ===\n\n' "$1"
	}

	{
		print_section "System Info"
		fpaste --sysinfo --printonly 2>&1 || true

		print_section "Rpm-Ostree Status"
		if require_cmd --check rpm-ostree; then
			rpm-ostree status --verbose 2>&1 || true
		else
			printf 'rpm-ostree not available.\n'
		fi

		print_section "Flatpaks Installed"
		if require_cmd --check flatpak; then
			if [[ -n ${run_user:-} ]]; then
				$run_user flatpak list \
					--columns=app,version,options \
					2>&1 || true
			else
				flatpak list \
					--columns=app,version,options \
					2>&1 || true
			fi
		else
			printf 'flatpak not available.\n'
		fi

		print_section "Homebrew Packages Installed"
		if homebrew_available; then
			run_homebrew list --versions 2>&1 ||
				printf 'Homebrew package query failed.\n'
		else
			printf 'Homebrew unavailable: %s\n' "$HOMEBREW_ERROR"
		fi

		print_section "Audit Results"
		if [[ -n ${run_user:-} ]]; then
			$run_user ujust audit-secureblue \
				2>&1 || true
		else
			ujust audit-secureblue 2>&1 || true
		fi

		print_section "Listing Local Overrides"
		if [[ -n ${run_user:-} ]]; then
			$run_user ujust \
				check-local-overrides \
				2>&1 || true
		else
			ujust check-local-overrides \
				2>&1 || true
		fi

		print_section \
			"Previous Boot Events (warnings/errors)"
		journalctl -b -1 -p warning..alert \
			2>&1 || true

		print_section \
			"Recent System Events (warnings/errors, last hour)"
		journalctl -b -p warning..alert \
			--since "1 hour ago" 2>&1 || true

		print_section "Failed Systemd Services (system)"
		systemctl list-units --state=failed \
			2>&1 || true

		print_section \
			"Failed Systemd Services (user: ${NONROOT_USER})"
		if require_cmd --check runuser; then
			if ! run_as_user_env "$NONROOT_USER" \
				systemctl --user list-units \
				--state=failed 2>&1; then
				printf '%s\n' \
					"Could not query user systemd" \
					" for ${NONROOT_USER}" \
					" (no session)."
			fi
		else
			printf '%s\n' \
				"'runuser' not available;" \
				" skipping user systemd status."
		fi

		print_section "Homebrew Services Status"
		if ! homebrew_available; then
			printf 'Homebrew unavailable: %s\n' "$HOMEBREW_ERROR"
		elif ! run_homebrew services info --all 2>&1; then
			printf 'Homebrew services status query failed.\n'
		fi

		print_section "Disk Usage (df -h)"
		if require_cmd --check df; then
			df -h 2>&1 || true
		else
			printf 'df not available.\n'
		fi
	} 2>&1 | tee "$info_log"

	log "Secureblue information saved to ${info_log}"
}

run_optional_phases() {
	if [[ -z ${SKIP_AUDIT:-} ]]; then
		run_phase "security-audit" "optional" \
			"Security audit" run_security_audit
	else
		mark_phase_skipped "security-audit" \
			"optional" "Security audit" \
			"flag set"
	fi

	if [[ -z ${SKIP_COLLECT:-} ]]; then
		run_phase "collect-system-info" "optional" \
			"Collect Secureblue info" \
			collect_system_info
	else
		mark_phase_skipped "collect-system-info" \
			"optional" \
			"Collect Secureblue info" \
			"flag set"
	fi
}

bootstrap() {
	ensure_root "$@"
	parse_args "$@"
	require_cmd awk getent stat journalctl systemctl
	validate_nonroot_user
}

# ---- Main ----
main() {
	log "Starting update process..."
	PHASE_ORDER=()
	PHASE_STATUS=()
	PHASE_KIND=()
	PHASE_LABEL=()

	run_phase "system-image" "mandatory" \
		"System image update" update_system_image
	run_phase "firmware" "mandatory" "Firmware update" \
		update_firmware
	run_phase "homebrew" "mandatory" "Homebrew update" \
		update_homebrew
	run_phase "flatpak" "mandatory" "Flatpak update" \
		update_flatpak
	run_phase "filesystems" "mandatory" \
		"Filesystem maintenance" maintain_filesystems
	run_optional_phases

	if print_phase_summary; then
		log "Update process completed."
	else
		error "Update process completed with mandatory phase failures."
		return 1
	fi
}

# Entry point
bootstrap "$@"
main "$@"
