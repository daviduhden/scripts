#!/bin/ksh

set -eu

# OpenBSD sysupgrade-current script
# Upgrade to snapshot (-current) and schedule post-upgrade actions
# to run on first boot via rc.firsttime(8).
#
# Notes:
# - Uses ksh93 if available, otherwise falls back to base ksh.
# - Post-upgrade tasks (sysmerge/pkg_add/lynis/info dump)
#   are wired through /upgrade.site -> /etc/rc.firsttime.
# - Lynis is executed via ksh/ksh93 to match shell expectations.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

log() { print "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; }

cleanup_previous_artifacts() {
	if [ -f /upgrade.site ]; then
		rm -f /upgrade.site
	fi
	if ls /tmp/openbsd-info.* >/dev/null 2>&1; then
		rm -f /tmp/openbsd-info.*
	fi
}

write_upgrade_site() {
	cat <<'EOF' >/upgrade.site
#!/bin/ksh

set -eu

# This script is executed at the end of the upgrade
# in the context of the new system (see upgrade.site(5)).

# Copyright (c) 2025-2026 David Uhden Collado
#
# Permission to use, copy, modify, and distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice
# appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS
# ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO
# EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER
# RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
# OF THIS SOFTWARE.

RCF=/etc/rc.firsttime

ensure_rc_firsttime() {
    if [ -f "$RCF" ]; then
        return
    fi

    umask 022
    {
        print '#!/bin/ksh'
        cat <<'EOF_RCF'
case "${KSH_VERSION-}" in
    *93*) : ;;  # already ksh93
    *)
        if command -v ksh93 >/dev/null 2>&1; then
            exec ksh93 "$0" "$@"
        elif [ -x /usr/local/bin/ksh93 ]; then
            exec /usr/local/bin/ksh93 "$0" "$@"
        elif command -v ksh >/dev/null 2>&1; then
            exec ksh "$0" "$@"
        elif [ -x /bin/ksh ]; then
            exec /bin/ksh "$0" "$@"
        fi
    ;;
esac

set -eu

# This script is executed at the end of the upgrade
# in the context of the new system (see upgrade.site(5)).

# Copyright (c) 2025-2026 David Uhden Collado
#
# Permission to use, copy, modify, and distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice
# appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS
# ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO
# EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER
# RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
# OF THIS SOFTWARE.

print "Running /etc/rc.firsttime post-upgrade tasks..."
EOF_RCF
    } > "$RCF"
    chmod 700 "$RCF"
}

