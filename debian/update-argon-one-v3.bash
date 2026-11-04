#!/bin/bash

set -euo pipefail

# Argon One V3 maintenance script
#  - Updates EEPROM (argon-eeprom.sh)
#  - Updates power button & fan control script (argon1.sh)
#  - Can run interactively or from cron (non-interactive)
#
# Requirements: root privileges, network access, curl, bash, mktemp,
# and reboot. The script verifies connectivity to download.argon40.com
# with a HEAD request before downloading.
#
# Side effects:
#  - Prepares and verifies both installers before running either of them
#    with bash as root
#  - May reboot the system, depending on the option or interactive
#    answer
#
# Script execution requires operator-pinned SHA-256 digests or explicit
# --trust-upstream. ARGON_EEPROM_SCRIPT/ARGON_CONTROL_SCRIPT select local files;
# supplied digests also apply to local files. Scripts execute as root. Temporary files are
# removed on exit. Use --no-reboot for cron, or --auto-reboot to reboot
# without prompting.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

EEPROM_URL="https://download.argon40.com/argon-eeprom.sh"
CONTROL_URL="https://download.argon40.com/argon1.sh"
TMP_FILES=()
TRUST_UPSTREAM=0
EEPROM_SHA256=${ARGON_EEPROM_SHA256:-}
CONTROL_SHA256=${ARGON_CONTROL_SHA256:-}

# Reboot mode:
#   "question" -> ask (default in interactive mode)
#   "yes"    -> automatically reboot
#   "no"     -> never reboot automatically
AUTO_REBOOT="question"

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -r, --auto-reboot   Automatically reboot at the end without asking.
  -N, --no-reboot     Do not reboot at the end
                       (default in non-interactive).
      --eeprom-sha256 HASH  Require this reviewed EEPROM script digest.
      --control-sha256 HASH Require this reviewed control script digest.
      --trust-upstream      Explicitly trust unpinned upstream scripts.
  -h, --help          Show this help and exit.

Examples:
  # Normal interactive usage
  sudo $0 --eeprom-sha256 REVIEWED_HASH --control-sha256 REVIEWED_HASH

  # For cron (no automatic reboot)
  sudo $0 --trust-upstream --no-reboot

  # For cron with automatic reboot when finished
  sudo $0 --trust-upstream --auto-reboot
EOF
}

parse_args() {
	local flag_used=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--eeprom-sha256 | --control-sha256)
			[[ $# -ge 2 && $2 =~ ^[[:xdigit:]]{64}$ ]] || {
				error 'Expected a SHA-256 digest'
				exit 1
			}
			if [[ $1 == --eeprom-sha256 ]]; then EEPROM_SHA256=${2,,}; else CONTROL_SHA256=${2,,}; fi
			shift 2
			;;
		--trust-upstream)
			TRUST_UPSTREAM=1
			shift
			;;
		-r | --auto-reboot)
			flag_used=1
			AUTO_REBOOT="yes"
			shift
			;;
		-N | --no-reboot)
			flag_used=1
			AUTO_REBOOT="no"
			shift
			;;
		-h | --help)
			flag_used=1
			warn "CLI flag detected;" \
				"using non-default options" \
				"instead of standard behavior."
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
	if [[ $flag_used -eq 1 ]]; then
		warn "CLI flag detected;" \
			"using non-default options" \
			"instead of standard behavior."
	fi
}

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

trap 'error "Execution interrupted."; exit 1' INT

# Remove every temporary script recorded in TMP_FILES. Missing entries
# are ignored; the EXIT trap guarantees this runs on normal exit and
# after an error-triggered exit.
cleanup_tmp_files() {
	local file
	for file in "${TMP_FILES[@]}"; do
		[[ -n $file && -f $file ]] && rm -f -- "$file"
	done
}

trap cleanup_tmp_files EXIT

# ---- Helpers -------------------------------------------------------

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

net_curl() {
	curl -fLsS --retry 5 "$@"
}

