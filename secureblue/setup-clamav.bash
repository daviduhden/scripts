#!/bin/bash
set -euo pipefail

# SecureBlue ClamAV setup script
# Configures ClamAV with self-healing updates, on-access scanning,
# and periodic system scans. Also sets up SELinux contexts and
# filesystem permissions to ensure proper operation.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

###################
# Logging helpers #
###################
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

log() { printf '%s %b[INFO]%b  %s\n' "$(date '+%F %T')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b  %s\n' "$(date '+%F %T')" "$YELLOW" "$RESET" "$*"; }
error() {
	printf '%s %b[ERROR]%b %s\n' "$(date '+%F %T')" "$RED" "$RESET" "$*" >&2
	exit 1
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || error "Root required"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || error "Required command '$1' not found"
}

# Fedora's ClamAV account naming has varied across releases/packages.
# Resolve a usable service account dynamically for Atomic 44+.
CLAMAV_USER=""
CLAMAV_GROUP=""

resolve_clamav_account() {
	for candidate in clamav clamscan; do
		if id -u "$candidate" >/dev/null 2>&1; then
			CLAMAV_USER="$candidate"
			break
		fi
	done

	[[ -n "$CLAMAV_USER" ]] || error "No ClamAV service user found (tried: clamav, clamscan)"

	CLAMAV_GROUP="$(id -gn "$CLAMAV_USER")"
	[[ -n "$CLAMAV_GROUP" ]] || error "Could not resolve primary group for $CLAMAV_USER"

	log "Using ClamAV service account: ${CLAMAV_USER}:${CLAMAV_GROUP}"
}

########################
# PACKAGE INSTALLATION #
########################

install_packages() {
	log "Installing ClamAV packages"

	for pkg in clamd clamav clamav-freshclam policycoreutils-python-utils; do
		if ! rpm -q "$pkg" >/dev/null 2>&1; then
			rpm-ostree install -y "$pkg" || warn "Failed to layer $pkg (may already be installed)"
		else
			log "$pkg is already installed, skipping"
		fi
	done
}

##########################
# FILESYSTEM PERMISSIONS #
##########################

fix_permissions() {
	log "Fixing filesystem permissions"

	install -d -m 0775 -o "$CLAMAV_USER" -g "$CLAMAV_GROUP" /var/lib/clamav
	install -d -m 0775 -o "$CLAMAV_USER" -g "$CLAMAV_GROUP" /var/log/clamav
	install -d -m 0775 -o "$CLAMAV_USER" -g "$CLAMAV_GROUP" /run/clamd.scan
	install -d -m 0770 -o root -g root /var/spool/quarantine

	touch /var/log/freshclam.log
	chown "$CLAMAV_USER:$CLAMAV_GROUP" /var/log/freshclam.log
	chmod 0664 /var/log/freshclam.log
}

#########################
# SELINUX CONFIGURATION #
#########################

fix_selinux() {
	log "Configuring SELinux file contexts"

	semanage fcontext -a -t antivirus_db_t "/var/lib/clamav(/.*)?" 2>/dev/null ||
		semanage fcontext -m -t antivirus_db_t "/var/lib/clamav(/.*)?"

	semanage fcontext -a -t antivirus_log_t "/var/log/clamav(/.*)?" 2>/dev/null ||
		semanage fcontext -m -t antivirus_log_t "/var/log/clamav(/.*)?"

	semanage fcontext -a -t antivirus_log_t "/var/log/freshclam.log" 2>/dev/null ||
		semanage fcontext -m -t antivirus_log_t "/var/log/freshclam.log"

	semanage fcontext -a -t antivirus_var_run_t "/run/clamd.scan(/.*)?" 2>/dev/null ||
		semanage fcontext -m -t antivirus_var_run_t "/run/clamd.scan(/.*)?"

	restorecon -RF \
		/var/lib/clamav \
		/var/log/clamav \
		/var/log/freshclam.log \
		/run/clamd.scan
}

###########################
# FRESHCLAM CONFIGURATION #
###########################

configure_freshclam() {
	log "Configuring freshclam"

	sed -i \
		-e 's/^Example/#Example/' \
		-e 's|^#DatabaseDirectory.*|DatabaseDirectory /var/lib/clamav|' \
		-e 's|^#UpdateLogFile.*|UpdateLogFile /var/log/freshclam.log|' \
		-e 's|^#NotifyClamd.*|NotifyClamd /etc/clamd.d/scan.conf|' \
		/etc/freshclam.conf
}

run_freshclam() {
	log "Running freshclam database update"
	freshclam || error "freshclam failed"
}

#######################
# CLAMD CONFIGURATION #
#######################

configure_clamd() {
	log "Configuring clamd (scan instance)"

	sed -i \
		-e 's/^Example/#Example/' \
		-e 's|^#LocalSocket .*|LocalSocket /run/clamd.scan/clamd.sock|' \
		-e 's|^#LocalSocketMode .*|LocalSocketMode 0660|' \
		-e "s|^#User .*|User $CLAMAV_USER|" \
		-e 's|^#LogFile .*|LogFile /var/log/clamav/clamd.log|' \
		-e 's|^#ScanOnAccess .*|ScanOnAccess yes|' \
		-e 's|^#OnAccessIncludePath .*|OnAccessIncludePath /var/home|' \
		-e 's|^#OnAccessExcludeRootUID .*|OnAccessExcludeRootUID yes|' \
		/etc/clamd.d/scan.conf

	systemctl enable --now clamd@scan.service
}

######################
# ON-ACCESS SCANNING #
######################

configure_clamonacc() {
	log "Configuring clamonacc (on-access scanning)"

	cat >/etc/systemd/system/clamonacc.service <<'EOF'
[Unit]
Description=ClamAV On-Access Scanner
After=clamd@scan.service
Requires=clamd@scan.service

[Service]
ExecStart=/usr/sbin/clamonacc \
  --fdpass \
	--config-file=/etc/clamd.d/scan.conf \
  --log=/var/log/clamav/clamonacc.log \
  --exclude-dir=/proc \
  --exclude-dir=/sys \
  --exclude-dir=/run \
  --exclude-dir=/tmp \
  --exclude-dir=/var/lib/containers
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable --now clamonacc.service
}

#####################
# PERIODIC SCANNING #
#####################

configure_periodic_scan() {
	log "Configuring periodic ClamAV scan"

	cat >/usr/local/sbin/clamav-target-scan.bash <<'EOF'
#!/bin/bash
set -euo pipefail

exec /usr/bin/clamdscan \
  --multiscan \
  --fdpass \
  --infected \
  --exclude-dir='^/proc/' \
  --exclude-dir='^/sys/' \
  --exclude-dir='^/run/' \
  --exclude-dir='^/tmp/' \
  --exclude-dir='^/var/lib/containers/' \
  --log=/var/log/clamav/periodic.log \
  --move=/var/spool/quarantine \
  /var/home
EOF

	chmod 0755 /usr/local/sbin/clamav-target-scan.bash

	cat >/etc/systemd/system/clamav-target-scan.service <<'EOF'
[Unit]
Description=ClamAV periodic scan

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clamav-target-scan.bash
SuccessExitStatus=0 1 2
EOF

	cat >/etc/systemd/system/clamav-target-scan.timer <<'EOF'
[Unit]
Description=Daily ClamAV scan

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload
	systemctl enable --now clamav-target-scan.timer
}

check_prereqs() {
	require_cmd install
	require_cmd sed
	require_cmd systemctl
	require_cmd rpm-ostree
	require_cmd rpm
	require_cmd restorecon
	require_cmd semanage
}

run_setup() {
	install_packages
	resolve_clamav_account
	fix_permissions
	fix_selinux
	configure_freshclam
	run_freshclam
	configure_clamd
	configure_clamonacc
	configure_periodic_scan
	log "ClamAV installation and configuration completed successfully 🎉"
}

########
# MAIN #
########

main() {
	require_root
	check_prereqs
	run_setup
}

main "$@"
