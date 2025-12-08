#!/bin/sh

set -e

# Upgrade to snapshot (-current) and schedule post-upgrade actions
# to run on first boot via rc.firsttime(8).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

log()   { printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Basic PATH (important when run from cron)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

log "Preparing /upgrade.site for post-upgrade tasks..."

# 1. Create /upgrade.site, which will be executed at the end of the
#    upgrade process inside the new system.
cat << 'EOF' > /upgrade.site
#!/bin/sh
# This script is executed at the end of the upgrade
# in the context of the new system (see upgrade.site(5)).

RCF=/etc/rc.firsttime

# Create /etc/rc.firsttime if it does not exist
if [ ! -f "$RCF" ]; then
    umask 022
    {
        echo '#!/bin/sh'
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
/usr/local/bin/apply-sysclean

echo "Collecting system info and uploading to 0x0.st..."
collect_system_info_and_upload() {
    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' "curl not found; skipping system info upload."
        return
    fi
    tmpf=$(mktemp /tmp/openbsd-info.XXXXXX 2>/dev/null || printf '/tmp/openbsd-info.%s' "$$")
    : >"$tmpf"
    expires_ms=$(( ( $(date +%s) + 86400 ) * 1000 ))
    {
        printf '\n=== System Info ===\n\n'
        uname -a
        printf '\n'
        sysctl -n kern.version 2>/dev/null || true
        printf '\n=== Boot Log (dmesg.boot) ===\n\n'
        if [ -f /var/run/dmesg.boot ]; then cat /var/run/dmesg.boot; else dmesg; fi
        printf '\n=== Installed Packages (pkg_info -mz) ===\n\n'
        pkg_info -mz 2>/dev/null || printf '%s\n' "pkg_info not available."
        printf '\n=== Applied Syspatches (syspatch -l) ===\n\n'
        if command -v syspatch >/dev/null 2>&1; then syspatch -l; else printf '%s\n' "syspatch not available."; fi
        printf '\n=== /var/log/messages (last 200 lines) ===\n\n'
        if [ -f /var/log/messages ]; then tail -n 200 /var/log/messages; else printf '%s\n' "/var/log/messages not available."; fi
        printf '\n=== Disk Usage (df -h) ===\n\n'
        if command -v df >/dev/null 2>&1; then df -h; else printf '%s\n' "df not available."; fi
    } > "$tmpf"
    /usr/local/bin/curl -fLsS --retry 5 -F "file=@${tmpf}" -F "expires=${expires_ms}" https://0x0.st 2>/dev/null | tr -d "[:space:]" || true
    rm -f "$tmpf"
}

collect_system_info_and_upload
EOF_APPEND
EOF

chmod +x /upgrade.site

log "Starting sysupgrade -s..."
/usr/sbin/sysupgrade -s

log "sysupgrade completed; system info upload will run on first boot via /etc/rc.firsttime."
