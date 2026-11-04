#!/bin/bash

set -euo pipefail

# Debian golang update script
# Automatically install/update Go (golang) to the latest stable version
# on Linux systems using official tarballs.
# - Fetch latest stable version from go.dev
# - Download the appropriate tarball for the system architecture
# - Install into /usr/local/go
# - Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile
#
# Requirements: root privileges, network access, curl, Python 3, install,
# awk, mv, uname, and mktemp. Only Linux is supported.
#
# Side effects:
#  - Replaces /usr/local/go with the downloaded release
#  - Appends an export to /etc/profile when /usr/local/go/bin is not
#    already mentioned, after copying it to a timestamped backup
#  - Stages the verified archive beside the destination and cleans it on exit
#  - Retains prior installations under /usr/local/.go-backup.* for recovery
#
# The archive SHA-256 is checked against the exact official go.dev metadata.
# This trusts HTTPS rather than an independent signature. A new tree is
# prepared and version-checked before activation, with restoration on failure.
# A distribution Go package is untouched; only /usr/local/go is replaced.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin
PATH="${PATH}:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
PERL_CMD="${PERL_CMD:-perl}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
RELEASE_HELPER="${RELEASE_HELPER:-}"
if [ -z "$RELEASE_HELPER" ]; then
	RELEASE_HELPER=""
	for candidate in "$SCRIPT_DIR/release-verify.pl" "$SCRIPT_DIR/release-verify" "$SCRIPT_DIR/../scripts/release-verify.pl"; do
		if [ -f "$candidate" ]; then
			RELEASE_HELPER="$candidate"
			break
		fi
	done
fi

GO_BASE_URL="https://go.dev/dl"
VERSION_URL="https://go.dev/VERSION?m=text"
INSTALL_DIR="/usr/local"
GO_ROOT="${INSTALL_DIR}/go"
GO_STAGE=
GO_LOCK=
GO_BACKUP=

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() {
	printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

# EXIT cleanup can run after the updater function has returned, so transaction
# paths are global rather than trap references to expired local variables.
cleanup_go_update() {
	local status=$?
	if [[ -n $GO_BACKUP && -d $GO_BACKUP/go && ! -e $GO_ROOT && ! -L $GO_ROOT ]]; then
		if ! mv -T -- "$GO_BACKUP/go" "$GO_ROOT"; then
			warn "Restoration failed; previous Go tree retained at $GO_BACKUP/go"
			status=1
		fi
	fi
	if [[ -n $GO_STAGE && -d $GO_STAGE ]]; then rm -rf -- "$GO_STAGE"; fi
	if [[ -n $GO_LOCK && -d $GO_LOCK ]]; then rmdir -- "$GO_LOCK" || status=1; fi
	return "$status"
}

require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		error "This script must be run as root. Try: sudo $0"
	fi
}

# Helper to ensure required commands exist
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "required command '$1' is not installed or not in PATH."
	fi
}

net_curl() {
	curl -fLsS --retry 5 "$@"
}

# Get the latest stable Go version (e.g. go1.25.5) from go.dev.
# The endpoint returns the version followed by a timestamp; everything
# from the first whitespace character is discarded.
get_latest_go_version() {
	local ver
	if ! ver="$(net_curl "$VERSION_URL" 2>/dev/null)"; then
		return 1
	fi
	# Strip trailing whitespace/newlines
	ver="${ver%%[[:space:]]*}"
	printf '%s\n' "$ver"
}

# Map the kernel machine type to the architecture component of the
# official tarball name. armv7 is mapped to armv6l because that is the
# 32-bit ARM tarball name upstream publishes.
detect_go_arch() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
	x86_64 | amd64) printf '%s\n' "amd64" ;;
	i386 | i486 | i586 | i686 | x86) printf '%s\n' "386" ;;
	aarch64 | arm64) printf '%s\n' "arm64" ;;
	armv6l) printf '%s\n' "armv6l" ;;
	armv7l | armv7hl | armv7) printf '%s\n' "armv6l" ;;
	loongarch64) printf '%s\n' "loong64" ;;
	mips) printf '%s\n' "mips" ;;
	mips64) printf '%s\n' "mips64" ;;
	mipsel | mipsle) printf '%s\n' "mipsle" ;;
	mips64el | mips64le) printf '%s\n' "mips64le" ;;
	ppc64) printf '%s\n' "ppc64" ;;
	ppc64le | ppc64el) printf '%s\n' "ppc64le" ;;
	riscv64) printf '%s\n' "riscv64" ;;
	s390x) printf '%s\n' "s390x" ;;
	*) error "Unsupported architecture: ${arch}." \
		"No matching official Go Linux tarball" \
		"known for this arch." ;;
	esac
}

# Ensure /usr/local/go/bin is in system-wide PATH via /etc/profile.
# A simple substring check makes this idempotent; the file is backed up
# before the export is appended.
ensure_go_path_in_etc_profile() {
	local profile_file="/etc/profile"
	local backup_suffix
	local go_path_snippet

	go_path_snippet='# Go binary path'
	go_path_snippet="${go_path_snippet}"$'\n'
	go_path_snippet="${go_path_snippet}"'export PATH='
	go_path_snippet="${go_path_snippet}\"\$PATH:/usr/local/go/bin\""
	go_path_snippet="${go_path_snippet}"$'\n'

	if [[ ! -f $profile_file ]]; then
		warn "${profile_file} not found;" \
			"cannot automatically update system PATH."
		return 0
	fi

	if grep -q '/usr/local/go/bin' "$profile_file"; then
		log "${profile_file} already contains" \
			"/usr/local/go/bin in PATH." \
			"No changes made."
		return 0
	fi

	backup_suffix="$(date +%Y%m%d%H%M%S)"
	cp "$profile_file" "${profile_file}.bak.${backup_suffix}"
	log "Backup of ${profile_file} created at" \
		"${profile_file}.bak.${backup_suffix}"

	printf '\n%s' "$go_path_snippet" >>"$profile_file"
	log "${profile_file} updated to include /usr/local/go/bin in PATH."
}

