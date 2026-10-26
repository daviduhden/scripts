#!/bin/bash
set -uo pipefail

# SecureBlue post-install interactive runner for ujust commands.
#
# Walks the operator through a curated set of post-install tasks, asking before
# each one. Steps that do not need a reboot run first; reboot-likely steps are
# queued and offered at the end, followed by an optional reboot. Some tasks
# (ujust bios, LUKS setup, dns-selector, create-admin) are interactive or
# reboot immediately on their own.
#
# The runner does not elevate ordinary ujust tasks; those prompt through their
# own mechanisms. It uses run0 only for the final reboot when not already root.
# It intentionally omits `set -e` (set -uo pipefail only): a failed step is
# recorded and summarized, and only failures marked critical produce a nonzero
# exit status.
#
# Each command runs in a login shell so ujust is found with its normal
# environment, and combined stdout/stderr is appended to a timestamped log in
# the user's home directory.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

LOG_FILE="${HOME}/postinstall_$(date +%F_%H%M%S).log"

# Queue entries are encoded as "command||description||critical", where
# critical=1 means a failure makes the script exit nonzero. FAILURES collects
# every failed command; CRITICAL_FAILURES holds only the critical subset.
declare -a QUEUE_NOW=()
declare -a QUEUE_LATE=() # reboot-likely
declare -a FAILURES=()
declare -a CRITICAL_FAILURES=()

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }
require_cmd() {
	have "$1" || {
		say "[ERROR] Required command '$1' not found"
		exit 1
	}
}
say() { printf "%b\n" "$*"; }
hr() { printf "%s\n" \
	"------------------------------------------------------------"; }
info() { say "[OK]  $*"; }
ok() { say "[OK]  $*"; }
warn2() { say "[WARN]  $*"; }
fail() { say "[ERROR]  $*"; }

# Prompt until the answer is recognizable. If stdin is unavailable (for
# example when run non-interactively), use the caller-provided default
# instead of looping forever.
confirm() {
	local question="${1:-Continue?}"
	local def="${2:-y}" # y/n
	local ans=""
	while true; do
		ans=""
		if [[ $def == "y" ]]; then
			if ! read -r -p "$question [Y/n] " ans; then
				warn2 "Input unavailable; defaulting to yes for: $question"
				ans="Y"
			fi
			ans="${ans:-Y}"
		else
			if ! read -r -p "$question [y/N] " ans; then
				warn2 "Input unavailable; defaulting to no for: $question"
				ans="N"
			fi
			ans="${ans:-N}"
		fi
		case "$ans" in
		[Yy] | [Yy][Ee][Ss]) return 0 ;;
		[Nn] | [Nn][Oo]) return 1 ;;
		*) say "Please answer y/n." ;;
		esac
	done
}

run_cmd() {
	local desc="$1"
	shift
	local cmd=("$@")

	hr
	say "[STEP] $desc"
	# Join the already-split array only for display; execution still uses the
	# array so arguments with spaces stay intact.
	local _cmdstr
	_cmdstr=$(printf '%s ' "${cmd[@]}")
	say "-> Running: ${_cmdstr% }"
	# tee mirrors output to the terminal and the log. PIPESTATUS[0] captures
	# the ujust exit status rather than tee's, which is normally zero.
	{
		"${cmd[@]}"
	} 2>&1 | tee -a "$LOG_FILE"
	local rc=${PIPESTATUS[0]}
	if [[ $rc -ne 0 ]]; then
		say "[WARN] Failed with exit code $rc: ${_cmdstr% }"
		FAILURES+=("${_cmdstr% } (rc=$rc)")
		return "$rc"
	fi
	say "[OK] OK"
	return 0
}

enqueue_now() { QUEUE_NOW+=("$1"); }
enqueue_late() { QUEUE_LATE+=("$1"); }

reboot_system() {
	hr
	say "[REBOOT]  Rebooting..."
	if [[ ${EUID:-9999} -eq 0 ]]; then
		systemctl reboot
	elif have run0; then
		run0 systemctl reboot
	else
		say "No run0 found. Please reboot manually when convenient."
		return 1
	fi
}

