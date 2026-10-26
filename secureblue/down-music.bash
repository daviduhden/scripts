#!/bin/bash
set -euo pipefail

# Download audio from YouTube and convert it to OGG Vorbis.
#
# - Uses yt-dlp to fetch the best available audio into a temporary directory.
# - Re-encodes the result with FFmpeg at Vorbis quality level 6 and writes
#   <sanitized-title>.ogg into the current working directory. An existing file
#   with the same name is overwritten.
# - Derives the output name from the downloaded file: lowercase, spaces become
#   underscores, and characters outside [a-z0-9._-] are removed.
# - Reads cookies from the invoking desktop user's Trivalent/Chromium profile
#   (needed for age- or membership-restricted videos). The script performs no
#   elevation itself.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# ---------- Config ----------

# One private temporary directory holds the intermediate download until the
# EXIT trap below removes it. The final OGG file is written outside it.
TMP_DIR="$(mktemp -d)"

# ---------- Logging functions ----------

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# ---------- Utility functions ----------

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "Missing required command: $1"
		exit 1
	fi
}

cleanup() {
	# The trap runs on both success and error, so a failed download does not
	# leave partial files behind.
	if [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
}
trap cleanup EXIT

sanitize_filename() {
	# Keep only portable ASCII filename characters. Dots are preserved so the
	# caller can strip the downloaded extension before appending .ogg.
	local name="$1"
	name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
	name=$(echo "$name" | sed 's/ /_/g' | sed 's/[^a-z0-9._-]//g')
	printf '%s\n' "$name"
}

usage() {
	echo "Usage: $0 YOUTUBE_VIDEO_URL"
}

parse_args() {
	if [ $# -lt 1 ]; then
		usage
		exit 1
	fi

	URL="$1"
}

# SecureBlue images may not put Linuxbrew on PATH for non-login shells.
ensure_brew_path() {
	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [ -x "$prefix/bin/brew" ]; then
			export PATH="$prefix/bin:$prefix/sbin:$PATH"
			return
		fi
	done
}

check_prereqs() {
	ensure_brew_path
	require_cmd yt-dlp
	require_cmd ffmpeg
	require_cmd getent
}

# Resolve the desktop user whose browser profile supplies cookies. This works
# when the script is started from a normal shell or through a pkexec-style
# launcher that leaves the original UID in PKEXEC_UID.
detect_runtime_user() {
	# If invoked via policykit-compatible tools, prefer the caller UID.
	if [ -n "${PKEXEC_UID:-}" ]; then
		id -un "$PKEXEC_UID"
		return
	fi

	# logname resolves the terminal owner.
	if logname >/dev/null 2>&1; then
		logname
		return
	fi

	# Fallback to common login/session environment variables.
	if [ -n "${LOGNAME:-}" ] && [ "$LOGNAME" != "root" ]; then
		printf '%s\n' "$LOGNAME"
		return
	fi
	if [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
		printf '%s\n' "$USER"
		return
	fi

	id -un
}

resolve_home_dir() {
	local user="$1" home_dir
	home_dir="$(getent passwd "$user" | cut -d: -f6)"
	if [ -z "$home_dir" ]; then
		error "Failed to resolve home directory for user: $user"
		exit 1
	fi
	printf '%s\n' "$home_dir"
}

# yt-dlp writes one audio file into the otherwise empty temporary directory.
# Fail clearly if it produced nothing, and use the first entry if a
# post-processing step left more than one.
resolve_downloaded_file() {
	shopt -s nullglob
	files=("$TMP_DIR"/*)
	if [ ${#files[@]} -eq 0 ]; then
		error "Failed to download audio."
		exit 1
	fi
	printf '%s\n' "${files[0]}"
}

run_download_and_convert() {
	local input audio_file sanitized_title output
	local runtime_user home_dir cookies_profile

	runtime_user="$(detect_runtime_user)"
	home_dir="$(resolve_home_dir "$runtime_user")"
	# Trivalent is Chromium-derived, so yt-dlp can read cookies from its
	# default profile as long as this user can access the cookie database.
	cookies_profile="${home_dir}/.config/trivalent/Default/"

	log "Downloading audio from YouTube..."
	# Extract the best audio stream; FFmpeg performs the OGG/Vorbis encode.
	yt-dlp -x --audio-format best \
		--cookies-from-browser "chromium:${cookies_profile}" \
		-o "$TMP_DIR/%(title)s.%(ext)s" "$URL"

	input="$(resolve_downloaded_file)"
	audio_file="$(basename "$input")"
	sanitized_title="$(sanitize_filename "$audio_file")"
	output="${sanitized_title%.*}.ogg"

	log "Converting to OGG Vorbis..."
	ffmpeg -y -i "$input" -c:a vorbis -q:a 6 -strict -2 "$output"

	log "File saved as $output"
}

run_update() {
	run_download_and_convert
}

# ---------- Main ----------

main() {
	parse_args "$@"
	check_prereqs
	run_update
}

main "$@"