append_firstboot_tasks() {
    cat <<'EOF_APPEND' >> "$RCF"
run_logged_cmd() {
    log_file="$1"
    shift
    if "$@" 2>&1 | tee "$log_file"; then
        return 0
    fi
    return 1
}

run_sysmerge() {
    print ""
    print "---"
    print "Running sysmerge -b (batch mode)..."
    print "This auto-applies changes to unmodified files,"
    print "installs missing files/binaries, recreates system"
    print "users/groups, and fixes permissions via mtree."
    print "Locally modified configs are NOT overwritten;"
    print "files with unresolved diffs are left for review."
    print "Backups are saved under /var/sysmerge/backups."
    print "---"
    print ""
    /usr/sbin/sysmerge -b
}

upgrade_packages() {
    log_file="/var/log/openbsd/pkg-upgrade-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p /var/log/openbsd
    print "Upgrading packages (pkg_add -Uu -Dsnap)"
    print "and removing unused ones (pkg_delete -a)..."
    if run_logged_cmd "$log_file" /usr/sbin/pkg_add -Uu -Dsnap \
        && run_logged_cmd "$log_file" /usr/sbin/pkg_delete -a; then
        print "Package upgrade completed (log: $log_file)."
    else
        print "Package upgrade encountered errors; see $log_file."
    fi
}

run_lynis_audit() {
    print "Running Lynis security audit..."
    # Prefer explicit shell path for Lynis (ksh93 -> ksh fallback).
    if [ -x /usr/local/bin/ksh93 ]; then
        shell_bin="/usr/local/bin/ksh93"
    else
        shell_bin="/bin/ksh"
    fi
    if [ -x /usr/local/bin/lynis ]; then
        audit_ts=$(date +%Y%m%d-%H%M%S)
        audit_log="/tmp/lynis-audit-${audit_ts}.log"
        audit_report="/tmp/lynis-report-${audit_ts}.dat"
        lynis_log="/tmp/lynis-terminal-${audit_ts}.log"
        if "$shell_bin" /usr/local/bin/lynis \
            audit system --quiet \
            --logfile "$audit_log" \
            --report-file "$audit_report" \
            2>&1 | tee "$lynis_log"; then
            chmod 0600 "$audit_log" \
                "$audit_report" 2>/dev/null || true
            chmod 0600 "$lynis_log" 2>/dev/null || true
            print ""
            print "---"
            print "Lynis audit saved to:"
            print "  $lynis_log"
            print "  $audit_log"
            print "  $audit_report"
            print "---"
        else
            print ""
            print "---"
            print "Lynis audit had errors; see:"
            print "  $lynis_log"
            print "---"
        fi
    else
        print "lynis not found; skipping security audit."
    fi
}

collect_system_info_and_upload() {
    print "Collecting system info..."
    out_log="/tmp/openbsd-info-$(date +%Y%m%d-%H%M%S).log"
    rcctl_ls_on_output=""
    if command -v rcctl >/dev/null 2>&1; then
        rcctl_ls_on_output=$(rcctl ls on 2>/dev/null || true)
    fi
    print_section() {
        print ""
        print "---"
        print ""
        print "=== $1 ==="
        print ""
    }
    {
        print_section "System Info"
        uname -a
        print ""
        sysctl -n kern.version 2>/dev/null || true
        print_section "Boot Log (dmesg.boot)"
        if [ -f /var/run/dmesg.boot ]; then
            cat /var/run/dmesg.boot
        else
            dmesg
        fi
        print_section "Installed Packages (pkg_info -mz)"
        pkg_info -mz 2>/dev/null \
            || print "pkg_info not available."
        print_section "Enabled Services (rcctl ls on)"
        if [ -n "$rcctl_ls_on_output" ]; then
            print -- "$rcctl_ls_on_output"
        elif command -v rcctl >/dev/null 2>&1; then
            print "No enabled services listed."
        else
            print "rcctl not available."
        fi
        print_section "Failed Services (rcctl ls failed)"
        if command -v rcctl >/dev/null 2>&1; then
            rcctl ls failed 2>/dev/null \
                || print "No failed services."
        else
            print "rcctl not available."
        fi
        print_section "Recent Events (last 200 lines)"
        if [ -f /var/log/messages ]; then
            tail -n 200 /var/log/messages
        else
            print "/var/log/messages not available."
        fi
        print_section "Disk Usage (df -h)"
        if command -v df >/dev/null 2>&1; then
            df -h
        else
            print "df not available."
        fi
        if [ -n "$rcctl_ls_on_output" ] \
            && print -- "$rcctl_ls_on_output" \
            | grep -Eq '^xenodm$'; then
            print_section "Xenocara Log (last 200 lines)"
            if [ -f /var/log/Xorg.0.log ]; then
                tail -n 200 /var/log/Xorg.0.log
            else
                print "/var/log/Xorg.0.log not available."
            fi
        fi
    } 2>&1 | tee "$out_log"
    chmod 0600 "$out_log" 2>/dev/null || true
    print ""
    print "---"
    print "System info saved to: $out_log"
    print "---"
}

main() {
    run_sysmerge
    upgrade_packages
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
	log "sysupgrade completed; system info collection will run on"
	log "first boot via /etc/rc.firsttime."
}

main "$@"
