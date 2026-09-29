#!/bin/sh
set -eu

# validate-windows-installer.sh
# - Static safety checks for install-windows.bat, windows/launcher.cmd and
#   the perl/programs.txt manifest. Batch cannot run on POSIX systems, so
#   this checks the properties that matter: no elevation, no system PATH
#   writes, no shell download/exec, CRLF batch files, exit-status
#   propagation and a single program manifest shared with the Makefile.
# - Usage: ./validate-windows-installer.sh [ROOT_DIR]
# - Exit status: 0 when everything is fine, 1 otherwise.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [ROOT_DIR]" >&2
	exit 2
}

ROOT_DIR=${1:-.}
case "$ROOT_DIR" in
-*) usage ;;
esac
[ -d "$ROOT_DIR" ] || {
	printf '%s\n' "[ERROR] not a directory: $ROOT_DIR" >&2
	exit 2
}

INSTALLER="$ROOT_DIR/install-windows.bat"
LAUNCHER="$ROOT_DIR/windows/launcher.cmd"
MANIFEST="$ROOT_DIR/perl/programs.txt"
MAKEFILE="$ROOT_DIR/Makefile"

fail=0

note_fail() {
	printf '%s\n' "[ERROR] $1" >&2
	fail=1
}

require() {
	# require FILE PATTERN MESSAGE
	[ -f "$1" ] || {
		note_fail "missing file: $1"
		return
	}
	grep -Fq -- "$2" "$1" || note_fail "$3"
}

forbid() {
	# forbid FILE PATTERN MESSAGE (case-insensitive)
	[ -f "$1" ] || {
		note_fail "missing file: $1"
		return
	}
	if grep -Fiq -- "$2" "$1"; then
		note_fail "$3"
	fi
}

require_crlf() {
	# Batch files are executed by cmd.exe; CRLF avoids any label/offset
	# surprise with goto and parenthesised blocks.
	[ -f "$1" ] || {
		note_fail "missing file: $1"
		return
	}
	if LC_ALL=C grep -q "$(printf '\r')" "$1"; then
		:
	else
		note_fail "$1 should use CRLF line endings"
	fi
}

# ---------------------------------------------------------------- installer
require "$INSTALLER" '%~dp0' \
	"install-windows.bat must resolve files relative to %~dp0"
require "$INSTALLER" 'perl\programs.txt' \
	"install-windows.bat must read the perl/programs.txt manifest"
require "$INSTALLER" 'windows\launcher.cmd' \
	"install-windows.bat must use the launcher template"
require "$INSTALLER" 'StrawberryPerl.StrawberryPerl' \
	"install-windows.bat must install Strawberry Perl via winget"
require "$INSTALLER" '--exact' \
	"winget install must use --exact"
require "$INSTALLER" '--accept-package-agreements' \
	"winget install must accept package agreements non-interactively"
require "$INSTALLER" '--accept-source-agreements' \
	"winget install must accept source agreements non-interactively"
require "$INSTALLER" '--silent' \
	"winget install should be silent"
require "$INSTALLER" 'where winget' \
	"install-windows.bat must check for winget before using it"
require "$INSTALLER" 'DisableDelayedExpansion' \
	"install-windows.bat must avoid global delayed expansion"
require "$INSTALLER" 'CurrentUser' \
	"user PATH must be updated through HKCU (CurrentUser)"
require "$INSTALLER" '--dry-run' \
	"install-windows.bat must support --dry-run"
require "$INSTALLER" '--no-path' \
	"install-windows.bat must support --no-path"
require "$INSTALLER" '--install-dir' \
	"install-windows.bat must support --install-dir"
require "$INSTALLER" '--version' \
	"install-windows.bat must verify installed launchers"
require "$INSTALLER" 'installed-files.txt' \
	"install-windows.bat must keep an installed-files manifest"

forbid "$INSTALLER" 'setx' \
	"do not use setx to modify PATH"
forbid "$INSTALLER" 'runas' \
	"do not elevate privileges automatically"
forbid "$INSTALLER" 'Start-Process' \
	"do not launch elevated processes"
forbid "$INSTALLER" 'Invoke-Expression' \
	"do not evaluate remote or dynamic content"
forbid "$INSTALLER" 'iex' \
	"do not evaluate dynamic content"
forbid "$INSTALLER" 'curl' \
	"do not download arbitrary content"
forbid "$INSTALLER" 'wget' \
	"do not download arbitrary content"
forbid "$INSTALLER" 'choco' \
	"winget is the only package manager used"
forbid "$INSTALLER" 'scoop' \
	"winget is the only package manager used"
forbid "$INSTALLER" 'wsl' \
	"do not depend on WSL"
forbid "$INSTALLER" 'cygwin' \
	"do not depend on Cygwin"
forbid "$INSTALLER" 'msys' \
	"do not depend on MSYS2"
forbid "$INSTALLER" 'ExecutionPolicy' \
	"do not change the PowerShell execution policy"
forbid "$INSTALLER" 'HKLM' \
	"do not write to the system registry hive"
forbid "$INSTALLER" 'HKEY_LOCAL_MACHINE' \
	"do not write to the system registry hive"
forbid "$INSTALLER" '--force' \
	"do not force winget reinstalls"

# ------------------------------------------------------------------ launcher
require "$LAUNCHER" '%~dp0' \
	"launcher.cmd must resolve its own directory"
require "$LAUNCHER" 'perl-path.txt' \
	"launcher.cmd must use the recorded Perl interpreter"
require "$LAUNCHER" '%~n0.pl' \
	"launcher.cmd must derive the program from its own name"
require "$LAUNCHER" '%*' \
	"launcher.cmd must forward all arguments"
require "$LAUNCHER" 'exit /b %ERRORLEVEL%' \
	"launcher.cmd must preserve the Perl exit status"
require "$LAUNCHER" 'DisableDelayedExpansion' \
	"launcher.cmd must not corrupt paths containing exclamation marks"
forbid "$LAUNCHER" 'Invoke-Expression' \
	"launcher.cmd must not evaluate dynamic content"
forbid "$LAUNCHER" 'setx' \
	"launcher.cmd must not modify PATH"

# ------------------------------------------------------------ line endings
require_crlf "$INSTALLER"
require_crlf "$LAUNCHER"

# ---------------------------------------------------------------- manifest
if [ ! -f "$MANIFEST" ]; then
	note_fail "missing manifest: $MANIFEST"
else
	if ! grep -Eq '^[A-Za-z0-9._-]+\.pl$' "$MANIFEST"; then
		note_fail "$MANIFEST must list at least one .pl program"
	fi
	while IFS= read -r line; do
		case "$line" in
		'' | '#'*) continue ;;
		esac
		case "$line" in
		*/* | *\\* | *' '*)
			note_fail "invalid manifest entry: $line"
			continue
			;;
		esac
		if [ ! -f "$ROOT_DIR/perl/$line" ]; then
			note_fail "manifest lists a missing program: perl/$line"
		fi
	done <"$MANIFEST"
fi

require "$MAKEFILE" 'programs.txt' \
	"Makefile must use perl/programs.txt as the program list"

if [ "$fail" -eq 0 ]; then
	printf '%s\n' "[INFO] Windows installer checks passed"
fi
exit "$fail"
