#!/usr/bin/env bash

set -euo pipefail

# AI assistant history cleanup for Debian.
# - Removes session history for Codex, GitHub Copilot, and Claude Code.
# - Removes OpenCode prompt history, database files and logs.
# - Removes Crush data and project-local Swival history/state.
# - Keeps configuration files and credentials intact.
# - Supports --dry-run/-n or DRY_RUN=1 to preview without deleting.
#
# Run this as the user whose data should be removed; it does not
# require root and does not elevate. Deletion is permanent: there is
# no prompt, backup, or trash step.
#
# The history locations can be overridden with CODEX_HOME,
# COPILOT_HOME, CLAUDE_CONFIG_DIR, OPENCODE_STATE_HOME, OPENCODE_DATA_HOME, and
# CRUSH_GLOBAL_DATA, plus the standard XDG variables. Set
# SWIVAL_PROJECT_HOME to select the project whose .swival state is
# purged; it defaults to the current working directory.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
CLAUDE_HOME=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
OPENCODE_STATE_HOME=${OPENCODE_STATE_HOME:-"${XDG_STATE_HOME:-$HOME/.local/state}/opencode"}
OPENCODE_DATA_HOME=${OPENCODE_DATA_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/opencode"}
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

# Accept common true-ish values from the environment; anything else
# means a real run. The --dry-run flag sets this later.
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac
INCLUDE_CRUSH=0

usage() {
	cat <<'EOF'
Usage: ai-purge-history.bash [--dry-run|-n] [--include-crush-data] [--help]

Removes Codex, Copilot, Claude Code, OpenCode, Crush, and project-local Swival
history/state for the current user. Configuration and credentials are kept.

  --dry-run, -n          Show the paths that would be removed, delete nothing
  --include-crush-data   Also remove the whole Crush data directory
  --help, -h             Show this help
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n) DRY_RUN=1 ;;
	--include-crush-data) INCLUDE_CRUSH=1 ;;
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

# Remove each path, or print it in dry-run mode. Missing paths are
# ignored (rm -rf does not fail on them). In dry-run mode, only paths
# that currently exist are listed.
validate_remove_path() {
	local path="$1"
	[[ -n $path && $path == /* ]] || {
		printf '%s\n' "[ERROR] refusing a non-absolute removal path: '$path'" >&2
		return 1
	}
	[[ $path != "/" && $path != "$HOME" && $path != "$HOME/" ]] || {
		printf '%s\n' "[ERROR] refusing to remove a protected path: $path" >&2
		return 1
	}
	case "$path" in
	*/../* | */.. | */./* | */. | *//*)
		printf '%s\n' "[ERROR] refusing an unnormalized removal path: $path" >&2
		return 1
		;;
	esac
	return 0
}

remove_paths() {
	local path

	for path in "$@"; do
		validate_remove_path "$path" || continue
		if [ "$DRY_RUN" -eq 1 ]; then
			if [[ -e $path || -L $path ]]; then
				printf '%s\n' "[DRY-RUN] would remove: $path"
			fi
		else
			rm -rf -- "$path"
		fi
	done
}

# Claude's projects tree also holds auto memory. Select only transcript files.
history_no_symlinks() {
	typeset ancestor="$1"
	validate_remove_path "$ancestor" || return 1
	while [ -n "$ancestor" ]; do
		if [ -L "$ancestor" ]; then
			printf '[ERROR] refusing a history path through a symbolic link: %s\n' "$ancestor" >&2
			return 1
		fi
		ancestor=${ancestor%/*}
	done
}

remove_history_files() {
	typeset path
	for path in "$@"; do
		history_no_symlinks "$path" || return 1
		[ -f "$path" ] || continue
		if [ "$DRY_RUN" -eq 1 ]; then
			printf '[DRY-RUN] would remove: %s\n' "$path"
		else
			rm -f -- "$path" || return 1
		fi
	done
}

purge_claude_history() {
	typeset projects project session subagents
	while [ "${CLAUDE_HOME%/}" != "$CLAUDE_HOME" ]; do
		CLAUDE_HOME=${CLAUDE_HOME%/}
	done
	history_no_symlinks "$CLAUDE_HOME" || return 1
	projects="$CLAUDE_HOME/projects"
	history_no_symlinks "$projects" || return 1
	remove_history_files "$CLAUDE_HOME/history.jsonl" || return 1
	for project in "$projects"/*; do
		[ -L "$project" ] || [ -d "$project" ] || continue
		history_no_symlinks "$project" || return 1
		remove_history_files "$project"/*.jsonl "$project"/*.jsonl.superseded-* || return 1
		for session in "$project"/*; do
			[ "${session##*/}" != memory ] || continue
			[ -L "$session" ] || [ -d "$session" ] || continue
			history_no_symlinks "$session" || return 1
			subagents="$session/subagents"
			history_no_symlinks "$subagents" || return 1
			remove_history_files "$subagents"/*.jsonl || return 1
		done
	done
}

purge_claude_history

# Only session/state paths are listed here; configuration files and
# credentials in the same home directories are intentionally omitted.
remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
remove_paths \
	"$OPENCODE_STATE_HOME/prompt-history.jsonl" \
	"$OPENCODE_DATA_HOME/opencode.db" \
	"$OPENCODE_DATA_HOME/opencode.db-wal" \
	"$OPENCODE_DATA_HOME/opencode.db-shm" \
	"$OPENCODE_DATA_HOME/log"
if [ "$INCLUDE_CRUSH" -eq 1 ]; then
	remove_paths "$CRUSH_DATA_HOME"
else
	printf '%s\n' \
		"[INFO] Preserving Crush data directory (use --include-crush-data to remove it): $CRUSH_DATA_HOME"
fi
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
	printf '%s\n' "AI assistant history purged for Debian"
fi
