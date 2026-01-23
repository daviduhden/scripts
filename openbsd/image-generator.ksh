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
typeset COMMON_FW AMD64_FW ARM64_FW

# Common firmware seen in snapshots index.txt (wireless/usb/etc.).
COMMON_FW="
acx malo ogx wpi
iwm iwx iwn ipw iwi
bwfm bwi
athn qwx qwz
mtw mwx
otus uath upgt pgt
uvideo
"

# x86_64/amd64-specific (CPU/GPU/NIC firmware).
AMD64_FW="$COMMON_FW
amd amdsev intel vmm
amdgpu radeondrm inteldrm
ice
"

# arm64-specific (DTBs/SoC blobs).
ARM64_FW="$COMMON_FW
arm64-qcom-dtb
apple-boot
qcpas
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

refresh_disklabel() {
	typeset vnd
	vnd="$1"
	have disklabel || return 1
	# Clear and refresh in-core label from on-disk label.
	disklabel -c "$vnd" >/dev/null 2>&1 || true
	return 0
}

fsck_vnd_a() {
	typeset vnd dev
	vnd="$1"

	have fsck || return 1

	if [ -c "/dev/r${vnd}a" ]; then
		dev="/dev/r${vnd}a"
	else
		dev="/dev/${vnd}a"
	fi

	# Best-effort; do not fail hard if fsck isn't needed.
	fsck -fy "$dev" >/dev/null 2>&1 || true
	return 0
}

mount_vnd_a() {
	typeset vnd mp tmp msg
	vnd="$1"
	mp="$2"

	# If already mounted, nothing to do.
	if mount | grep -q "on ${mp} "; then
		return 0
	fi

	tmp=$(mktemp "${WORKDIR}/mount.XXXXXXXX")
	if mount "/dev/${vnd}a" "$mp" >"$tmp" 2>&1; then
		rm -f "$tmp" >/dev/null 2>&1 || true
		return 0
	fi

	msg=$(sed -n '1,5p' "$tmp" 2>/dev/null || true)
	rm -f "$tmp" >/dev/null 2>&1 || true

	# If mount suggests fsck, try to repair and re-mount.
	if print -r -- "$msg" | grep -qi 'fsck\|read-only'; then
		fsck_vnd_a "$vnd"
		mount "/dev/${vnd}a" "$mp" >/dev/null 2>&1 && return 0
	fi

	return 1
}

expand_disklabel_boundaries() {
	# Some images have an on-disk disklabel with boundaries matching the original
	# image size. After growing the backing file, we must extend the OpenBSD
	# disk boundaries so disklabel partitions (and growfs) can use the new space.
	#
	# disklabel(8) explicitly supports this via the 'b' command in -E mode.
	# This avoids fragile fdisk(8) scripting and CHS prompts.
	typeset vnd tmp
	vnd="$1"

	have disklabel || return 1

	tmp=$(mktemp "${WORKDIR}/disklabel.E.XXXXXXXX")
	# Sequence:
	#   b  -> set OpenBSD disk boundaries
	#   <enter> keep offset
	#   *  -> size to end of disk
	#   w  -> write label
	#   q  -> quit
	if ! printf 'b\n\n*\nw\nq\n' | disklabel -E "$vnd" >"$tmp" 2>&1; then
		if [ "${DEBUG:-0}" = "1" ]; then
			warn "disklabel -E output: $(sed -n '1,120p' "$tmp" 2>/dev/null || true)"
		fi
		rm -f "$tmp" >/dev/null 2>&1 || true
		return 1
	fi
	rm -f "$tmp" >/dev/null 2>&1 || true
	refresh_disklabel "$vnd"
	return 0
}

disklabel_dev_for_vnd() {
	# Prefer raw whole-disk device.
	typeset vnd
	vnd="$1"

	if [ -c "/dev/r${vnd}c" ]; then
		print "/dev/r${vnd}c"
		return 0
	fi
	if [ -c "/dev/${vnd}c" ]; then
		print "/dev/${vnd}c"
		return 0
	fi
	if [ -c "/dev/r${vnd}" ]; then
		print "/dev/r${vnd}"
		return 0
	fi
	print "/dev/${vnd}"
}

