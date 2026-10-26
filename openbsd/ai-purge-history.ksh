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
# Run this as the user whose history should be removed. It needs write access
# to the configured paths, not root; the defaults are under that user's home
# and the current project directory.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Tool data directories. Each can be overridden from the environment;
# the defaults follow the tools' own conventions. Crush honors XDG_DATA_HOME
# and falls back to ~/.local/share, while Swival state is tied to the current
# project directory unless SWIVAL_PROJECT_HOME points elsewhere.
CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
CRUSH_DATA_HOME=${CRUSH_GLOBAL_DATA:-"${XDG_DATA_HOME:-$HOME/.local/share}/crush"}
SWIVAL_PROJECT_HOME=${SWIVAL_PROJECT_HOME:-"$PWD"}

# Normalize DRY_RUN from the environment. Any value other than one of the
# truthy spellings below means a real purge, and the --dry-run option can
# still enable it later.
typeset DRY_RUN
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
1 | true | TRUE | yes | YES | on | ON) DRY_RUN=1 ;;
*) DRY_RUN=0 ;;
esac

# Help text. ksh's print builtin is used throughout this tree instead of
# echo because its escape and option handling is predictable.
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

# Parse options before anything is deleted. Unknown options print the usage
# text to stderr and exit with status 2.
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

# Delete every path given as an argument. Missing paths are not an error
# because each tool creates only the files it uses.
#
# In dry-run mode, test -e as well as -L so dangling symlinks are reported.
# A real run uses rm -rf, which removes symlinks themselves rather than
# following them, and the leading -- stops a path starting with "-" from
# being read as an option.
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

# Codex and Copilot: remove session state and logs only. Configuration,
# credentials, and other files in those home directories are left intact.
remove_paths "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
remove_paths "$COPILOT_HOME/session-state" "$COPILOT_HOME/logs"
# Crush keeps all of its state in a single data directory.
remove_paths "$CRUSH_DATA_HOME"
# Swival stores history and state inside the selected project. Remove the
# listed files only; the rest of .swival and the project are preserved.
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
