#!/usr/bin/env bash

set -euo pipefail

# AI assistant history cleanup for SecureBlue.
# - Removes session history for Codex and GitHub Copilot.
# - Removes OpenCode prompt history, database files and logs.
# - Removes Crush data and project-local Swival history/state.
# - Keeps configuration files and credentials intact.
# - Supports --dry-run/-n or DRY_RUN=1 to preview without deleting.
#
# Set SWIVAL_PROJECT_HOME to select the project whose .swival state is purged.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
OPENCODE_STATE_HOME=${OPENCODE_STATE_HOME:-"${XDG_STATE_HOME:-$HOME/.local/state}/opencode"}
OPENCODE_DATA_HOME=${OPENCODE_DATA_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/opencode"}
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

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

remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
remove_paths \
	"$OPENCODE_STATE_HOME/prompt-history.jsonl" \
	"$OPENCODE_DATA_HOME/opencode.db" \
	"$OPENCODE_DATA_HOME/opencode.db-wal" \
	"$OPENCODE_DATA_HOME/opencode.db-shm" \
	"$OPENCODE_DATA_HOME/log"
remove_paths "$CRUSH_DATA_HOME"
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
