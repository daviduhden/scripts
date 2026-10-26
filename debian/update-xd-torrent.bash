#!/bin/bash

set -euo pipefail

# XD Go build/install script
# Builds and installs the latest XD from source on Debian-based systems.
# - Requires Go to be installed
# - Clones or updates the XD GitHub repository
# - Builds the project using make
# - Installs the resulting binary into /usr/bin
# - Ensures "xd" system user/group and working directory exist
# - Installs/upgrades official xd.service systemd unit
#
# Requirements: root privileges, network access, git, curl, install,
# getent, make, and Go. useradd, groupadd, and systemctl are required
# unless --skip-service-and-user-setup is used. Go is not installed by
# this script.
#
# Side effects:
#  - Clones or updates the source under $HOME/.local/src/XD and checks
#    out the latest tag
#  - Builds with make and installs through make install PREFIX=/usr,
#    placing the binary in /usr/bin to match the upstream unit
#  - Creates the xd system user/group and /var/lib/XD
#  - Stops a running xd before building and restores it on exit if the
#    run stopped it
#  - Replaces /etc/systemd/system/xd.service, reloads systemd, enables
#    xd, and restarts it when it was active before
#
# The unit file is downloaded from the upstream master branch and is
# not verified. With --skip-service-and-user-setup the build and
# install still run, but user, unit, and systemd steps are omitted.
# When the checkout is already at the latest tag, the build is skipped
# and service setup still runs.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PATH="${PATH}:/usr/local/go/bin"
export PATH

REPO="majestrate/XD"
REPO_URL="https://github.com/${REPO}.git"
BUILD_DIR="${HOME}/.local/src"
BIN_NAME="XD"
SYSTEMD_UNIT_URL="https://raw.githubusercontent.com"
SYSTEMD_UNIT_URL="${SYSTEMD_UNIT_URL}/majestrate/XD"
SYSTEMD_UNIT_URL="${SYSTEMD_UNIT_URL}/refs/heads/master"
SYSTEMD_UNIT_URL="${SYSTEMD_UNIT_URL}/contrib/systemd/xd.service"
SYSTEMD_UNIT_FILE="/etc/systemd/system/xd.service"
XD_USER="xd"
XD_GROUP="xd"
XD_HOME_DIR="/var/lib/XD"

# Control: set when the local copy is already on the latest tag
SKIP_BUILD=0
WAS_ACTIVE=0
SKIP_SERVICE_AND_USER_SETUP=0

usage() {
	cat <<'EOF'
Usage: update-xd-torrent.bash [--skip-service-and-user-setup]

Options:
  --skip-service-and-user-setup  Skip xd user/group
                                creation and systemd
                                install/enable steps.
  -h, --help                     Show this help message and exit.
EOF
}

parse_args() {
	local flag_used=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--skip-service-and-user-setup)
			flag_used=1
			SKIP_SERVICE_AND_USER_SETUP=1
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
			;;
		esac
		shift
	done
	if [ "$flag_used" -eq 1 ]; then
		warn "CLI flag detected;" \
			"using non-default options" \
			"instead of standard behavior."
	fi
}

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
	exit 1
}

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || error "Run as root (sudo $0)"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		error "Required command '$1' not found."
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

ensure_go() {
	require_cmd go
	log "Go version: $(go version)"
}

# Clone on first use, fetch tags, and compare HEAD with the newest tag.
# The newest tag is the one attached to the most recent tagged commit.
# Sets SKIP_BUILD when HEAD is exactly that tag.
clone_or_update_repo() {
	mkdir -p "$BUILD_DIR"
	cd "$BUILD_DIR"
	if [ ! -d "$BIN_NAME" ]; then
		log "Cloning $BIN_NAME repository..."
		git clone "$REPO_URL" "$BIN_NAME"
	fi

	cd "$BUILD_DIR/$BIN_NAME"

	# Fetch tags and remote refs
	git fetch --tags --prune origin || git fetch --tags --prune

	# Determine latest tag (by tag creation date)
	latest_tag=$(git describe --tags \
		"$(git rev-list --tags --max-count=1)" \
		2>/dev/null || true)

	if [ -n "$latest_tag" ]; then
		local_tag=$(git describe --tags \
			--exact-match HEAD 2>/dev/null || true)
		if [ "$local_tag" = "$latest_tag" ]; then
			log "Local repository is already at" \
				"latest tag '$latest_tag'." \
				"Skipping build."
			SKIP_BUILD=1
			return
		fi
		log "Checking out latest tag $latest_tag..."
		git checkout "tags/$latest_tag" -q
	else
		log "No tags found; updating to latest commit on default branch..."
		git pull --ff-only
	fi
}

