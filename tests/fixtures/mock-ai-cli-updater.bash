#!/bin/bash
# Run the AI updater dispatcher against a disposable package and executable set.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../../scripts/update-ai-clis-linux.bash
source "$1"
release_helper=${1%/*}/release-verify.pl
shift

if [[ ${1:-} == --test-swival ]]; then
	JQ=$2
	platform=$3
	shift 3
	setup_runtime() {
		ARCH=amd64 HOME_DIR=$HOME USER_BIN=$FIXTURE_ROOT/bin
		WORK_DIR=$HOME/work STATE_DIR=$HOME/state RELEASE_HELPER=$release_helper
		BREW_PREFIX=$FIXTURE_ROOT/brew
		ORIGINAL_PATH="$USER_BIN:$FIXTURE_ROOT/other:/usr/bin:/bin"
		mkdir -p -- "$WORK_DIR" "$STATE_DIR" "$BREW_PREFIX/bin"
	}
	safe_path() { [[ $1 == "$FIXTURE_ROOT/"* ]]; }
	metadata_ready() { return 0; }
	ensure_packages() {
		printf 'dependencies %s\n' "$1" >>"$FIXTURE_ROOT/events"
		[[ ${FIXTURE_DEPENDENCIES_FAIL:-} != swival ]]
	}
	install_brew_uv() {
		mkdir -p -- "$BREW_PREFIX/opt/uv" || return
		cp -- "${BASH_SOURCE[0]%/*}/mock-ai-cli-swival-uv.bash" "$BREW_PREFIX/bin/uv"
	}
	run_brew() {
		printf 'brew %s\n' "$*" >>"$FIXTURE_ROOT/events"
		case "$1" in
		update) ;;
		info)
			local installed='[]' outdated=false version
			if [[ -x $BREW_PREFIX/bin/uv ]]; then
				installed='[{}]'
				version=$(version_of "$BREW_PREFIX/bin/uv") || return
				[[ $version == 0.13.9 ]] || outdated=true
			fi
			printf '{"formulae":[{"installed":%s,"outdated":%s}]}\n' "$installed" "$outdated"
			;;
		install | upgrade) install_brew_uv ;;
		*) return 1 ;;
		esac
	}
	fetch() {
		local version=${FIXTURE_SWIVAL_VERSION:-1.2.3} uv_version=${FIXTURE_UV_VERSION:-0.13.9}
		local triplet=x86_64-unknown-linux-gnu digest
		if [[ ${FIXTURE_OFFLINE:-} == swival ]]; then return 1; fi
		case "$1" in
		https://pypi.org/pypi/swival/json)
			local primary=$version file
			if [[ ${FIXTURE_SWIVAL_PREVIEW:-} == 1 ]]; then primary+=rc1; fi
			file=$(printf '{"url":"https://files.pythonhosted.org/packages/abc/swival-%s-py3-none-any.whl","filename":"swival-%s-py3-none-any.whl","packagetype":"bdist_wheel","yanked":%s,"digests":{"sha256":"%s"}}' \
				"$version" "$version" "${FIXTURE_SWIVAL_YANKED:-false}" \
				1111111111111111111111111111111111111111111111111111111111111111) || return
			printf '{"info":{"version":"%s","name":"swival"},"releases":{"%s":[%s]}}\n' \
				"$primary" "$version" "$file"
			;;
		https://api.github.com/repos/astral-sh/uv/releases/latest)
			mkdir -p -- "$WORK_DIR/uv-$triplet" || return
			cp -- "${BASH_SOURCE[0]%/*}/mock-ai-cli-swival-uv.bash" "$WORK_DIR/uv-$triplet/uv" || return
			tar -czf "$WORK_DIR/test-uv.tgz" -C "$WORK_DIR" "uv-$triplet" || return
			digest=$(sha256sum -- "$WORK_DIR/test-uv.tgz") || return
			if [[ ${FIXTURE_BAD_UV_DIGEST:-} == 1 ]]; then digest=$(printf '%064d' 0); fi
			printf '{"draft":false,"prerelease":false,"tag_name":"%s","assets":[{"name":"uv-%s.tar.gz","browser_download_url":"https://github.com/astral-sh/uv/releases/download/%s/uv-%s.tar.gz","digest":"sha256:%s"}]}\n' \
				"$uv_version" "$triplet" "$uv_version" "$triplet" "${digest%% *}"
			;;
		https://github.com/astral-sh/uv/releases/download/*)
			[[ $2 == -o ]] || return
			cp -- "$WORK_DIR/test-uv.tgz" "$3"
			;;
		*) return 1 ;;
		esac
	}
	verify_session() {
		printf 'session %s\n' "$1" >>"$FIXTURE_ROOT/events"
		[[ ${FIXTURE_PATH_FAIL:-} != "$1" && $(version_of "$2") == "$FINAL" ]]
	}
	export HTTPS_PROXY=fixture-proxy UV_INDEX_URL=fixture-index PIP_INDEX_URL=fixture-index UV_PYTHON_INSTALL_MIRROR=fixture-mirror
	main "$platform" "$@"
	exit
fi

if [[ ${1:-} == --test-session ]]; then
	PLATFORM=${2:-debian}
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
		tap:) printf '%s\n' homebrew/core charmbracelet/tap oven-sh/bun ;;
		info:oven-sh/bun/bun)
			printf '%s\n' '{"formulae":[{"full_name":"oven-sh/bun/bun","versions":{"stable":"2.0.0"},"installed":[],"dependencies":[]}]}'
			;;
		info:homebrew/core/opencode)
			printf '%s\n' '{"formulae":[{"full_name":"homebrew/core/opencode","tap":"homebrew/core","name":"opencode","versions":{"stable":"2.0.0"},"installed":[],"dependencies":[]}]}'
			;;
		info:charmbracelet/tap/crush)
			printf '%s\n' '{"formulae":[{"full_name":"charmbracelet/tap/crush","tap":"charmbracelet/tap","name":"crush","versions":{"stable":"2.0.0"},"installed":[],"dependencies":[]}]}'
			;;
		info:homebrew/cask/codex)
			printf '%s\n' '{"casks":[{"token":"codex","tap":"homebrew/cask","version":"2.0.0","installed":null}]}'
			;;
		info:homebrew/cask/copilot-cli)
			printf '%s\n' '{"casks":[{"token":"copilot-cli","tap":"homebrew/cask","version":"2.0.0","installed":null}]}'
			;;
		info:homebrew/cask/claude-code)
			printf '%s\n' '{"casks":[{"token":"claude-code","tap":"homebrew/cask","version":"2.0.0","installed":"1.0.0"}]}'
			;;
		*) return 1 ;;
		esac
	}
	latest_brew opencode
	install_brew opencode
	latest_brew crush
	install_brew crush
	latest_brew codex
	install_brew codex
	latest_brew copilot-cli
	install_brew copilot-cli
	latest_brew claude
	install_brew claude
	latest_brew bun
	install_brew bun
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

ensure_swival_runtime() { ensure_packages swival; }

activate_user_release() { install_debian "$1"; }

verify_session() {
	printf 'session %s\n' "$1" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_PATH_FAIL:-} != "$1" ]]
}

main debian "$@"
