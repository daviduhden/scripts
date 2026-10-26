#!/usr/bin/env bash

set -euo pipefail

# AI assistant history cleanup for SecureBlue.
#
# Removes conversation and session state for Codex, GitHub Copilot, OpenCode,
# Crush, and the Swival project selected by SWIVAL_PROJECT_HOME. Configuration
# files and credentials are intentionally left in place.
#
# Run this as the desktop user whose history should be purged: the paths are
# resolved from that user's HOME and XDG directories, and the script performs
# no elevation. Each tool's own environment variable overrides the defaults
# below, matching where the tools themselves store their state.
#
# Supports --dry-run/-n or DRY_RUN=1 to print the paths that would be removed
# without deleting anything.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Codex and Copilot keep their state in fixed per-user directories.
CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
# OpenCode splits prompt history (state) from its database and logs (data).
OPENCODE_STATE_HOME=${OPENCODE_STATE_HOME:-"${XDG_STATE_HOME:-$HOME/.local/state}/opencode"}
OPENCODE_DATA_HOME=${OPENCODE_DATA_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/opencode"}
# Crush exposes its data directory as CRUSH_GLOBAL_DATA.
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
# Swival state is project-local; default to the current working directory.
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

# Accept the common true-like spellings for the environment variable, but
# treat any other value as false rather than failing.
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac

usage() {
	cat <<'EOF'
Usage: ai-purge-history.bash [--dry-run|-n] [--help]

Removes Codex, Copilot, OpenCode, Crush, and project-local Swival
history/state for the current user. Configuration and credentials are kept.

  --dry-run, -n  Show the paths that would be removed, delete nothing
  --help, -h     Show this help
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n) DRY_RUN=1 ;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		printf '%s\n' "[ERROR] unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

remove_paths() {
	local path

	# Real deletions ignore missing paths, so tools that were never used do
	# not fail the run. The dry-run branch reports only existing entries and
	# also matches dangling symlinks via -L.
	for path in "$@"; do
		if [ "$DRY_RUN" -eq 1 ]; then
			if [[ -e $path || -L $path ]]; then
				printf '%s\n' "[DRY-RUN] would remove: $path"
			fi
		else
			rm -rf -- "$path"
		fi
	done
}

# Remove only history/state paths; configuration or credential files that sit
# beside them (for example Codex auth files) are not listed here.
remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
# Include the SQLite write-ahead log and shared-memory file so no deleted
# conversation state can be replayed from them.
remove_paths \
	"$OPENCODE_STATE_HOME/prompt-history.jsonl" \
	"$OPENCODE_DATA_HOME/opencode.db" \
	"$OPENCODE_DATA_HOME/opencode.db-wal" \
	"$OPENCODE_DATA_HOME/opencode.db-shm" \
	"$OPENCODE_DATA_HOME/log"
# Crush's data directory is removed as a whole rather than by individual file.
remove_paths "$CRUSH_DATA_HOME"
# Swival state is scoped to the selected project; other projects are untouched.
remove_paths \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md" \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md.lock" \
	"$SWIVAL_PROJECT_HOME/.swival/continue.md" \
	"$SWIVAL_PROJECT_HOME/.swival/repl_history" \
	"$SWIVAL_PROJECT_HOME/.swival/memory" \
	"$SWIVAL_PROJECT_HOME/.swival/cache.db" \
	"$SWIVAL_PROJECT_HOME/.swival/audit"

if [ "$DRY_RUN" -eq 1 ]; then
	printf '%s\n' "Dry run complete; no files were removed."
else
	printf '%s\n' "AI assistant history purged for SecureBlue"
fi
