#!/usr/bin/env bash

set -euo pipefail

# AI assistant history cleanup for Debian.
# - Removes session history for Codex and GitHub Copilot.
# - Removes OpenCode prompt history, database files and logs.
# - Removes Crush data and project-local Swival history/state.
# - Keeps configuration files and credentials intact.
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

rm -rf -- "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
rm -rf -- "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
rm -rf -- \
	"$OPENCODE_STATE_HOME/prompt-history.jsonl" \
	"$OPENCODE_DATA_HOME/opencode.db" \
	"$OPENCODE_DATA_HOME/opencode.db-wal" \
	"$OPENCODE_DATA_HOME/opencode.db-shm" \
	"$OPENCODE_DATA_HOME/log"
rm -rf -- "$CRUSH_DATA_HOME"
rm -rf -- \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md" \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md.lock" \
	"$SWIVAL_PROJECT_HOME/.swival/continue.md" \
	"$SWIVAL_PROJECT_HOME/.swival/repl_history" \
	"$SWIVAL_PROJECT_HOME/.swival/memory" \
	"$SWIVAL_PROJECT_HOME/.swival/cache.db" \
	"$SWIVAL_PROJECT_HOME/.swival/audit"

printf '%s\n' "AI assistant history purged for Debian"
