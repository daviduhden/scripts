#!/bin/ksh

set -eu

# AI assistant history cleanup for OpenBSD.
# - Removes session history for Codex and GitHub Copilot.
# - Removes Crush data and project-local Swival history/state.
# - Deliberately does not handle OpenCode on OpenBSD.
# - Keeps configuration files and credentials intact.
# - Supports --dry-run/-n or DRY_RUN=1 to preview without deleting.
#
# Set SWIVAL_PROJECT_HOME to select the project whose .swival state is purged.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

typeset DRY_RUN
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac

usage() {
	print "Usage: ai-purge-history.ksh [--dry-run|-n] [--help]"
	print ""
	print "Removes Codex, Copilot, Crush, and project-local Swival"
	print "history/state for the current user. Configuration and"
	print "credentials are kept."
	print ""
	print "  --dry-run, -n  Show the paths that would be removed, delete nothing"
	print "  --help, -h     Show this help"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n) DRY_RUN=1 ;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		print "[ERROR] unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

remove_paths() {
	typeset path

	for path in "$@"; do
		if [ "$DRY_RUN" -eq 1 ]; then
			if [ -e "$path" ] || [ -L "$path" ]; then
				print "[DRY-RUN] would remove: $path"
			fi
		else
			rm -rf -- "$path"
		fi
	done
}

remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
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
	print "Dry run complete; no files were removed."
else
	print "AI assistant history purged for OpenBSD"
fi