# Build with LD_PRELOAD unset, then install under /usr. PREFIX=/usr is
# deliberate: the upstream unit expects /usr/bin/XD.
build_and_install_XD() {
	log "Building XD..."
	env -u LD_PRELOAD make
	log "Installing XD..."
	# Install to /usr/bin so the downloaded xd.service ExecStart matches.
	make install PREFIX=/usr
	log "XD installed successfully."
}

# Create the group and user only when missing, using system accounts.
# The user has no login shell. The home directory is created if needed
# and its ownership is normalized on every run.
ensure_xd_user_group_and_home() {
	log "Ensuring xd system group/user and working directory exist..."

	if ! getent group "$XD_GROUP" >/dev/null 2>&1; then
		log "Creating system group '$XD_GROUP'..."
		groupadd --system "$XD_GROUP"
	fi

	if ! id -u "$XD_USER" >/dev/null 2>&1; then
		log "Creating system user '$XD_USER'..."
		useradd --system \
			--gid "$XD_GROUP" \
			--home-dir "$XD_HOME_DIR" \
			--shell /usr/sbin/nologin "$XD_USER"
	fi

	mkdir -p "$XD_HOME_DIR"
	chown -R "$XD_USER:$XD_GROUP" "$XD_HOME_DIR"
}

stop_xd_if_running() {
	log "Stopping xd service if it is running..."
	if systemctl is-active --quiet xd; then
		WAS_ACTIVE=1
		systemctl stop xd
	fi
}

# If this run stopped a running xd and a later step failed
# before the restart, bring the service back up instead of
# leaving it down.
restore_xd_if_needed() {
	if [ "$WAS_ACTIVE" -eq 1 ] &&
		! systemctl is-active --quiet xd; then
		systemctl start xd >/dev/null 2>&1 || true
	fi
}
trap restore_xd_if_needed EXIT

# Download the upstream unit, install it mode 0644, reload systemd,
# and enable xd. The service is restarted only if it was active before
# this run; otherwise the user is told how to start it.
install_systemd_service() {
	log "Updating systemd unit: $SYSTEMD_UNIT_FILE..."
	install -d /etc/systemd/system

	local unit_tmp
	unit_tmp="$(mktemp /tmp/xd-service-XXXXXX)"
	if ! net_curl "$SYSTEMD_UNIT_URL" -o "$unit_tmp"; then
		rm -f "$unit_tmp"
		error "Failed to download systemd unit from ${SYSTEMD_UNIT_URL}"
	fi

	install -m 0644 "$unit_tmp" "$SYSTEMD_UNIT_FILE"
	rm -f "$unit_tmp"

	log "Reloading systemd daemon..."
	systemctl daemon-reload

	log "Enabling xd service at boot..."
	systemctl enable xd >/dev/null 2>&1 || true

	if [ "$WAS_ACTIVE" -eq 1 ]; then
		log "Restarting xd..."
		systemctl restart xd
	else
		log "xd was not running before."
		log "You can start it now with: systemctl start xd"
	fi
}

check_prereqs() {
	require_root
	require_cmd git
	require_cmd curl
	require_cmd install
	require_cmd getent
	require_cmd make
	if [ "$SKIP_SERVICE_AND_USER_SETUP" -eq 0 ]; then
		require_cmd systemctl
		require_cmd useradd
		require_cmd groupadd
	fi
}

prepare_service_state() {
	if [ "$SKIP_SERVICE_AND_USER_SETUP" -eq 0 ]; then
		ensure_xd_user_group_and_home
		stop_xd_if_running
	else
		log "Skipping xd user/group creation and systemd setup as requested."
	fi
}

build_if_needed() {
	if [ "$SKIP_BUILD" -eq 1 ]; then
		log "No build required. Continuing with system setup."
	else
		build_and_install_XD
	fi
}

finalize_service_setup() {
	if [ "$SKIP_SERVICE_AND_USER_SETUP" -eq 0 ]; then
		install_systemd_service
	fi
}

# Build order matters: prepare and stop the service before replacing
# the binary, then build, then install or refresh the unit. If the
# build is skipped, service setup still proceeds.
run_update() {
	ensure_go
	clone_or_update_repo
	prepare_service_state
	build_if_needed
	finalize_service_setup
}

main() {
	parse_args "$@"
	check_prereqs
	run_update
}

main "$@"
