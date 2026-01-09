#!/bin/bash
set -euo pipefail

# Download audio from YouTube and convert it to OGG Vorbis
# - Downloads the best quality audio using yt-dlp
# - Converts audio to OGG Vorbis with FFmpeg
# - Saves the file with the video title:
#     * lowercase
#     * spaces replaced with underscores
#     * special characters removed
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# ---------- Config ----------

# Temporary directory for downloads
TMP_DIR="$(mktemp -d)"

# Color setup
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

# ---------- Logging functions ----------

log() { printf '%s %b[INFO]%b ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$GREEN" "$RESET" "$*"; }
warn() { printf '%s %b[WARN]%b ⚠️ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$YELLOW" "$RESET" "$*"; }
error() { printf '%s %b[ERROR]%b ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RED" "$RESET" "$*" >&2; }

# ---------- Utility functions ----------

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "Missing required command: $1"
		exit 1
	fi
}

cleanup() {
	# Remove temporary directory if it exists
	if [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
}
trap cleanup EXIT

sanitize_filename() {
	# Convert to lowercase, replace spaces with underscores, remove special chars
	local name="$1"
	name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
	name=$(echo "$name" | sed 's/ /_/g' | sed 's/[^a-z0-9._-]//g')
	printf '%s\n' "$name"
}

# ---------- Main ----------

main() {
	if [ $# -lt 1 ]; then
		echo "Usage: $0 YOUTUBE_VIDEO_URL"
		exit 1
	fi

	URL="$1"

	require_cmd yt-dlp
	require_cmd ffmpeg

	log "Downloading audio from YouTube..."
	# Download best audio only
	yt-dlp -x --audio-format best -o "$TMP_DIR/%(title)s.%(ext)s" "$URL"

	# Find the first regular file in TMP_DIR robustly (handles spaces/newlines)
	shopt -s nullglob
	files=("$TMP_DIR"/*)
	if [ ${#files[@]} -eq 0 ]; then
		error "Failed to download audio."
		exit 1
	fi

	INPUT="${files[0]}"
	AUDIO_FILE="$(basename "$INPUT")"
	SANITIZED_TITLE=$(sanitize_filename "$AUDIO_FILE")
	OUTPUT="${SANITIZED_TITLE%.*}.ogg"

	log "Converting to OGG Vorbis..."
	ffmpeg -i "$INPUT" -c:a libvorbis -q:a 6 "$OUTPUT"

	log "File saved as $OUTPUT"
}

main "$@"