run_golang_update() {
	OS="$(uname -s)"
	if [[ $OS != "Linux" ]]; then
		error "this script currently supports only Linux."
	fi

	log "Checking latest Go version from go.dev..."
	LATEST_VERSION="$(get_latest_go_version || true)"
	if [[ -z ${LATEST_VERSION} ]]; then
		error "could not fetch latest Go version from ${VERSION_URL}."
	fi
	log "Latest available Go version: ${LATEST_VERSION}"

	CURRENT_VERSION=""
	if command -v go >/dev/null 2>&1; then
		CURRENT_VERSION="$(go version 2>/dev/null | awk '{print $3}')"
	fi
	if [[ -n $CURRENT_VERSION ]]; then
		log "Currently installed Go version: ${CURRENT_VERSION}"
		if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
			log "Go is already up to date. Nothing to do."
			return 0
		fi
	else
		log "Go is not currently installed."
	fi

	GO_ARCH="$(detect_go_arch)"
	TAR_NAME="${LATEST_VERSION}.linux-${GO_ARCH}.tar.gz"
	TAR_URL="${GO_BASE_URL}/${TAR_NAME}"
	[[ $LATEST_VERSION =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || error 'Invalid Go release version'
	install -d -m 0755 "$INSTALL_DIR"
	local lock="$INSTALL_DIR/.go-update.lock" stage backup='' published actual listing
	mkdir -- "$lock" 2>/dev/null || error "Go update lock exists: $lock (inspect before removing)"
	stage=$(mktemp -d "$INSTALL_DIR/.go-install.XXXXXX") || {
		rmdir -- "$lock"
		error 'Cannot create Go staging directory'
	}
	GO_STAGE=$stage
	GO_LOCK=$lock
	# The backup is deliberately retained, including after failed restoration.
	trap cleanup_go_update EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	TAR_FILE="$stage/release.tar.gz"
	log "Downloading ${TAR_NAME} from ${TAR_URL}..."
	net_curl --proto '=https' --proto-redir '=https' "$TAR_URL" -o "$TAR_FILE"
	net_curl --proto '=https' --proto-redir '=https' 'https://go.dev/dl/?mode=json&include=all' -o "$stage/releases.json"
	# Verify the exact filename/digest from official metadata, then extract
	# regular files/directories only into the new tree, never the live install.
	published=$("$PERL_CMD" "$RELEASE_HELPER" json-file-digest "$TAR_NAME" \
		<"$stage/releases.json") || error 'Go archive validation failed'
	actual=$(sha256sum "$TAR_FILE" | awk '{print $1}') ||
		error 'Go archive validation failed'
	[[ $actual == "$published" ]] || error 'Go SHA-256 mismatch'
	listing=$(tar -tzf "$TAR_FILE") || error 'Go archive validation failed'
	if printf '%s\n' "$listing" |
		grep -Eq '(^|/)\.\.(/|$)|^/' ||
		[ -n "$(printf '%s\n' "$listing" | sort | uniq -d)" ] ||
		! tar -tvzf "$TAR_FILE" | awk '$1 !~ /^[d-]/ { exit 1 }'; then
		error 'Go archive validation failed'
	fi
	"$PERL_CMD" "$RELEASE_HELPER" tar-extract-all \
		"$TAR_FILE" "$stage" go 2147483648 ||
		error 'Go archive validation failed'
	[[ -f $stage/go/bin/go && ! -L $GO_ROOT ]] || error 'Invalid staged binary or linked install destination'
	[[ "$("$stage/go/bin/go" version | awk '{print $3}')" == "$LATEST_VERSION" ]] || error 'Staged Go version mismatch'
	if [[ -e $GO_ROOT ]]; then
		[[ -d $GO_ROOT ]] || error 'Go destination is not a directory'
		backup=$(mktemp -d "$INSTALL_DIR/.go-backup.XXXXXX")
		GO_BACKUP=$backup
		mv -T -- "$GO_ROOT" "$backup/go"
	fi
	if ! mv -T -- "$stage/go" "$GO_ROOT"; then
		if [[ -n $backup ]] && ! mv -T -- "$backup/go" "$GO_ROOT"; then
			error "Go activation and restoration failed; previous tree retained at $backup/go"
		fi
		error 'Go activation failed; previous installation restored'
	fi
	[[ -z $backup ]] || log "Previous Go installation retained at $backup/go"
	log "Go installation finished successfully: $LATEST_VERSION"

	ensure_go_path_in_etc_profile
	log "Done."
	log "Log out and log back in" \
		"(or source /etc/profile)" \
		"to ensure the new PATH is applied."
}

run_update() {
	run_golang_update
}

check_prereqs() {
	require_root
	require_cmd curl
	require_cmd tar
	require_cmd install
	require_cmd uname
	require_cmd mktemp
	require_cmd "$PERL_CMD"
	require_cmd sha256sum
	require_cmd awk
	require_cmd mv
	[ -f "$RELEASE_HELPER" ] ||
		error "release-verify helper not found: $RELEASE_HELPER"
}

main() {
	check_prereqs
	run_update
}

main "$@"
