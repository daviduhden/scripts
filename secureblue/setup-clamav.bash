#!/bin/bash
set -euo pipefail

# SecureBlue ClamAV setup script
# Configures ClamAV with self-healing updates, on-access scanning,
# and periodic system scans.
#
# This script is intended to be run via run0 to ensure proper permissions.
#
# Usage:
#   run0 ./setup-clamav.bash [--dry-run] [--apply-live]
# See --help for details.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

#!/usr/bin/env bash
set -euo pipefail

###################
# Logging helpers #
################### 
if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; RESET=""
fi
log()   { printf '%s %b[INFO]%b  %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s %b[WARN]%b  %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2; exit 1; }

###########
# Globals #
###########
APPLY_LIVE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --apply-live) APPLY_LIVE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            cat <<EOF
Usage:
  run0 ./setup-clamav-final.sh [--dry-run] [--apply-live]
EOF
            exit 0
            ;;
    esac
done

doit() { ((DRY_RUN)) && log "[DRY-RUN] $*" || "$@"; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || error "Root required"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

###########
# Helpers #
###########
backup_once() { local f="$1"; [[ -f "$f" ]] || return 0; local b="${f}.bak"; [[ -e $b ]] && return 0; cp -a "$f" "$b"; }
ensure_kv_line() { local file="$1" key="$2" value="$3"; if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}\b" "$file"; then sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}\b.*|${key} ${value}|g" "$file"; else printf "\n%s %s\n" "$key" "$value" >>"$file"; fi; }
ensure_multi_line() { local file="$1" key="$2" value="$3"; grep -Fxq "${key} ${value}" "$file" || printf "%s %s\n" "$key" "$value" >>"$file"; }
comment_out_example() { local file="$1"; sed -ri 's|^[[:space:]]*Example[[:space:]]*$|# Example|g' "$file" || true; }
write_file_if_missing() { local path="$1" content="$2"; [[ -f "$path" ]] || { install -d -m 0755 "$(dirname "$path")"; printf "%s\n" "$content" >"$path"; }; }

