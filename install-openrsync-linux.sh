#!/bin/sh
set -eu

# install-openrsync-linux.sh
# - Installs or updates openrsync from source on Linux.
# - Usage: ./install-openrsync-linux.sh [PREFIX]
# - Default PREFIX: /usr/local
#
# openrsync's Makefile is written for BSD make, so bmake is used on
# Linux; GNU make cannot build it.
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

# Select a BSD make: bmake when available, otherwise a BSD-compatible
# make.  GNU make cannot build openrsync on Linux, so fail clearly
# instead of attempting a broken build with it.
pick_make() {
	if command -v bmake >/dev/null 2>&1; then
		MAKE='bmake'
		# configure invokes plain make internally; point it at
		# bmake so that GNU make is never required.
		MAKE_WRAP="$TMP_DIR/make-wrap"
		mkdir "$MAKE_WRAP"
		{
			printf '%s\n' '#!/bin/sh'
			printf '%s\n' 'exec bmake "$@"'
		} >"$MAKE_WRAP/make"
		chmod +x "$MAKE_WRAP/make"
		CONFIG_PATH="$MAKE_WRAP:$PATH"
	elif command -v make >/dev/null 2>&1 &&
		"$(command -v make)" -V .MAKE.VERSION >/dev/null 2>&1; then
		MAKE='make'
		CONFIG_PATH="$PATH"
	else
		printf '%s\n' \
			"[ERROR] openrsync requires BSD make on Linux." \
			" Install bmake; GNU make cannot build it." >&2
		exit 1
	fi
}

# Verify that the zlib development files are usable, mirroring the
# Makefile's "pkg-config --libs zlib || -lz" fallback.
check_zlib() {
	ZLIB_CHECK_C="$TMP_DIR/zlib-check.c"
	ZLIB_CHECK_BIN="$TMP_DIR/zlib-check"
	{
		printf '%s\n' '#include <zlib.h>'
		printf '%s\n' \
			'int main(void) { return zlibVersion() == 0; }'
	} >"$ZLIB_CHECK_C"
	ZLIB_CPPFLAGS=
	ZLIB_LDLIBS=-lz
	if command -v pkg-config >/dev/null 2>&1; then
		ZLIB_CPPFLAGS=$(pkg-config --cflags zlib 2>/dev/null || true)
		ZLIB_LDLIBS=$(pkg-config --libs zlib 2>/dev/null || true)
		[ -n "$ZLIB_LDLIBS" ] || ZLIB_LDLIBS=-lz
	fi
	# Word splitting is intentional: pkg-config may emit several
	# flags, and the variables are empty or -lz otherwise.
	# shellcheck disable=SC2086
	if cc $ZLIB_CPPFLAGS "$ZLIB_CHECK_C" -o "$ZLIB_CHECK_BIN" \
		$ZLIB_LDLIBS >/dev/null 2>&1; then
		rm -f "$ZLIB_CHECK_C" "$ZLIB_CHECK_BIN"
		return 0
	fi
	rm -f "$ZLIB_CHECK_C" "$ZLIB_CHECK_BIN"
	printf '%s\n' \
		"[ERROR] zlib development files not found" \
		" (need zlib.h and a linkable libz)." \
		" Install your distribution's zlib development package." >&2
	return 1
}

main() {
	PREFIX=${1:-/usr/local}
	[ $# -le 1 ] || usage
	[ "${PREFIX#-}" = "$PREFIX" ] || usage
	case "$PREFIX" in
	*[[:space:]]*)
		printf '%s\n' \
			"[ERROR] PREFIX must not contain spaces;" \
			" openrsync's install rules cannot handle them." >&2
		exit 1
		;;
	esac
	REPO_URL="https://github.com/kristapsdz/openrsync"

	OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
	[ "$OS_NAME" = "Linux" ] || {
		printf '%s\n' \
			"[ERROR] This installer only supports Linux" \
			" (detected: $OS_NAME)" >&2
		exit 1
	}

	require_cmd git
	require_cmd cc
	require_cmd mktemp
	require_cmd cut
	require_cmd sed
	require_cmd install

	if command -v openrsync >/dev/null 2>&1; then
		printf '%s\n' "[INFO] Existing openrsync found at: $(command -v openrsync)"
		printf '%s\n' \
			"[INFO] Proceeding with update from latest upstream" \
			" source..."
	else
		printf '%s\n' \
			"[INFO] openrsync not found; proceeding with" \
			" fresh install..."
	fi

	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openrsync-build-XXXXXX")
	trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

	pick_make

	printf '%s\n' "[INFO] Cloning openrsync source..."
	git clone --depth 1 "$REPO_URL" "$TMP_DIR/openrsync"

	cd "$TMP_DIR/openrsync"

	check_zlib

	printf '%s\n' "[INFO] Configuring openrsync with PREFIX=$PREFIX..."
	PATH="$CONFIG_PATH" ./configure PREFIX="$PREFIX"

	printf '%s\n' "[INFO] Building openrsync with $MAKE..."
	if command -v nproc >/dev/null 2>&1; then
		"$MAKE" -j"$(nproc)"
	else
		"$MAKE"
	fi

	printf '%s\n' "[INFO] Installing/updating openrsync..."
	if "$MAKE" install; then
		if command -v openrsync >/dev/null 2>&1; then
			printf '%s\n' "[INFO] openrsync available at: $(command -v openrsync)"
		elif [ -x "$PREFIX/bin/openrsync" ]; then
			printf '%s\n' "[INFO] openrsync installed at: $PREFIX/bin/openrsync"
			printf '%s\n' "[INFO] $PREFIX/bin is not in PATH"
		fi
		printf '%s\n' "[INFO] openrsync install/update completed successfully"
		exit 0
	fi

	printf '%s\n' \
		"[ERROR] Installation failed." \
		" Re-run with elevated privileges if needed." >&2
	exit 1
}

main "$@"