# Fail early if the download host is unreachable. This is a HEAD
# request, so no script content is fetched here.
check_network() {
	log "Checking network connectivity to download.argon40.com..."
	if ! net_curl --head "$EEPROM_URL" >/dev/null 2>&1; then
		error "Cannot reach download.argon40.com." \
			"Check your Internet connection."
		exit 1
	fi
	log "Network looks OK."
}

download_remote_script() {
	local url="$1"
	local tmp_script="$2" digest="$3" local_script="$4"
	if [[ -n $local_script ]]; then
		[[ -f $local_script && ! -L $local_script ]] || {
			error 'Expected a regular local script'
			return 1
		}
		cp -- "$local_script" "$tmp_script" || return 1
	else
		log "Downloading script from $url to temporary file..."
		net_curl --proto '=https' --proto-redir '=https' -o "$tmp_script" "$url" || return 1
	fi
	if [[ -n $digest ]]; then
		[[ $digest =~ ^[[:xdigit:]]{64}$ ]] || {
			error 'Invalid SHA-256'
			return 1
		}
		printf '%s  %s\n' "${digest,,}" "$tmp_script" | sha256sum -c - || return 1
	elif [[ $TRUST_UPSTREAM != 1 ]]; then
		error 'Supply reviewed SHA-256 digests, or explicitly opt in with --trust-upstream.'
		return 1
	else
		warn 'Executing upstream script without an independent pinned digest.'
	fi
	bash -n "$tmp_script"
}

# Execute only after both installers have passed preparation and validation.
run_eeprom_update() {
	log "Running verified EEPROM update script from Argon40..."
	bash "$1" || return 1
	log "EEPROM update script finished."
}

run_control_update() {
	log "Running verified Argon One V3 control script installer..."
	bash "$1" || return 1
	log "Argon One V3 control script finished."
}

# Decide whether to reboot: explicit flags win, a non-interactive
# session never prompts, and an interactive session asks (default no).
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

	# Non-interactive (cron): never question
	if [[ ! -t 0 ]]; then
		log "Non-interactive session detected;" \
			"skipping reboot. Please reboot manually."
		return 0
	fi

	# Interactive: ask the user
	read -r -p "Reboot now to apply all changes? [y/N] " answer
	case "$answer" in
	[yY][eE][sS] | [yY])
		log "Rebooting..."
		reboot
		;;
	*)
		log "Reboot skipped. Remember to reboot" \
			"later to apply EEPROM and control changes."
		;;
	esac
}

check_prereqs() {
	require_root
	require_cmd sha256sum
	require_cmd bash
	require_cmd mktemp
	require_cmd reboot
	if [[ -z ${ARGON_EEPROM_SCRIPT:-} || -z ${ARGON_CONTROL_SCRIPT:-} ]]; then
		require_cmd curl
		check_network
	fi
}

run_update() {
	local eeprom control
	eeprom=$(mktemp "${TMPDIR:-/tmp}/argon-eeprom.XXXXXX.bash")
	TMP_FILES+=("$eeprom")
	control=$(mktemp "${TMPDIR:-/tmp}/argon-control.XXXXXX.bash")
	TMP_FILES+=("$control")
	# A bad second download/digest must not allow the first installer to run.
	download_remote_script "$EEPROM_URL" "$eeprom" "$EEPROM_SHA256" "${ARGON_EEPROM_SCRIPT:-}" || return 1
	download_remote_script "$CONTROL_URL" "$control" "$CONTROL_SHA256" "${ARGON_CONTROL_SCRIPT:-}" || return 1
	run_eeprom_update "$eeprom" || return 1
	run_control_update "$control" || return 1
	log "All Argon One V3 update steps completed."
	ask_reboot
}

# ---- Main ----------------------------------------------------------

main() {
	parse_args "$@"
	[[ $TRUST_UPSTREAM == 1 || (-n $EEPROM_SHA256 && -n $CONTROL_SHA256) ]] || {
		error 'Require both reviewed SHA-256 digests or explicit --trust-upstream.'
		exit 1
	}
	log "Argon One V3 maintenance: EEPROM + control script update"
	check_prereqs
	run_update
}

main "$@"
