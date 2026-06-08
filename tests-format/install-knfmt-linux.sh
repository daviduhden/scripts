#!/bin/sh
set -eu

# install-knfmt-linux.sh
# - Installs or updates knfmt from source on Linux.
# - Usage: ./install-knfmt-linux.sh [PREFIX]
# - Default PREFIX: /usr/local
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' "Usage: $0 [PREFIX]" >&2
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s\n' "[ERROR] $1 not found in PATH" >&2
		exit 1
	}
}

main() {
	PREFIX=${1:-/usr/local}
	[ "${PREFIX#-}" = "$PREFIX" ] || usage
	REPO_URL="https://github.com/mptre/knfmt"

	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	[ "$OS_NAME" = "Linux" ] || {
		printf '%s\n' "[ERROR] This installer only supports Linux (detected: $OS_NAME)" >&2
		exit 1
	}

	require_cmd git
	require_cmd make
	require_cmd cc
	require_cmd mktemp

	if command -v knfmt >/dev/null 2>&1; then
		printf '%s\n' "[INFO] Existing knfmt found at: $(command -v knfmt)"
		printf '%s\n' "[INFO] Proceeding with update from latest upstream source..."
	else
		printf '%s\n' "[INFO] knfmt not found; proceeding with fresh install..."
	fi

	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/knfmt-build-XXXXXX")
	trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

	printf '%s\n' "[INFO] Cloning knfmt source..."
	git clone --depth 1 "$REPO_URL" "$TMP_DIR/knfmt"

	cd "$TMP_DIR/knfmt"
	printf '%s\n' "[INFO] Configuring knfmt with PREFIX=$PREFIX..."
	PREFIX="$PREFIX" ./configure

	printf '%s\n' "[INFO] Building knfmt..."
	if command -v nproc >/dev/null 2>&1; then
		make -j"$(nproc)"
	else
		make
	fi

	printf '%s\n' "[INFO] Installing/updating knfmt..."
	if make install; then
		if command -v knfmt >/dev/null 2>&1; then
			printf '%s\n' "[INFO] knfmt available at: $(command -v knfmt)"
		fi
		printf '%s\n' "[INFO] knfmt install/update completed successfully"
		exit 0
	fi

	printf '%s\n' "[ERROR] Installation failed. Re-run with elevated privileges if needed." >&2
	exit 1
}

main "$@"