# We store commands as strings so we can queue them easily.
run_ujust_string() {
	local ucmd="$1" # e.g. "ujust setup-usbguard"
	local desc="$2"
	run_cmd "$desc" bash -lc -- "$ucmd"
}

# Split a queued "command||description||critical" item and run it. The
# critical flag only affects reporting; execution continues either way.
run_selected_step() {
	local item="$1"
	local ucmd desc critical rest rc

	ucmd="${item%%||*}"
	rest="${item#*||}"
	desc="${rest%%||*}"
	critical="${item##*||}"
	rc=0

	run_ujust_string "$ucmd" "$desc" || rc=$?
	if [[ $critical == "1" && $rc -ne 0 ]]; then
		CRITICAL_FAILURES+=("${desc}: ${ucmd} (rc=$rc)")
	fi
}

run_postinstall_flow() {
	# ---------- preflight ----------
	hr
	say "[TOOL] secureblue post-install (ujust) -- interactive script"
	say "Log: $LOG_FILE"
	hr

	say "[INFO] Notes:"
	say "- This script only automates the article's 'ujust' commands."
	say "- 'ujust bios' reboots immediately into UEFI/BIOS and the ""\
script ends there."
	say "- Some steps (dns-selector, create-admin, LUKS unlock) are ""\
interactive on their own."
	hr

	# ---------- interactive walk-through ----------
	# Essential -- Enroll Secure Boot key (queue late)
	if confirm \
		"Run: ujust enroll-secureblue-secure-boot-key? ""\
(often needs a reboot; queued for the end)" \
		"y"; then
		enqueue_late "ujust enroll-secureblue-secure-boot-key""\
||Enroll Secure Boot key||1"
	fi

	# Essential -- Validation (can run now)
	if confirm \
		"Run validation now: ujust audit-secureblue? ""\
(recommended; results may change after reboot)" \
		"y"; then
		enqueue_now "ujust audit-secureblue||Validation ""\
(audit-secureblue)||1"
	fi

	# Recommended -- Disable booting from USB (BIOS)
	if confirm \
		"Open UEFI/BIOS now: ujust bios ? ""\
(REBOOTS IMMEDIATELY and ends the script)" \
		"n"; then
		say "[WARN]  This will reboot now into the firmware setup."
		if confirm "Are you sure you want to do this now?" "n"; then
			run_ujust_string "ujust bios" \
				"Enter UEFI/BIOS (ujust bios)"
			# If reboot doesn't happen for some reason,
			# still exit to avoid weird state.
			exit 0
		fi
	fi

	# Recommended -- USBGuard
	if confirm \
		"Run: ujust setup-usbguard? ""\
(generates policy from currently attached USB devices, ""\
blocks others)" \
		"y"; then
		enqueue_now "ujust setup-usbguard||Setup USBGuard||0"
	fi

	# Recommended -- Create admin wheel account
	if confirm \
		"Run: ujust create-admin? ""\
(creates a dedicated admin account; interactive)" \
		"y"; then
		enqueue_now "ujust create-admin||Create separate wheel/""\
admin account||0"
	fi

	# Recommended -- DNS selector (with VPN warning)
	if confirm \
		"Run: ujust dns-selector? (configures DNS; interactive)" \
		"y"; then
		hr
		say "[WARN] VPN note:"
		say "If you plan to use a VPN, you may want to keep the ""\
system default DNS or use systemd-resolved (depending on ""\
your setup) to avoid DNS leaks."
		say "Avoid forcing Trivalent DNS-over-HTTPS when using a VPN."
		if confirm "Continue with dns-selector anyway?" "y"; then
			enqueue_now "ujust dns-selector||Configure system ""\
DNS (dns-selector)||0"
		else
			say "Skipping dns-selector."
		fi
	fi

	# Recommended -- MAC randomization
	if confirm \
		"Run: ujust toggle-mac-randomization ? ""\
(toggles random/permanent MAC in NetworkManager)" \
		"y"; then
		enqueue_now "ujust toggle-mac-randomization||Toggle MAC ""\
address randomization||0"
	fi

	# Recommended -- Bash environment lockdown
	if confirm \
		"Run: ujust toggle-bash-environment-lockdown? ""\
(mitigates LD_PRELOAD-style attacks)" \
		"y"; then
		enqueue_now "ujust toggle-bash-environment-lockdown||""\
Bash environment lockdown||0"
	fi

	# Recommended -- LUKS Hardware Unlock (queue late)
	hr
	say "[LUKS] LUKS Hardware Unlock"
	say "Options: FIDO2 (preferred if you have a security key)" \
		"or TPM2 (with AMD/fTPM caveats)."
	say "Guidance: pick ONLY ONE (do not enable both)."
	hr

	if confirm \
		"Configure LUKS FIDO2 unlock? ""\
(ujust setup-luks-fido2-unlock; often needs reboot; ""\
queued for the end)" \
		"n"; then
		enqueue_late "ujust setup-luks-fido2-unlock||LUKS ""\
FIDO2 unlock||0"
	else
		if confirm \
			"Configure LUKS TPM2 unlock? ""\
(ujust setup-luks-tpm-unlock; often needs reboot; ""\
queued for the end)" \
			"n"; then
			hr
			say "[WARN] AMD/fTPM note:"
			say "If your AMD system uses fTPM (firmware TPM)" \
				"instead of a dedicated TPM/Pluton,"
			say "the guide recommends skipping TPM2 ""\
enrollment."
			if confirm "Continue with TPM2 anyway?" "n"; then
				enqueue_late "ujust setup-luks-tpm-unlock""\
||LUKS TPM2 unlock||0"
			else
				say "Skipping TPM2 unlock."
			fi
		fi
	fi

	# ---------- execution ----------
	hr
	say "[PLAN] Execution plan"
	if ((${#QUEUE_NOW[@]})); then
		say "[NOW] No-reboot steps (run now):"
		for item in "${QUEUE_NOW[@]}"; do
			say "  - ${item%%||*}"
		done
	else
		say "[NOW] No-reboot steps (run now): none"
	fi

	if ((${#QUEUE_LATE[@]})); then
		say "[REBOOT] Likely-reboot steps (queued for the end):"
		for item in "${QUEUE_LATE[@]}"; do
			say "  - ${item%%||*}"
		done
	else
		say "[REBOOT] Likely-reboot steps (queued for the end): none"
	fi
	hr

	if ! confirm "Start running the selected steps now?" "y"; then
		say "[EXIT] Exiting without running anything."
		exit 0
	fi

	# Run non-reboot steps first; a failure here is recorded but does not
	# prevent later steps from running.
	for item in "${QUEUE_NOW[@]}"; do
		run_selected_step "$item"
	done

	# Run LATE queue (reboot-likely)
	if ((${#QUEUE_LATE[@]})); then
		hr
		say "[RUN] Running the likely-reboot steps saved for the ""\
end..."

		for item in "${QUEUE_LATE[@]}"; do
			run_selected_step "$item"
		done

		hr
		say "[OK] Completed the final steps."
		if confirm \
			"Reboot now to apply everything that requires it?" \
			"y"; then
			reboot_system
		else
			say "[INFO] Remember to reboot later to apply all""\
 changes."
		fi
	else
		say "No reboot-requiring steps were scheduled."
	fi

	# Summary
	hr
	say "[SUMMARY] Summary"
	say "Log: $LOG_FILE"
	if ((${#FAILURES[@]})); then
		say "[WARN]  Failures found:"
		for f in "${FAILURES[@]}"; do
			say "  - $f"
		done
	else
		say "[OK] No command failures were detected."
	fi
	if ((${#CRITICAL_FAILURES[@]})); then
		say "[ERROR] Critical selected steps failed:"
		for f in "${CRITICAL_FAILURES[@]}"; do
			say "  - $f"
		done
		exit 1
	fi
	say "[OK] Completed with no critical step failures."
}

main() {
	require_cmd bash
	require_cmd tee
	require_cmd systemctl
	require_cmd ujust
	run_postinstall_flow
}

main "$@"
