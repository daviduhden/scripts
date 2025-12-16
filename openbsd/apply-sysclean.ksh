#!/bin/ksh

# If we are NOT already running under ksh93, try to re-exec with ksh93.
# If ksh93 is not available, fall back to the base ksh (OpenBSD /bin/ksh).
case "${KSH_VERSION-}" in
*93*) : ;; # already ksh93
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

# Source silent helper if available (prefer silent.ksh, fallback to silent)
if [ -f "$(dirname "$0")/../lib/silent.ksh" ]; then
	# shellcheck source=/dev/null
	. "$(dirname "$0")/../lib/silent.ksh"
	start_silence
elif [ -f "$(dirname "$0")/../lib/silent" ]; then
	# shellcheck source=/dev/null
	. "$(dirname "$0")/../lib/silent"
	start_silence
fi

# Ensure common tools are available (attempt auto-install when possible)
printf '[WARN] automatic package install removed; please ensure the following are installed: curl git ca-certificates\n' >&2

# OpenBSD apply-sysclean script
#
# This script runs sysclean(8), parses its report, and applies the suggested
# cleanup actions to remove obsolete files, users, and groups left behind
# after system or package updates.
#
# Behavior:
#   - Requires root privileges (must be run as UID 0).
#   - Ensures sysclean(8) is available, installing it via pkg_add(1) or
#     ./sysclean && make install if necessary (unless in dry-run mode).
#   - Generates a sysclean report into $SYSCLEAN_OUT (default: /tmp/sysclean.out).
#   - Removes obsolete paths, users, and groups based on that report.
#
# Options:
#   --dry-run | -n   Show what would be removed without making any changes.
#
# Environment:
#   SYSCLEAN_OUT     Path to the sysclean output file (optional override).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Default sysclean output file (can be overridden with SYSCLEAN_OUT env var)
typeset SYSCLEAN_OUT SYSCLEAN_BUNDLED_DIR DRY_RUN
SYSCLEAN_OUT="${SYSCLEAN_OUT:-/tmp/sysclean.out}"
SYSCLEAN_BUNDLED_DIR="/usr/local/bin/sysclean"
DRY_RUN=0

if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
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

log() { print "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${RESET} ✅ $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${RESET} ⚠️ $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${RESET} ❌ $*" >&2; }

parse_args() {
	case "${1:-}" in
	--dry-run | -n)
		DRY_RUN=1
		shift
		;;
	esac
	set -- "$@"
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root (superuser)."
		exit 1
	fi
}

cleanup_bundled_sysclean() {
	typeset sysclean_path
	sysclean_path="$1"
	if [ -n "$sysclean_path" ] && [ -d "$SYSCLEAN_BUNDLED_DIR" ] && [ "$DRY_RUN" -ne 1 ]; then
		if [ "${sysclean_path%/*}" != "$SYSCLEAN_BUNDLED_DIR" ]; then
			log "Removing unused bundled sysclean at $SYSCLEAN_BUNDLED_DIR"
			rm -rf "$SYSCLEAN_BUNDLED_DIR" || warn "failed to remove $SYSCLEAN_BUNDLED_DIR"
		fi
	fi
}

install_sysclean_pkg() {
	if ! command -v pkg_add >/dev/null 2>&1; then
		log "pkg_add not found in PATH, skipping pkg_add installation."
		return 1
	fi

	log "Trying to install sysclean with pkg_add..."
	if pkg_add -v sysclean; then
		log "sysclean installed via pkg_add."
		return 0
	fi

	warn "pkg_add sysclean failed."
	return 1
}

install_sysclean_bundled() {
	if [ ! -d "$SYSCLEAN_BUNDLED_DIR" ]; then
		log "No bundled sysclean directory found for local installation."
		return 1
	fi

	log "Trying to install sysclean from $SYSCLEAN_BUNDLED_DIR via make realinstall (BINDIR=/usr/local/bin)..."
	if (cd "$SYSCLEAN_BUNDLED_DIR" && make BINDIR=/usr/local/bin realinstall); then
		log "sysclean installed from bundled directory."
		return 0
	fi

	warn "bundled sysclean make install failed."
	return 1
}

