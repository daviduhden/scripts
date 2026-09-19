#!/bin/ksh

set -eu

# AI assistant history cleanup for OpenBSD.
# - Removes session history for Codex and GitHub Copilot.
# - Removes Crush data and project-local Swival history/state.
# - Deliberately does not handle OpenCode on OpenBSD.
# - Keeps configuration files and credentials intact.
#
# Set SWIVAL_PROJECT_HOME to select the project whose .swival state is purged.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

rm -rf -- "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
rm -rf -- "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
rm -rf -- "$CRUSH_DATA_HOME"
rm -rf -- \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md" \
	"$SWIVAL_PROJECT_HOME/.swival/HISTORY.md.lock" \
	"$SWIVAL_PROJECT_HOME/.swival/continue.md" \
	"$SWIVAL_PROJECT_HOME/.swival/repl_history" \
	"$SWIVAL_PROJECT_HOME/.swival/memory" \
	"$SWIVAL_PROJECT_HOME/.swival/cache.db" \
	"$SWIVAL_PROJECT_HOME/.swival/audit"

printf '%s\n' "AI assistant history purged for OpenBSD"
