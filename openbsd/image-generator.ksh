#!/bin/ksh

set -eu

# OpenBSD image generator script
#
# This script downloads official OpenBSD install images and firmware,
# then injects architecture-appropriate firmware into each image to allow
# offline installations on systems without initial network connectivity.
#
# Behavior:
#   - Requires root privileges (UID 0).
#   - Downloads OpenBSD install images for amd64 and arm64.
#   - Downloads official firmware for the specified OpenBSD release.
#   - Creates two separate installer images:
#       * amd64 image with amd64-relevant firmware
#       * arm64 image with arm64-relevant firmware
#
# Notes:
#   - Firmware is copied into the install image but is only usable
#     after the first boot of the installed system (OpenBSD behavior).
#   - Images remain official and unmodified except for added firmware.
#
# See the OpenBSD FAQ and fw_update(8) for details.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Basic PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Configuration
typeset VERSION1 VERSION2 WORKDIR FW_DIR MOUNTPOINT
VERSION1="78"
VERSION2="7.8"
WORKDIR="/tmp/openbsd-image"
FW_DIR="$WORKDIR/firmware"
MOUNTPOINT="$WORKDIR/mnt"

typeset AMD64_BASE ARM64_BASE FW_BASE
AMD64_BASE="https://cdn.openbsd.org/pub/OpenBSD/${VERSION2}/amd64"
ARM64_BASE="https://cdn.openbsd.org/pub/OpenBSD/${VERSION2}/arm64"
FW_BASE="https://firmware.openbsd.org/firmware/${VERSION2}/"

typeset AMD64_IMG ARM64_IMG
AMD64_IMG="install${VERSION1}-amd64.img"
ARM64_IMG="install${VERSION1}-arm64.img"

typeset CURRENT_VND
CURRENT_VND=""

typeset VERIFY STRICT_VERIFY SIGNIFY_PUBKEY_BASE SIGNIFY_PUBKEY_FW
VERIFY="${VERIFY:-1}"
STRICT_VERIFY="${STRICT_VERIFY:-0}"
SIGNIFY_PUBKEY_BASE="${SIGNIFY_PUBKEY_BASE:-/etc/signify/openbsd-${VERSION1}-base.pub}"
SIGNIFY_PUBKEY_FW="${SIGNIFY_PUBKEY_FW:-/etc/signify/openbsd-${VERSION1}-fw.pub}"

# Firmware selection
typeset AMD64_FW ARM64_FW

AMD64_FW="
amd amdsev intel vmm
amdgpu radeondrm inteldrm
iwm iwx iwn ipw iwi
bwfm bwi
athn qwx qwz
mtw mwx
otus uath upgt
uvideo
ice
"

ARM64_FW="
arm64-qcom-dtb
qcpas
bwfm
athn
qwx qwz
mtw mwx
uvideo
"

# Colors and logging
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