###########################
# Atomic package layering #
###########################
install_atomic_packages() {
    if ! have_cmd rpm-ostree; then
        warn "Not on Fedora Atomic, skipping package layering"
        return
    fi
    local missing=()
    for p in clamav clamd clamav-freshclam; do
        rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if ((${#missing[@]})); then
        log "Layering missing packages: ${missing[*]}"
        local cmd=(rpm-ostree install --assumeyes "${missing[@]}")
        ((APPLY_LIVE)) && cmd+=(--apply-live)
        doit "${cmd[@]}"
        if (( ! APPLY_LIVE )); then
            log "Packages layered but not live-applied. Scheduling post-install."
            schedule_postinstall
            exit 0
        fi
    fi
}

#########################
# Permissions & SELinux #
#########################
fix_permissions() {
    install -d -m 0755 /var/lib/clamav /var/lib/clamav/tmp /var/log/clamav /var/spool/quarantine /run/clamd.scan
    chown -R clamscan:clamscan /var/lib/clamav /var/log/clamav /var/spool/quarantine /run/clamd.scan
    chmod 0755 /var/lib/clamav /var/log/clamav /run/clamd.scan
    chmod 0700 /var/spool/quarantine
}

fix_selinux() {
    grep -q '/run/clamd\.scan(/.*)?' /etc/selinux/targeted/contexts/files/file_contexts.local || \
        echo '/run/clamd\.scan(/.*)?    system_u:object_r:clamd_var_run_t:s0' >> /etc/selinux/targeted/contexts/files/file_contexts.local
    restorecon -Rv /run/clamd.scan /var/lib/clamav /var/log/clamav /var/spool/quarantine >/dev/null 2>&1 || true
}

##########################
# Freshclam self-healing #
##########################
run_freshclam() {
    fix_permissions
    fix_selinux
    local tries=0
    until ((tries>=3)); do
        ((tries++))
        log "Running freshclam (attempt $tries)"
        if freshclam; then
            log "freshclam succeeded"
            return 0
        else
            warn "freshclam failed, retrying in 5s..."
            sleep 5
        fi
    done
    error "freshclam failed after 3 attempts"
}

configure_freshclam() {
    install -d -m 0755 /var/log/clamav
    touch /var/log/freshclam.log
    chown clamscan:clamscan /var/log/freshclam.log /var/log/clamav
    chmod 0644 /var/log/freshclam.log
    chmod 0755 /var/log/clamav

    local f="/etc/freshclam.conf"
    backup_once "$f"
    write_file_if_missing "$f" "# freshclam.conf - generated"
    comment_out_example "$f"
    ensure_kv_line "$f" "DatabaseDirectory" "/var/lib/clamav"
    ensure_kv_line "$f" "UpdateLogFile" "/var/log/freshclam.log"
    ensure_kv_line "$f" "LogTime" "yes"
    ensure_kv_line "$f" "LogVerbose" "no"
    ensure_kv_line "$f" "DatabaseOwner" "clamscan"
    ensure_kv_line "$f" "NotifyClamd" "/etc/clamd.d/scan.conf"

    run_freshclam
}

######################
# Clamd self-healing #
######################
start_clamd() {
    fix_permissions
    fix_selinux
    local tries=0
    until ((tries>=3)); do
        ((tries++))
        log "Starting clamd@scan.service (attempt $tries)"
        systemctl restart clamd@scan.service && systemctl is-active --quiet clamd@scan.service && { log "clamd active"; return 0; } || warn "clamd failed to start, retrying..."
        sleep 5
    done
    error "clamd failed to start after 3 attempts"
}

configure_clamd() {
    install -d -m 0755 /etc/clamd.d /run/clamd.scan
    chown clamscan:clamscan /run/clamd.scan
    chmod 0755 /run/clamd.scan

    local conf="/etc/clamd.d/scan.conf"
    [[ ! -f $conf ]] && echo "# scan.conf - generated" >"$conf"
    backup_once "$conf"
    comment_out_example "$conf"

    ensure_kv_line "$conf" "LogSyslog" "yes"
    ensure_kv_line "$conf" "DatabaseDirectory" "/var/lib/clamav"
    ensure_kv_line "$conf" "LocalSocket" "/run/clamd.scan/clamd.sock"
    ensure_kv_line "$conf" "FixStaleSocket" "yes"
    ensure_kv_line "$conf" "User" "clamscan"

    for p in /var/home /tmp /run/media /mnt /var/mnt; do
        ensure_multi_line "$conf" "OnAccessIncludePath" "$p"
    done

    ensure_kv_line "$conf" "OnAccessExcludeUname" "clamscan"
    ensure_kv_line "$conf" "OnAccessExcludeRootUID" "yes"
    ensure_kv_line "$conf" "OnAccessPrevention" "yes"

    start_clamd
}

#######################
# On-access clamonacc #
#######################
configure_clamonacc() {
    local unit=""
    systemctl list-unit-files | grep -q '^clamav-clamonacc.service' && unit=clamav-clamonacc.service
    systemctl list-unit-files | grep -q '^clamonacc.service' && unit=clamonacc.service
    [[ -z $unit ]] && { log "No clamonacc service, skipping"; return; }
    local dropin="/etc/systemd/system/${unit}.d"; install -d -m 0755 "$dropin"
    cat >"$dropin/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/clamonacc --foreground --fdpass --log=/var/log/clamonacc.log --move=/var/spool/quarantine
Restart=on-failure
RestartSec=5
EOF
}

#########################
# Periodic scan + timer #
#########################
configure_periodic_scan() {
    install -d -m 0755 /usr/local/sbin /var/log/clamav /var/spool/quarantine
    chown -R clamscan:clamscan /var/log/clamav /var/spool/quarantine
    chmod 0755 /var/log/clamav
    chmod 0700 /var/spool/quarantine

    cat >/usr/local/sbin/clamav-scan-targets.bash <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/clamav"
QUAR="/var/spool/quarantine"
mkdir -p "$LOG_DIR" "$QUAR"
ts="$(date --iso-8601=seconds | tr ':' '-')"
log="${LOG_DIR}/clamdscan-${ts}.log"
targets=( "/var/home" "/tmp" )
fstypes=(ext4 xfs btrfs f2fs vfat exfat ntfs ntfs3 hfsplus apfs udf iso9660)
command -v findmnt >/dev/null 2>&1 && while IFS= read -r line; do t="${line%% *}"; case "$t" in ""|"/"|/proc*|/sys*|/run*|/dev*|/boot*|/var/lib/containers* ) continue ;; esac; targets+=( "$t" ); done < <(findmnt -rn -o TARGET,FSTYPE -t "$(IFS=,; echo "${fstypes[*]}")" 2>/dev/null || true)
mapfile -t uniq_targets < <(printf "%s\n" "${targets[@]}" | awk 'NF' | sort -u)
exec /usr/bin/clamdscan --multiscan --fdpass --infected --log="$log" --move="$QUAR" "${uniq_targets[@]}"
EOF
    chmod 0755 /usr/local/sbin/clamav-scan-targets.bash

    cat >/etc/systemd/system/clamav-target-scan.service <<'EOF'
[Unit]
Description=ClamAV periodic scan
Wants=clamd@scan.service
After=clamd@scan.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clamav-scan-targets.bash
EOF

    cat >/etc/systemd/system/clamav-target-scan.timer <<'EOF'
[Unit]
Description=ClamAV periodic scan scheduler
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
}

##########################
# Postinstall for Atomic #
##########################
schedule_postinstall() {
    install -d -m 0755 /var/lib/clamav-atomic
    cat >/var/lib/clamav-atomic/postinstall.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/bash /usr/local/sbin/setup-clamav-final.sh --apply-live
EOF
    chmod 0755 /var/lib/clamav-atomic/postinstall.sh

    cat >/etc/systemd/system/clamav-atomic-postinstall.service <<'EOF'
[Unit]
Description=ClamAV Atomic post-install
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/var/lib/clamav-atomic/postinstall.sh
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable clamav-atomic-postinstall.service || true
    log "Post-install scheduled for next reboot"
}

###################
# Enable services #
###################
enable_services() {
    systemctl daemon-reload
    systemctl enable --now clamav-freshclam.service || true
    systemctl enable --now clamd@scan.service || true
    local unit=""
    systemctl list-unit-files | grep -q '^clamav-clamonacc.service' && unit=clamav-clamonacc.service
    systemctl list-unit-files | grep -q '^clamonacc.service' && unit=clamonacc.service
    [[ -n $unit ]] && systemctl enable --now "$unit" || true
    systemctl enable --now clamav-target-scan.timer || true
}

###########
# Main #
###########
main() {
    require_root
    log "Starting ClamAV self-healing + periodic + on-access setup"
    install_atomic_packages
    configure_freshclam
    configure_clamd
    configure_clamonacc
    configure_periodic_scan
    fix_selinux
    enable_services
    log "ClamAV setup complete ✅"
    log "Logs: /var/log/freshclam.log, /var/log/clamav/*.log"
    log "Quarantine: /var/spool/quarantine"
}

main
