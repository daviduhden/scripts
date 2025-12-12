#!/bin/ksh
set -e

# Upgrade to snapshot (-current) and schedule post-upgrade actions
# to run on first boot via rc.firsttime(8).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Prefer ksh93 when available; fallback to base ksh
if [ -z "${_KSH93_EXECUTED:-}" ] && command -v ksh93 >/dev/null 2>&1; then
    _KSH93_EXECUTED=1 exec ksh93 "$0" "$@"
fi
_KSH93_EXECUTED=1

# Basic PATH (important when run from cron)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

cleanup_previous_artifacts() {
    if [ -f /upgrade.site ]; then
        rm -f /upgrade.site
    fi
    if ls /tmp/openbsd-info.* >/dev/null 2>&1; then
        rm -f /tmp/openbsd-info.*
    fi
}

write_upgrade_site() {
    cat << 'EOF' > /upgrade.site
#!/bin/ksh
# This script is executed at the end of the upgrade
# in the context of the new system (see upgrade.site(5)).

RCF=/etc/rc.firsttime

ensure_rc_firsttime() {
    if [ -f "$RCF" ]; then
        return
    fi

    umask 022
    {
        echo '#!/bin/ksh'
        echo 'echo "Running /etc/rc.firsttime post-upgrade tasks..."'
    } > "$RCF"
    chmod 700 "$RCF"
}

append_firstboot_tasks() {
    cat <<'EOF_APPEND' >> "$RCF"
run_sysmerge() {
    echo "Running sysmerge -b..."
    /usr/sbin/sysmerge -b
}

upgrade_packages() {
    echo "Upgrading packages (pkg_add -Uu -Dsnap) and removing unused ones (pkg_delete -a)..."
    /usr/sbin/pkg_add -Uu -Dsnap && /usr/sbin/pkg_delete -a
}

run_apply_sysclean() {
    echo "Running apply-sysclean..."
    if [ -x /usr/local/bin/apply-sysclean ]; then
        /usr/local/bin/apply-sysclean
    else
        echo "apply-sysclean not found; skipping."
    fi
}

run_lynis_audit() {
    echo "Running Lynis security audit (if available)..."
    if [ -x /usr/local/bin/lynis ]; then
        audit_dir="/var/log/openbsd"
        mkdir -p "$audit_dir"
        audit_ts=$(date +%Y%m%d-%H%M%S)
        audit_log="${audit_dir}/lynis-audit-${audit_ts}.log"
        audit_report="${audit_dir}/lynis-report-${audit_ts}.dat"
        if /usr/local/bin/lynis audit system --quiet --logfile "$audit_log" --report-file "$audit_report"; then
            chmod 0600 "$audit_log" "$audit_report" || true
            echo "Lynis security audit completed (log: $audit_log)."
        else
            echo "Lynis security audit encountered errors; see $audit_log."
        fi
        find "$audit_dir" -type f \( -name 'lynis-audit-*.log' -o -name 'lynis-report-*.dat' \) -mtime +7 -exec rm -f {} + 2>/dev/null || true
    else
        echo "lynis not found; skipping security audit."
    fi
}

collect_system_info_and_upload() {
    echo "Collecting system info and writing to /var/log/openbsd..."
    tmpf=$(mktemp /tmp/openbsd-info.XXXXXX 2>/dev/null || printf '/tmp/openbsd-info.%s' "$$")
    : >"$tmpf"
    out_dir="/var/log/openbsd"
    out_log="${out_dir}/sysupgrade-info-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$out_dir"
    rcctl_ls_on_output=""
    if command -v rcctl >/dev/null 2>&1; then
        rcctl_ls_on_output=$(rcctl ls on 2>/dev/null || true)
    fi
    print_section() {
        printf '\n---\n\n=== %s ===\n\n' "$1"
    }
    {
        print_section "System Info"
        uname -a
        printf '\n'
        sysctl -n kern.version 2>/dev/null || true
        print_section "Boot Log (dmesg.boot)"
        if [ -f /var/run/dmesg.boot ]; then cat /var/run/dmesg.boot; else dmesg; fi
        print_section "Installed Packages (pkg_info -mz)"
        pkg_info -mz 2>/dev/null || printf '%s\n' "pkg_info not available."
        print_section "Enabled Services (rcctl ls on)"
        if [ -n "$rcctl_ls_on_output" ]; then
            printf '%s\n' "$rcctl_ls_on_output"
        elif command -v rcctl >/dev/null 2>&1; then
            printf '%s\n' "No enabled services listed."
        else
            printf '%s\n' "rcctl not available."
        fi
        print_section "Failed Services (rcctl ls failed)"
        if command -v rcctl >/dev/null 2>&1; then
            rcctl ls failed 2>/dev/null || printf '%s\n' "No failed services or rcctl ls failed returned non-zero."
        else
            printf '%s\n' "rcctl not available."
        fi
        print_section "Recent System Events (last 200 lines)"
        if [ -f /var/log/messages ]; then tail -n 200 /var/log/messages; else printf '%s\n' "/var/log/messages not available."; fi
        print_section "Disk Usage (df -h)"
        if command -v df >/dev/null 2>&1; then df -h; else printf '%s\n' "df not available."; fi
        if [ -n "$rcctl_ls_on_output" ] && printf '%s\n' "$rcctl_ls_on_output" | grep -Eq '^xenodm$'; then
            print_section "Xenocara Log (last 200 lines)"
            if [ -f /var/log/Xorg.0.log ]; then
                tail -n 200 /var/log/Xorg.0.log
            else
                printf '%s\n' "/var/log/Xorg.0.log not available."
            fi
        fi
    } > "$tmpf"
    if mv "$tmpf" "$out_log"; then
        chmod 0600 "$out_log" || true
        printf '%s\n' "System info written to ${out_log}."
    else
        printf '%s\n' "Failed to write system info to ${out_log}."
        rm -f "$tmpf"
    fi

    find "$out_dir" -type f -name 'sysupgrade-info-*.log' -mtime +7 -exec rm -f {} + 2>/dev/null || true
}

main() {
    run_sysmerge
    upgrade_packages
    run_apply_sysclean
    run_lynis_audit
    collect_system_info_and_upload
}

main "$@"
EOF_APPEND
}

main() {
    ensure_rc_firsttime
    append_firstboot_tasks
}

main "$@"
EOF
}

run_sysupgrade() {
    log "Running sysupgrade -sf..."
    /usr/sbin/sysupgrade -sf
}

main() {
    log "Preparing /upgrade.site for post-upgrade tasks..."
    cleanup_previous_artifacts
    write_upgrade_site
    chmod +x /upgrade.site
    run_sysupgrade
    log "sysupgrade completed; system info collection will run on first boot via /etc/rc.firsttime."
}

main "$@"