log() { print "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${RESET} $*"; }
warn() { print "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${RESET} $*" >&2; }
error() { print "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${RESET} $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

expected_sha256() {
	typeset checksum_file base
	checksum_file="$1"
	base="$2"

	awk -v b="$base" '$1=="SHA256" && $2=="(" b ")" && $3=="=" {print $4}' "$checksum_file" | tail -n 1
}

verify_against_checksum_file() {
	typeset checksum_file f base expected actual
	checksum_file="$1"
	f="$2"
	base=$(basename "$f")

	[ "$VERIFY" = "1" ] || return 0
	[ -f "$checksum_file" ] || return 0

	expected=$(expected_sha256 "$checksum_file" "$base")
	if [ -z "$expected" ]; then
		warn "No SHA256 entry for $base in $(basename "$checksum_file"); skipping verification"
		return 0
	fi

	actual=$(sha256_hash "$f")
	if [ "$actual" != "$expected" ]; then
		error "SHA256 mismatch for $base"
		error "  expected: $expected"
		error "  actual:   $actual"
		return 1
	fi
}

verify_with_signify() {
	typeset pubkey sigfile f sigdir
	pubkey="$1"
	sigfile="$2"
	f="$3"

	[ "$VERIFY" = "1" ] || return 0
	have signify || return 0
	[ -f "$pubkey" ] || return 0
	[ -f "$sigfile" ] || return 0

	sigdir=$(dirname "$sigfile")
	(cd "$sigdir" && signify -Cp "$pubkey" -x "$(basename "$sigfile")" "$(basename "$f")" >/dev/null 2>&1)
}

sha256_hash() {
	typeset f
	f="$1"

	if have sha256; then
		sha256 -q "$f"
	elif have sha256sum; then
		sha256sum "$f" | awk '{print $1}'
	elif have openssl; then
		openssl dgst -sha256 "$f" | awk '{print $NF}'
	else
		error "Need sha256(1), sha256sum(1), or openssl(1) to checksum: $f"
		exit 1
	fi
}

verify_firmware_checksum() {
	typeset f base expected actual
	f="$1"
	base=$(basename "$f")

	[ "$VERIFY" = "1" ] || return 0
	[ -f "$FW_DIR/SHA256.sig" ] || return 0

	expected=$(expected_sha256 "$FW_DIR/SHA256.sig" "$base")
	if [ -z "$expected" ]; then
		warn "No SHA256 entry for $base in SHA256.sig; skipping verification"
		return 0
	fi

	actual=$(sha256_hash "$f")
	if [ "$actual" != "$expected" ]; then
		error "SHA256 mismatch for $base"
		error "  expected: $expected"
		error "  actual:   $actual"
		return 1
	fi
}

verify_image_artifacts() {
	typeset arch base_url verify_dir img_name local_img
	arch="$1"
	base_url="$2"
	local_img="$3"

	[ "$VERIFY" = "1" ] || return 0

	verify_dir="$WORKDIR/verify/${arch}"
	mkdir -p "$verify_dir"
	img_name="install${VERSION1}.img"

	# Keep the downloaded image name distinct, but verify against upstream filenames.
	ln -sf "../../$(basename "$local_img")" "$verify_dir/$img_name"

	if ! fetch_to "$base_url/SHA256" "$verify_dir/SHA256" 2>/dev/null; then
		warn "Could not download SHA256 for ${arch}; image checksums will not be verified"
		[ "$STRICT_VERIFY" = "1" ] && return 1 || return 0
	fi
	if ! fetch_to "$base_url/SHA256.sig" "$verify_dir/SHA256.sig" 2>/dev/null; then
		warn "Could not download SHA256.sig for ${arch}; signify verification may be unavailable"
		[ "$STRICT_VERIFY" = "1" ] && return 1 || true
	fi

	verify_against_checksum_file "$verify_dir/SHA256" "$verify_dir/$img_name" || return 1

	if verify_with_signify "$SIGNIFY_PUBKEY_BASE" "$verify_dir/SHA256.sig" "$verify_dir/$img_name"; then
		log "signify verified: ${arch}/${img_name}"
	else
		[ -f "$verify_dir/SHA256.sig" ] && [ -f "$SIGNIFY_PUBKEY_BASE" ] && have signify && {
			warn "signify verification failed for ${arch}/${img_name}"
			[ "$STRICT_VERIFY" = "1" ] && return 1 || true
		}
	fi
}

fetch_to() {
	typeset url out
	url="$1"
	out="$2"

	if have curl; then
		curl -fsSL -o "$out" "$url"
	elif have ftp; then
		ftp -o "$out" "$url"
	else
		error "Need either curl(1) or ftp(1) to download: $url"
		exit 1
	fi
}

fetch_to_cwd() {
	typeset url filename
	url="$1"
	filename="${url##*/}"
	fetch_to "$url" "$filename"
}

cleanup() {
	# Best-effort cleanup; avoid masking the original error.
	if mount | grep -q "on ${MOUNTPOINT} "; then
		umount "$MOUNTPOINT" >/dev/null 2>&1 || true
	fi
	if [ -n "${CURRENT_VND}" ]; then
		vnconfig -u "$CURRENT_VND" >/dev/null 2>&1 || true
		CURRENT_VND=""
	fi
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root."
		exit 1
	fi
}

prepare_dirs() {
	mkdir -p "$WORKDIR" "$FW_DIR" "$MOUNTPOINT"
}

download_images() {
	log "Downloading OpenBSD install images"

	if [ ! -f "$WORKDIR/$AMD64_IMG" ]; then
		log "Downloading amd64 install image"
		fetch_to "$AMD64_BASE/install${VERSION1}.img" "$WORKDIR/$AMD64_IMG"
	else
		log "amd64 image already exists, skipping"
	fi

	if [ ! -f "$WORKDIR/$ARM64_IMG" ]; then
		log "Downloading arm64 install image"
		fetch_to "$ARM64_BASE/install${VERSION1}.img" "$WORKDIR/$ARM64_IMG"
	else
		log "arm64 image already exists, skipping"
	fi

	verify_image_artifacts "amd64" "$AMD64_BASE" "$WORKDIR/$AMD64_IMG" || {
		if [ "$STRICT_VERIFY" = "1" ]; then exit 1; fi
		warn "Image verification failed for amd64 (continuing)"
	}
	verify_image_artifacts "arm64" "$ARM64_BASE" "$WORKDIR/$ARM64_IMG" || {
		if [ "$STRICT_VERIFY" = "1" ]; then exit 1; fi
		warn "Image verification failed for arm64 (continuing)"
	}
}

fetch_firmware_list() {
	log "Fetching firmware index"
	cd "$FW_DIR"

	# firmware snapshots provides a stable index.txt; prefer it over scraping HTML.
	if fetch_to "$FW_BASE/index.txt" firmware.list 2>/dev/null; then
		:
	else
		warn "index.txt not available; falling back to HTML parsing"
		fetch_to "$FW_BASE/" firmware.index.html
		sed -nE 's/.*href="([^"]+\.tgz)".*/\1/p' firmware.index.html >firmware.list
		rm -f firmware.index.html
	fi

	# Best-effort download of checksum signature list.
	if ! fetch_to "$FW_BASE/SHA256.sig" SHA256.sig 2>/dev/null; then
		warn "Could not download SHA256.sig; firmware checksums will not be verified"
		rm -f SHA256.sig >/dev/null 2>&1 || true
	fi
}

verify_firmware_set_files() {
	typeset fwset fw file
	fwset="$1"

	[ "$VERIFY" = "1" ] || return 0

	for fw in $fwset; do
		for file in "$FW_DIR"/"${fw}"-firmware-*.tgz; do
			[ -f "$file" ] || continue
			verify_firmware_checksum "$file" || {
				if [ "$STRICT_VERIFY" = "1" ]; then
					exit 1
				fi
				warn "Checksum verification failed for $(basename "$file") (continuing)"
			}
			if verify_with_signify "$SIGNIFY_PUBKEY_FW" "$FW_DIR/SHA256.sig" "$file"; then
				log "signify verified: $(basename "$file")"
			else
				[ -f "$FW_DIR/SHA256.sig" ] && [ -f "$SIGNIFY_PUBKEY_FW" ] && have signify && {
					warn "signify verification failed for $(basename "$file")"
					[ "$STRICT_VERIFY" = "1" ] && exit 1 || true
				}
			fi
		done
	done
}

download_firmware_set() {
	typeset fwset file
	fwset="$1"

	if have fw_update; then
		log "Downloading firmware via fw_update -Fv"
		typeset fw
		typeset -i rc
		rc=0
		for fw in $fwset; do
			if ! (cd "$FW_DIR" && fw_update -Fv "$fw"); then
				rc=1
				break
			fi
		done

		if [ "$rc" -eq 0 ]; then
			verify_firmware_set_files "$fwset"
			return 0
		fi

		if [ "$STRICT_VERIFY" = "1" ]; then
			exit 1
		fi
		warn "fw_update failed; falling back to manual download"
	fi

	if [ ! -f "$FW_DIR/firmware.list" ]; then
		fetch_firmware_list
	fi

	for fw in $fwset; do
		# Choose the last match in case multiple VERSION1s are listed.
		file=$(grep "^${fw}-firmware-.*\.tgz$" firmware.list | tail -n 1 || true)
		[ -n "$file" ] || continue

		if [ ! -f "$file" ]; then
			log "Downloading firmware: $file"
			fetch_to_cwd "$FW_BASE/$file"
			verify_firmware_checksum "$FW_DIR/$file" || {
				if [ "$STRICT_VERIFY" = "1" ]; then
					exit 1
				fi
				warn "Checksum verification failed for $file (continuing)"
			}
			if verify_with_signify "$SIGNIFY_PUBKEY_FW" "$FW_DIR/SHA256.sig" "$FW_DIR/$file"; then
				log "signify verified: $file"
			else
				[ -f "$FW_DIR/SHA256.sig" ] && [ -f "$SIGNIFY_PUBKEY_FW" ] && have signify && {
					warn "signify verification failed for $file"
					[ "$STRICT_VERIFY" = "1" ] && exit 1 || true
				}
			fi
		fi
	done
}

inject_firmware() {
	typeset img fwset vnd file dest_dir
	img="$1"
	fwset="$2"

	log "Attaching image: $img"
	vnd=$(vnconfig "$img" | awk '{sub(/:$/,"",$1); print $1; exit}')
	CURRENT_VND="$vnd"
	mount "/dev/${vnd}a" "$MOUNTPOINT"

	# Do not extract firmware into the image. Copy the compressed firmware
	# archives so fw_update(8) can be pointed at them later.
	dest_dir="$MOUNTPOINT/firmware"
	mkdir -p "$dest_dir"

	if [ -f "$FW_DIR/SHA256.sig" ]; then
		cp -p "$FW_DIR/SHA256.sig" "$dest_dir/"
	fi

	for fw in $fwset; do
		for file in "$FW_DIR"/"${fw}"-firmware-*.tgz; do
			[ -f "$file" ] || continue
			log "Copying $(basename "$file") into image"
			cp -p "$file" "$dest_dir/"
		done
	done

	sync
	umount "$MOUNTPOINT"
	vnconfig -u "$vnd"
	CURRENT_VND=""
}

main() {
	log "----------------------------------------"
	log "OpenBSD image generator started"

	trap 'cleanup' EXIT INT TERM

	require_root
	prepare_dirs
	download_images
	if have fw_update; then
		log "fw_update detected; skipping manual firmware index fetch"
	else
		fetch_firmware_list
	fi

	log "Downloading amd64 firmware"
	download_firmware_set "$AMD64_FW"

	log "Downloading arm64 firmware"
	download_firmware_set "$ARM64_FW"

	log "Injecting firmware into amd64 image"
	inject_firmware "$WORKDIR/$AMD64_IMG" "$AMD64_FW"

	log "Injecting firmware into arm64 image"
	inject_firmware "$WORKDIR/$ARM64_IMG" "$ARM64_FW"

	log "Installer images ready:"
	log " -> $WORKDIR/$AMD64_IMG"
	log " -> $WORKDIR/$ARM64_IMG"

	log "OpenBSD image generation finished"
	log "----------------------------------------"
}

main "$@"
