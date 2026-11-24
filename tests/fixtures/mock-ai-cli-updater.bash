#!/bin/bash
# Run the AI updater dispatcher against a disposable package and executable set.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../../scripts/update-ai-clis-linux.bash
source "$1"
shift

if [[ ${1:-} == --test-session ]]; then
	HOME_DIR="$HOME"
	SHELL_BIN="$FIXTURE_ROOT/bin/bash"
	ORIGINAL_PATH=/usr/bin:/bin
	USER_BIN="$FIXTURE_ROOT/bin"
	FINAL=2.0.0
	safe_path() { [[ $1 == "$FIXTURE_ROOT/"* ]]; }
	verify_session codex "$USER_BIN/codex"
	exit
fi

if [[ ${1:-} == --test-homebrew ]]; then
	JQ=$2
	run_brew() {
		printf '%s\n' "$*" >>"$FIXTURE_ROOT/events"
		case "$1:${4:-}" in
		update: | install:* | upgrade:*) return 0 ;;
		info:homebrew/cask/codex)
			printf '%s\n' '{"casks":[{"token":"codex","tap":"homebrew/cask","version":"2.0.0","installed":null}]}'
			;;
		info:homebrew/cask/claude-code)
			printf '%s\n' '{"casks":[{"token":"claude-code","tap":"homebrew/cask","version":"2.0.0","installed":"1.0.0"}]}'
			;;
		*) return 1 ;;
		esac
	}
	latest_brew codex
	install_brew codex
	latest_brew claude
	install_brew claude
	exit
fi

if [[ ${1:-} == --test-dependencies ]]; then
	PLATFORM=debian
	RELEASE_HELPER=${BASH_SOURCE[0]}
	declare -A installed=(["ca-certificates"]=2.0 [curl]=1.0)
	apt-cache() {
		[[ $1 == policy ]] || return 1
		printf 'candidate %s\n' "$2" >>"$FIXTURE_ROOT/events"
		if [[ ${FIXTURE_INCOMPATIBLE:-} == "$2" ]]; then
			printf '  Candidate: (none)\n'
		else
			printf '  Candidate: 2.0\n'
		fi
	}
	dpkg-query() {
		local package=${!#}
		[[ ${installed[$package]+present} ]] || return 1
		printf 'installed %s\n' "${installed[$package]}"
	}
	dpkg() { [[ $1 == --compare-versions && $2 == 1.0 && $3 == lt && $4 == 2.0 ]]; }
	run_root() {
		[[ $1 == /usr/bin/apt-get ]] || return 1
		shift
		local argument
		for argument in "$@"; do
			case "$argument" in
			update)
				printf 'refresh\n' >>"$FIXTURE_ROOT/events"
				return
				;;
			--) break ;;
			esac
			shift
		done
		[[ ${1:-} == -- ]] || return 1
		shift
		for argument in "$@"; do
			printf 'package %s\n' "${argument%%=*}" >>"$FIXTURE_ROOT/events"
			installed[${argument%%=*}]=${argument#*=}
		done
	}
	for program in curl jq openssl perl cosign; do
		ln -sf /bin/true "$FIXTURE_ROOT/bin/$program"
	done
	export PATH="$FIXTURE_ROOT/bin:$PATH"
	shift
	for agent in "$@"; do ensure_packages "$agent"; done
	exit
fi

setup_runtime() {
	ARCH=amd64
	HOME_DIR="$HOME"
	WORK_DIR="$HOME_DIR/work"
	mkdir -p "$WORK_DIR"
	USER_BIN="$FIXTURE_ROOT/bin"
	ORIGINAL_PATH="$USER_BIN:$FIXTURE_ROOT/other:/usr/bin:/bin"
	PATH=$ORIGINAL_PATH
	export PATH
}

safe_path() {
	[[ $1 == "$FIXTURE_ROOT/"* ]]
}

is_supported() {
	[[ ${FIXTURE_UNSUPPORTED:-} != "$1" ]]
}

metadata_ready() {
	[[ ${FIXTURE_BOOTSTRAP:-} != "$1" ]]
}

ensure_packages() {
	printf 'dependencies %s\n' "$1" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_DEPENDENCIES_FAIL:-} != "$1" ]]
}

latest_debian() {
	[[ $ARCH == amd64 && -d $WORK_DIR ]] || return 1
	printf 'resolve %s\n' "$1" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_OFFLINE:-} != "$1" ]] || return 1
	LATEST=2.0.0
}

managed_path() {
	local name="$1"
	if [[ $name == copilot-cli ]]; then name=copilot; fi
	MANAGED="$USER_BIN/$name"
}

can_update() {
	[[ ${FIXTURE_PERMISSION_FAIL:-} != "$1" ]]
}

install_debian() {
	printf 'install %s\n' "$1" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_INSTALL_FAIL:-} != "$1" ]] || return 1
	[[ ${FIXTURE_INSTALL_NOOP:-} != "$1" ]] || return 0
	printf '#!/bin/sh\nprintf "%%s\\n" "%s %s"\n' "$1" "$LATEST" >"$MANAGED"
	chmod 0755 "$MANAGED"
}

verify_session() {
	printf 'session %s\n' "$1" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_PATH_FAIL:-} != "$1" ]]
}

main debian "$@"