ensure_sysclean_installed() {
	typeset sysclean_path
	sysclean_path="$(command -v sysclean 2>/dev/null || true)"

	cleanup_bundled_sysclean "$sysclean_path"

	if [ -n "$sysclean_path" ]; then
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		error "sysclean is not installed and DRY RUN is enabled; not installing automatically."
		exit 1
	fi

	log "sysclean not found in PATH, attempting installation..."

	install_sysclean_pkg || true

	if ! command -v sysclean >/dev/null 2>&1; then
		install_sysclean_bundled || true
	fi

	if ! command -v sysclean >/dev/null 2>&1; then
		error "sysclean is still not available after installation attempts; aborting."
		exit 1
	fi

	cleanup_bundled_sysclean "$(command -v sysclean 2>/dev/null || true)"
}

run_sysclean() {
	log "Running sysclean to generate: $SYSCLEAN_OUT"
	if ! sysclean >"$SYSCLEAN_OUT" 2>/dev/null; then
		error "sysclean execution failed."
		exit 1
	fi
	log "sysclean output written to: $SYSCLEAN_OUT"

	if [ ! -s "$SYSCLEAN_OUT" ]; then
		warn "sysclean output file is empty: $SYSCLEAN_OUT"
	fi
}

remove_obsolete_paths() {
	log "Parsing obsolete paths from: $SYSCLEAN_OUT"

	awk 'NF && $1 ~ /^\// {print $1}' "$SYSCLEAN_OUT" | sort -u |
		while IFS= read -r path; do
			[ -n "$path" ] || continue

			if [ "$DRY_RUN" -eq 1 ]; then
				log "DRY RUN: would remove file or directory: $path"
				continue
			fi

			if [ -e "$path" ] || [ -L "$path" ]; then
				log "Removing file or directory: $path"
				rm -rf -- "$path" || warn "failed to remove: $path"
			else
				log "Skipping non-existent path: $path"
			fi
		done
}

remove_obsolete_users() {
	log "Parsing obsolete users from: $SYSCLEAN_OUT"

	awk '$1=="@user" {
            sub(/^@user[[:space:]]+/, "", $0);
            split($0, a, ":");
            print a[1];
        }' "$SYSCLEAN_OUT" | sort -u |
		while IFS= read -r user; do
			[ -n "$user" ] || continue

			if [ "$DRY_RUN" -eq 1 ]; then
				log "DRY RUN: would remove user: $user"
				continue
			fi

			if id "$user" >/dev/null 2>&1; then
				log "Removing user: $user"
				userdel "$user" || warn "failed to remove user: $user"
			else
				log "Skipping user (not found): $user"
			fi
		done
}

remove_obsolete_groups() {
	log "Parsing obsolete groups from: $SYSCLEAN_OUT"

	awk '$1=="@group" {
            sub(/^@group[[:space:]]+/, "", $0);
            split($0, a, ":");
            print a[1];
        }' "$SYSCLEAN_OUT" | sort -u |
		while IFS= read -r group; do
			[ -n "$group" ] || continue

			if [ "$DRY_RUN" -eq 1 ]; then
				log "DRY RUN: would remove group: $group"
				continue
			fi

			if getent group "$group" >/dev/null 2>&1; then
				log "Removing group: $group"
				groupdel "$group" || warn "failed to remove group: $group"
			else
				log "Skipping group (not found): $group"
			fi
		done
}

main() {
	parse_args "$@"

	log "----------------------------------------"
	log "apply-sysclean started"

	require_root
	ensure_sysclean_installed
	run_sysclean
	remove_obsolete_paths
	remove_obsolete_users
	remove_obsolete_groups

	log "apply-sysclean finished"
	log "----------------------------------------"
}

main "$@"
