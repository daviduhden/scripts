#!/usr/bin/env bash

set -euo pipefail

# AI assistant history cleanup for SecureBlue.
#
# Removes conversation and session state for Codex, GitHub Copilot, Claude Code, OpenCode,
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
CLAUDE_HOME=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
# OpenCode prompt history is separate from its session and credential database.
OPENCODE_STATE_HOME=${OPENCODE_STATE_HOME:-"${XDG_STATE_HOME:-$HOME/.local/state}/opencode"}
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
INCLUDE_CRUSH=0
SELECTED=''
SELECT_ALL=0

usage() {
	cat <<'EOF'
Usage: ai-purge-history.bash [--dry-run|-n] [--include-crush-data] [--help]

Select one or more agents. Without selectors, the default agents are selected.
OpenCode sessions are scoped to the current project on OpenCode 2.

  --codex --copilot-cli --claude --opencode --swival
  --crush               Select Crush (requires --include-crush-data)
  --all                 Select the default agents

  --dry-run, -n          Show the paths that would be removed, delete nothing
  --include-crush-data   Also remove the whole Crush data directory
  --help, -h             Show this help
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n) DRY_RUN=1 ;;
	--include-crush-data) INCLUDE_CRUSH=1 ;;
	--all) SELECT_ALL=1 ;;
	--codex | --copilot-cli | --copilot | --claude | --opencode | --crush | --swival)
		agent=${1#--}
		[ "$agent" != copilot-cli ] || agent=copilot
		SELECTED="$SELECTED $agent"
		;;
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

selected() {
	case " $SELECTED " in
	*" $1 "*) return 0 ;;
	*) return 1 ;;
	esac
}

if [ "$SELECT_ALL" -eq 1 ] && [ -n "$SELECTED" ]; then
	printf '%s\n' '[ERROR] --all cannot be combined with agent selectors.' >&2
	exit 2
fi
EXPLICIT_SELECTION=0
if [ -n "$SELECTED" ]; then
	EXPLICIT_SELECTION=1
else
	SELECTED='codex copilot claude opencode swival'
	if [ "$INCLUDE_CRUSH" -eq 1 ]; then SELECTED="$SELECTED crush"; fi
fi
if selected crush && [ "$INCLUDE_CRUSH" -ne 1 ]; then
	printf '%s\n' '[ERROR] --crush requires --include-crush-data (removes the entire Crush data directory).' >&2
	exit 2
fi
if [ "$INCLUDE_CRUSH" -eq 1 ] && ! selected crush; then
	printf '%s\n' '[ERROR] Select --crush to use --include-crush-data with individual selectors.' >&2
	exit 2
fi

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

	# Real deletions ignore missing paths, so tools that were never used do
	# not fail the run. The dry-run branch reports only existing entries and
	# also matches dangling symlinks via -L.
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

# OpenCode can store credentials alongside sessions. Delete sessions through
# the CLI and validate each complete page of IDs before issuing deletions.
# Sort the IDs so a repeated page signals lack of progress regardless of order.
purge_opencode_history() {
	typeset batch ids previous='' session_id
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '%s\n' '[DRY-RUN] would delete OpenCode sessions through the CLI if available.'
	elif ! command -v opencode >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' '[WARN] OpenCode session cleanup requires opencode and jq.' >&2
		[ "$EXPLICIT_SELECTION" -eq 0 ] || return 1
	else
		while :; do
			if ! batch=$(command opencode session list --max-count 100 --format json 2>/dev/null); then
				printf '%s\n' '[ERROR] OpenCode could not list sessions.' >&2
				return 1
			fi
			# OpenCode 1 may produce no output when no sessions remain.
			[ -n "$batch" ] || break
			if ! ids=$(printf '%s\n' "$batch" | jq -sr '
				if length == 1 and (.[0] | type == "array"
					and all(.[]; type == "object" and (.id | type == "string" and test("^ses_[a-zA-Z0-9]+$")))
					and (map(.id) | length == (unique | length)))
				then .[0] | sort_by(.id) | .[].id else error("invalid session list") end
			' 2>/dev/null); then
				printf '%s\n' '[ERROR] OpenCode returned an invalid session list.' >&2
				return 1
			fi
			[ -n "$ids" ] || break
			if [ "$ids" = "$previous" ]; then
				printf '%s\n' '[ERROR] OpenCode session deletion made no progress.' >&2
				return 1
			fi
			previous=$ids
			while IFS= read -r session_id; do
				if ! command opencode session delete "$session_id" >/dev/null 2>&1; then
					printf '%s\n' '[ERROR] OpenCode could not delete a session.' >&2
					return 1
				fi
			done <<EOF
$ids
EOF
		done
	fi
	remove_history_files "$OPENCODE_STATE_HOME/prompt-history.jsonl"
}

if selected opencode; then purge_opencode_history; fi
if selected claude; then purge_claude_history; fi
if selected codex; then
	remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
fi
if selected copilot; then
	remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
fi
if selected crush; then remove_paths "$CRUSH_DATA_HOME"; fi
if selected swival; then
	remove_paths \
		"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md" \
		"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md.lock" \
		"$SWIVAL_PROJECT_HOME/.swival/continue.md" \
		"$SWIVAL_PROJECT_HOME/.swival/repl_history" \
		"$SWIVAL_PROJECT_HOME/.swival/memory" \
		"$SWIVAL_PROJECT_HOME/.swival/cache.db" \
		"$SWIVAL_PROJECT_HOME/.swival/audit"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	printf '%s\n' "Dry run complete; no files were removed."
else
	printf '%s\n' "AI assistant history purged for SecureBlue"
fi
