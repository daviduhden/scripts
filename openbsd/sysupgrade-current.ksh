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

log "Preparing /upgrade.site for post-upgrade tasks..."

# Clean previous artifacts from earlier runs
if [ -f /upgrade.site ]; then
    rm -f /upgrade.site
fi
if ls /tmp/openbsd-info.* >/dev/null 2>&1; then
    rm -f /tmp/openbsd-info.*
fi

# 1. Create /upgrade.site, which will be executed at the end of the
#    upgrade process inside the new system.
cat << 'EOF' > /upgrade.site
#!/bin/ksh
# This script is executed at the end of the upgrade
# in the context of the new system (see upgrade.site(5)).

RCF=/etc/rc.firsttime

# Create /etc/rc.firsttime if it does not exist
if [ ! -f "$RCF" ]; then
    umask 022
    {
        echo '#!/bin/ksh'
        echo 'echo "Running /etc/rc.firsttime post-upgrade tasks..."'
    } > "$RCF"
    chmod 700 "$RCF"
fi

# Append the actions to be run on the first boot after the upgrade
cat <<'EOF_APPEND' >> "$RCF"
echo "Running sysmerge -b..."
/usr/sbin/sysmerge -b

echo "Upgrading packages (pkg_add -Uu -Dsnap) and removing unused ones (pkg_delete -a)..."
/usr/sbin/pkg_add -Uu -Dsnap && /usr/sbin/pkg_delete -a

echo "Running apply-sysclean..."
if [ -x /usr/local/bin/apply-sysclean ]; then
    /usr/local/bin/apply-sysclean
else
    echo "apply-sysclean not found; skipping."
fi

echo "Collecting system info and uploading to 0x0.st..."
collect_system_info_and_upload() {
    CURL_BIN="/usr/local/bin/curl"
    if [ ! -x "$CURL_BIN" ]; then
        CURL_BIN="/usr/bin/curl"
    fi
    if [ ! -x "$CURL_BIN" ]; then
        printf '%s\n' "curl not found; skipping system info upload."
        return
    fi
    tmpf=$(mktemp /tmp/openbsd-info.XXXXXX 2>/dev/null || printf '/tmp/openbsd-info.%s' "$$")
    : >"$tmpf"
    expires_ms=$(( ( $(date +%s) + 86400 ) * 1000 ))
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
    "$CURL_BIN" -fLsS --retry 5 -F "file=@${tmpf}" -F "expires=${expires_ms}" https://0x0.st 2>/dev/null | tr -d "[:space:]" || true
    rm -f "$tmpf"
}

collect_system_info_and_upload
EOF_APPEND
EOF

chmod +x /upgrade.site

log "Running sysupgrade -sf..."
/usr/sbin/sysupgrade -sf

log "sysupgrade completed; system info upload will run on first boot via /etc/rc.firsttime."
