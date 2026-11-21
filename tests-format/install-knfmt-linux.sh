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
	# Exit 0 after a successful install; 1 for an unsupported OS, a missing
	# build tool, or a failed build/install; 2 for usage errors.
	# Optional absolute installation prefix.
	PREFIX=${1:-/usr/local}
	[ "$#" -le 1 ] || usage
	case "$PREFIX" in
	/*) ;;
	*) usage ;;
	esac
	REPO_URL="https://github.com/mptre/knfmt"

	# knfmt's build system and this installer target Linux only. Report the
	# detected OS rather than attempting a partial install elsewhere.
	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	[ "$OS_NAME" = "Linux" ] || {
		printf '%s\n' \
			"[ERROR] This installer only supports Linux" \
			" (detected: $OS_NAME)" >&2
		exit 1
	}

	require_cmd git
	require_cmd make
	require_cmd cc
	require_cmd mktemp
	if [ "$(id -u)" -eq 0 ]; then
		printf '%s\n' '[ERROR] Run knfmt builds as a non-root user.' >&2
		exit 1
	fi

	if command -v knfmt >/dev/null 2>&1; then
		printf '%s\n' "[INFO] Existing knfmt found at: $(command -v knfmt)"
		printf '%s\n' \
			"[INFO] Proceeding with update from latest upstream" \
			" source..."
	else
		printf '%s\n' \
			"[INFO] knfmt not found; proceeding with" \
			" fresh install..."
	fi

	# A fresh shallow clone in a private temporary tree avoids reusing a dirty
	# checkout. The trap removes it on success, failure, and signals.
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/knfmt-build-XXXXXX")
	trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

	printf '%s\n' "[INFO] Cloning knfmt source..."
	git clone --depth 1 "$REPO_URL" "$TMP_DIR/knfmt"

	# configure and make run only as the invoking user.
	cd "$TMP_DIR/knfmt"
	printf '%s\n' "[INFO] Configuring knfmt with PREFIX=$PREFIX..."
	PREFIX="$PREFIX" ./configure

	# nproc is optional; a missing value simply means a serial build.
	printf '%s\n' "[INFO] Building knfmt..."
	if command -v nproc >/dev/null 2>&1; then
		make -j"$(nproc)"
	else
		make
	fi

	if [ ! -f knfmt ] || [ ! -x knfmt ] || [ ! -f knfmt.1 ]; then
		printf '%s\n' '[ERROR] Build did not produce the expected installation files.' >&2
		exit 1
	fi
	set -- /usr/bin/install
	if ! mkdir -p "$PREFIX/bin" "$PREFIX/man/man1" 2>/dev/null ||
		[ ! -w "$PREFIX/bin" ] || [ ! -w "$PREFIX/man/man1" ]; then
		require_cmd sudo
		set -- sudo -- /usr/bin/install
	fi
	"$@" -d -- "$PREFIX/bin" "$PREFIX/man/man1"
	"$@" -m 0755 -- knfmt "$PREFIX/bin/knfmt"
	"$@" -m 0644 -- knfmt.1 "$PREFIX/man/man1/knfmt.1"
	printf '%s\n' "[INFO] Installed knfmt at $PREFIX/bin/knfmt"
}

main "$@"
