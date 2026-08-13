#!/bin/ksh

set -eu

# OpenBSD Crush installer/updater
# Installs or updates Crush (charmbracelet/crush) from the
# latest precompiled OpenBSD binary published on GitHub:
#  - Detects the latest release via the GitHub API
#  - Downloads the tarball for the running architecture
#  - Verifies the SHA-256 checksum from checksums.txt
#  - Installs the binary, manpage and license to /usr/local
#  - Configures the DeepSeek provider/model (OpenAI-compatible
#    API) in ~/.config/crush/crushrc for the target user, so
#    crush is ready to use DeepSeek out of the box
#
# Usage: update-crush.ksh [USER]
#   USER  user to configure for DeepSeek (default: root)
#
# Environment:
#   DEEPSEEK_API_KEY  DeepSeek API key (consumed by crush at
#                     runtime via the crushrc; not stored here)
#   CRUSH_FORCE=1     Force reinstall even if up to date
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

###################
# PATH and logging #
###################
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

log() { print "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; }

usage() {
	print "Usage: $0 [USER]" >&2
	print "  USER  user to configure for DeepSeek (default: root)" >&2
	exit 2
}

#####################
# Common helpers    #
#####################
check_root() {
	if [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root."
		exit 1
	fi
}

fetch_url() {
	typeset url="$1" out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fLsS --retry 5 "$url" -o "$out"
	elif command -v ftp >/dev/null 2>&1; then
		ftp -o "$out" "$url"
	else
		error "Neither curl nor ftp is available."
		return 1
	fi
}

map_arch() {
	case "$(uname -m)" in
	amd64) print "x86_64" ;;
	i386) print "i386" ;;
	arm64) print "arm64" ;;
	arm) print "armv7" ;;
	*) print "" ;;
	esac
}

resolve_home() {
	typeset user="$1"
	awk -F: -v u="$user" '$1 == u { print $6; exit }' /etc/passwd
}

###################
# DeepSeek config #
###################
configure_deepseek() {
	typeset user_home crushrc_dir crushrc

	user_home=$(resolve_home "$CRUSH_USER")
	[ -n "$user_home" ] || {
		error "Cannot resolve home directory for user: $CRUSH_USER"
		return 1
	}

	crushrc_dir="$user_home/.config/crush"
	crushrc="$crushrc_dir/crushrc"

	crushrc_block=$(
		cat <<'CRUSHRC_EOF'
# --- DeepSeek provider (managed by update-crush.ksh) ---
# OpenAI-compatible API. Set DEEPSEEK_API_KEY in your
# environment before running crush.
provider add deepseek --type openai-compat \
  --base-url "https://api.deepseek.com/v1" \
  --api-key "$DEEPSEEK_API_KEY"

model add deepseek/deepseek-chat \
  --name "Deepseek V3" \
  --context-window 64000 \
  --default-max-tokens 5000 \
  --price-input 0.27 \
  --price-output 1.1 \
  --price-cache-create 1.1 \
  --price-cache-hit 0.07
# --- End DeepSeek section ---
CRUSHRC_EOF
	)

	mkdir -p "$crushrc_dir" || {
		error "Cannot create $crushrc_dir"
		return 1
	}

	# Drop any previously managed DeepSeek block, then re-add it.
	if [ -f "$crushrc" ]; then
		awk '
			/^# --- DeepSeek provider / { skip = 1; next }
			/^# --- End DeepSeek section ---$/ { skip = 0; next }
			skip == 0 { print }
		' "$crushrc" >"$tmpdir/crushrc.new" || {
			error "Cannot rewrite $crushrc"
			return 1
		}
		if ! mv "$tmpdir/crushrc.new" "$crushrc"; then
			error "Cannot replace $crushrc"
			return 1
		fi
	fi

	if [ -f "$crushrc" ]; then
		printf '\n%s\n' "$crushrc_block" >>"$crushrc" || {
			error "Cannot update $crushrc"
			return 1
		}
	else
		printf '%s\n' "$crushrc_block" >"$crushrc" || {
			error "Cannot create $crushrc"
			return 1
		}
	fi

	chown -R "$CRUSH_USER" "$crushrc_dir" ||
		warn "chown failed for $crushrc_dir"
	chmod 0600 "$crushrc"

	log "DeepSeek provider configured in $crushrc"
	if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
		warn "DEEPSEEK_API_KEY is not set; export it" \
			" before running crush."
	fi
}