expand_disklabel_partition_a() {
	# After enlarging the backing file and re-attaching vnd(4), the filesystem
	# won't grow unless the disklabel partition also grows.
	# This expands partition 'a' to fill the remaining available sectors.
	typeset vnd dl tmp_in tmp_out
	vnd="$1"

	have disklabel || {
		warn "disklabel(8) not available; cannot expand partition for ${vnd}"
		return 1
	}

	# Some images/dev setups expose different nodes; try a few.
	typeset candidates cand use_raw
	candidates="${vnd} /dev/r${vnd}c /dev/${vnd}c /dev/r${vnd}a /dev/${vnd}a /dev/r${vnd} /dev/${vnd}"
	dl=""
	use_raw="1"
	for cand in $candidates; do
		if disklabel -r "$cand" >/dev/null 2>&1; then
			dl="$cand"
			use_raw="1"
			break
		fi
		# Fallback: some environments refuse -r but allow in-core label reads.
		if disklabel "$cand" >/dev/null 2>&1; then
			dl="$cand"
			use_raw="0"
			break
		fi
	done
	if [ -z "$dl" ]; then
		dl=$(disklabel_dev_for_vnd "$vnd")
	fi
	tmp_in=$(mktemp "${WORKDIR}/disklabel.in.XXXXXXXX")
	tmp_out=$(mktemp "${WORKDIR}/disklabel.out.XXXXXXXX")

	# Prefer raw (-r) output, but allow non-raw reads if -r is rejected.
	if [ "$use_raw" = "1" ]; then
		if ! disklabel -r "$dl" >"$tmp_in" 2>/dev/null; then
			use_raw="0"
		fi
	fi
	if [ "$use_raw" = "0" ]; then
		if ! disklabel "$dl" >"$tmp_in" 2>/dev/null; then
			use_raw="1"
		fi
	fi
	if [ ! -s "$tmp_in" ]; then
		if [ "${DEBUG:-0}" = "1" ]; then
			typeset dl_err
			if [ "$use_raw" = "1" ]; then
				dl_err=$(disklabel -r "$dl" 2>&1 || true)
			else
				dl_err=$(disklabel "$dl" 2>&1 || true)
			fi
			warn "disklabel ${dl} failed: ${dl_err}"
		fi
		rm -f "$tmp_in" "$tmp_out" >/dev/null 2>&1 || true
		warn "Could not read disklabel from ${dl}; cannot expand partition"
		return 1
	fi

	# Compute new size from boundend/total sectors.
	# Prefer boundend if present (it reflects usable bounds).
	typeset parsed new_size old_size
	parsed=$(awk '
		$1=="boundend:"{be=$2}
		$1=="total" && $2=="sectors:"{ts=$3}
		/^[[:space:]]*a:[[:space:]]/ {old=$2; off=$3}
		END{
			if (off=="") exit 1;
			end = (be!="" && be>0) ? be : ts;
			if (end=="") exit 1;
			print end - off, old, off
		}
	' "$tmp_in" 2>/dev/null) || true

	if [ -z "$parsed" ]; then
		rm -f "$tmp_in" "$tmp_out" >/dev/null 2>&1 || true
		warn "Could not parse disklabel bounds for ${dl}; cannot expand partition"
		return 1
	fi

	# Split values: "new old off" without word-splitting (ignore off).
	new_size=${parsed%% *}
	parsed=${parsed#* }
	old_size=${parsed%% *}

	# If there's nothing to grow, nothing to do.
	if [ "$new_size" -le "$old_size" ]; then
		rm -f "$tmp_in" "$tmp_out" >/dev/null 2>&1 || true
		return 0
	fi

	# Rewrite only the 'a:' partition size.
	awk -v ns="$new_size" '
		/^[[:space:]]*a:[[:space:]]/ {
			printf "  a: %s %s", ns, $3
			for (i=4; i<=NF; i++) printf " %s", $i
			print ""
			next
		}
		{print}
	' "$tmp_in" >"$tmp_out"

	if ! disklabel -R "$dl" "$tmp_out" >/dev/null 2>&1; then
		rm -f "$tmp_in" "$tmp_out" >/dev/null 2>&1 || true
		warn "disklabel -R failed for ${dl}; cannot expand partition"
		return 1
	fi

	rm -f "$tmp_in" "$tmp_out" >/dev/null 2>&1 || true
	refresh_disklabel "$vnd"
	return 0
}

grow_image_file_mb() {
	typeset img mb
	img="$1"
	mb="$2"

	log "Growing image file by ${mb}MB: $img"
	dd if=/dev/zero bs=1m count="$mb" >>"$img"
}

grow_image_filesystem() {
	typeset vnd
	vnd="$1"

	if have growfs; then
		# Prefer raw device if available.
		if [ -c "/dev/r${vnd}a" ]; then
			growfs -y "/dev/r${vnd}a" >/dev/null
		else
			growfs -y "/dev/${vnd}a" >/dev/null
		fi
	else
		warn "growfs(8) not available; cannot grow filesystem"
		return 1
	fi
}

free_kb_in_mount() {
	typeset path
	path="$1"
	df -k "$path" | awk 'NR==2 {print $4}'
}

ensure_image_space_kb() {
	# Ensures at least required_kb free within the mounted image.
	# May detach/reattach and grow the image+filesystem.
	typeset img required_kb
	typeset -i free_kb prev_free_kb reserve_kb grow_mb max_grow_mb grown_mb
	img="$1"
	required_kb="$2"

	reserve_kb=${IMAGE_RESERVE_KB:-2048}
	grow_mb=${IMAGE_GROW_MB:-256}
	max_grow_mb=${IMAGE_MAX_GROW_MB:-1024}
	grown_mb=0

	# If previous attempts proved the image can't be grown, don't thrash.
	typeset nogrow_flag
	nogrow_flag="$WORKDIR/no-grow.$(basename "$img")"
	if [ -f "$nogrow_flag" ]; then
		return 1
	fi

	free_kb=$(free_kb_in_mount "$MOUNTPOINT")
	while [ $((free_kb - reserve_kb)) -lt "$required_kb" ]; do
		prev_free_kb="$free_kb"
		if [ "$grown_mb" -ge "$max_grow_mb" ]; then
			warn "Reached IMAGE_MAX_GROW_MB=${max_grow_mb}MB; cannot grow further"
			return 1
		fi

		log "Not enough space in image (${free_kb}KB free). Growing..."
		if mount | grep -q "on ${MOUNTPOINT} "; then
			umount "$MOUNTPOINT"
		fi
		if [ -n "${CURRENT_VND}" ]; then
			vnconfig -u "$CURRENT_VND"
			CURRENT_VND=""
		fi

		grow_image_file_mb "$img" "$grow_mb"
		grown_mb=$((grown_mb + grow_mb))

		CURRENT_VND=$(vnconfig "$img" | awk '{sub(/:$/,"",$1); print $1; exit}')
		# Extend disklabel boundaries to new end-of-disk.
		if ! expand_disklabel_boundaries "$CURRENT_VND"; then
			warn "Could not expand disklabel boundaries for ${CURRENT_VND}"
		fi

		# Expand disklabel partition first, then grow the filesystem.
		expand_disklabel_partition_a "$CURRENT_VND" || {
			warn "Partition expansion failed for ${CURRENT_VND}; growfs may not be able to grow"
		}
		# fsck before growfs/mount if needed.
		fsck_vnd_a "$CURRENT_VND"
		# Try to grow the filesystem, but always remount before returning.
		if ! grow_image_filesystem "$CURRENT_VND"; then
			warn "growfs did not grow filesystem for ${CURRENT_VND}a"
		fi
		if ! mount_vnd_a "$CURRENT_VND" "$MOUNTPOINT"; then
			error "Failed to mount /dev/${CURRENT_VND}a on $MOUNTPOINT after growing"
			# Do not leave callers copying into an unmounted directory.
			touch "$nogrow_flag" >/dev/null 2>&1 || true
			return 1
		fi

		free_kb=$(free_kb_in_mount "$MOUNTPOINT")
		log "Free space in image after grow: ${free_kb} KB"

		if [ "$free_kb" -le "$prev_free_kb" ]; then
			warn "Filesystem did not grow (free space unchanged); cannot add more space"
			touch "$nogrow_flag" >/dev/null 2>&1 || true
			return 1
		fi
	done

	return 0
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

	if ! fetch_to "$base_url/SHA256.sig" "$verify_dir/SHA256.sig" 2>/dev/null; then
		warn "Could not download SHA256.sig for ${arch}; signify verification may be unavailable"
		[ "$STRICT_VERIFY" = "1" ] && return 1 || true
	fi

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
	typeset -i need_kb
	img="$1"
	fwset="$2"

	log "Attaching image: $img"
	CURRENT_VND=$(vnconfig "$img" | awk '{sub(/:$/,"",$1); print $1; exit}')
	if ! mount_vnd_a "$CURRENT_VND" "$MOUNTPOINT"; then
		error "Failed to mount /dev/${CURRENT_VND}a on $MOUNTPOINT"
		vnconfig -u "$CURRENT_VND"
		CURRENT_VND=""
		exit 1
	fi

	# Do not extract firmware into the image. Copy the compressed firmware
	# archives so fw_update(8) can be pointed at them later.
	dest_dir="$MOUNTPOINT/firmware"
	mkdir -p "$dest_dir"

	if [ -f "$FW_DIR/SHA256.sig" ]; then
		need_kb=$(du -k "$FW_DIR/SHA256.sig" | awk '{print $1}')
		if ! ensure_image_space_kb "$img" "$need_kb"; then
			warn "Not enough space to copy SHA256.sig into image"
			[ "$STRICT_VERIFY" = "1" ] && exit 1 || true
		else
			mkdir -p "$dest_dir"
			cp -p "$FW_DIR/SHA256.sig" "$dest_dir/"
		fi
	fi

	for fw in $fwset; do
		for file in "$FW_DIR"/"${fw}"-firmware-*.tgz; do
			[ -f "$file" ] || continue
			need_kb=$(du -k "$file" | awk '{print $1}')
			if ! ensure_image_space_kb "$img" "$need_kb"; then
				warn "Not enough space in image for $(basename "$file")"
				[ "$STRICT_VERIFY" = "1" ] && exit 1 || true
				# Safety: never continue if the mount got lost.
				if ! mount | grep -q "on ${MOUNTPOINT} "; then
					error "Image is not mounted; aborting to avoid copying outside the image"
					exit 1
				fi
				continue
			fi
			mkdir -p "$dest_dir"
			log "Copying $(basename "$file") into image"
			cp -p "$file" "$dest_dir/"
		done
	done

	sync
	if mount | grep -q "on ${MOUNTPOINT} "; then
		umount "$MOUNTPOINT"
	fi
	vnconfig -u "$CURRENT_VND"
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