##############################
# Download, verify, install  #
##############################
install_crush() {
	typeset arch asset url checksum expected_checksum
	typeset extracted release_base

	arch=$(map_arch)
	[ -n "$arch" ] || {
		error "Unsupported architecture: $(uname -m)"
		return 1
	}

	release_base="https://github.com/charmbracelet/crush"
	asset="crush_${CRUSH_VERSION}_Openbsd_${arch}.tar.gz"
	url="${release_base}/releases/download/v${CRUSH_VERSION}/${asset}"

	log "Downloading $asset..."
	fetch_url "$url" "$tmpdir/$asset" || return 1

	log "Downloading checksums.txt..."
	fetch_url \
		"${release_base}/releases/download/v${CRUSH_VERSION}/checksums.txt" \
		"$tmpdir/checksums.txt" || return 1

	expected_checksum=$(awk -v f="$asset" \
		'$2 == f { print $1 }' "$tmpdir/checksums.txt")
	[ -n "$expected_checksum" ] || {
		error "No checksum found for $asset in checksums.txt"
		return 1
	}

	log "Verifying SHA-256 checksum..."
	checksum=$(sha256 -b "$tmpdir/$asset" |
		sed -E 's/.*= *//')
	if [ "$checksum" != "$expected_checksum" ]; then
		error "Checksum mismatch for $asset"
		return 1
	fi
	log "Checksum OK."

	log "Extracting $asset..."
	tar -xzf "$tmpdir/$asset" -C "$tmpdir" || return 1
	extracted="$tmpdir/crush_${CRUSH_VERSION}_Openbsd_${arch}"

	[ -f "$extracted/crush" ] || {
		error "crush binary not found in $asset"
		return 1
	}

	log "Installing crush ${CRUSH_VERSION} to $BINDIR..."
	install -m 0755 -o root -g wheel "$extracted/crush" \
		"$BINDIR/crush" || return 1

	if [ -f "$extracted/manpages/crush.1.gz" ]; then
		mkdir -p "$MANDIR" || return 1
		install -m 0644 -o root -g wheel \
			"$extracted/manpages/crush.1.gz" \
			"$MANDIR/crush.1.gz" || return 1
	fi

	if [ -f "$extracted/LICENSE.md" ]; then
		mkdir -p "$DOCDIR" || return 1
		install -m 0644 -o root -g wheel \
			"$extracted/LICENSE.md" \
			"$DOCDIR/LICENSE.md" || return 1
	fi

	return 0
}

installed_version() {
	[ -x "$BINDIR/crush" ] || return 0
	"$BINDIR/crush" --version 2>/dev/null |
		grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

###################
# Main            #
###################
BINDIR=/usr/local/bin
MANDIR=/usr/local/man/man1
DOCDIR=/usr/local/share/doc/crush

check_root
CRUSH_USER=${1:-root}

if [ "${CRUSH_USER#-}" != "$CRUSH_USER" ]; then
	usage
fi

if [ "$(uname -s)" != "OpenBSD" ]; then
	error "This script is intended for OpenBSD."
	exit 1
fi

tmpdir=$(mktemp -d /tmp/crush-update.XXXXXX) || {
	error "Cannot create temporary directory."
	exit 1
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

log "Fetching latest crush release info..."
fetch_url \
	"https://api.github.com/repos/charmbracelet/crush/releases/latest" \
	"$tmpdir/release.json" || {
	error "Cannot reach GitHub API."
	exit 1
}

CRUSH_VERSION=$(sed -n -E \
	's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/p' \
	"$tmpdir/release.json" | head -n 1)
[ -n "$CRUSH_VERSION" ] || {
	error "Cannot determine latest crush version."
	exit 1
}

current_version=$(installed_version || true)

if [ -z "$current_version" ]; then
	log "crush is not installed; installing $CRUSH_VERSION..."
	install_crush || exit 1
elif [ "$current_version" != "$CRUSH_VERSION" ]; then
	log "crush $current_version is outdated;" \
		" updating to $CRUSH_VERSION..."
	install_crush || exit 1
elif [ "${CRUSH_FORCE:-0}" = "1" ]; then
	log "Forcing reinstall of crush $CRUSH_VERSION..."
	install_crush || exit 1
else
	log "crush $CRUSH_VERSION is already up to date."
fi

configure_deepseek || exit 1

log "Done. Run 'crush' as $CRUSH_USER to start using" \
	" DeepSeek."
