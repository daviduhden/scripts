#!/bin/bash
set -euo pipefail

# Shared Debian and SecureBlue implementation of update-ai-clis.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

readonly SYSTEM_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
readonly VERSION_CORE='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
readonly PRERELEASE_ID='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
readonly VERSION_SUFFIX="(-$PRERELEASE_ID(\.$PRERELEASE_ID)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"
readonly CLAUDE_REPO=https://downloads.claude.ai/claude-code/apt/stable
readonly CLAUDE_SIGNER=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

declare -ar AGENTS=(opencode codex crush copilot-cli claude)
declare -Ar COMMANDS=([opencode]=opencode [codex]=codex [crush]=crush ["copilot-cli"]=copilot [claude]=claude)
declare -Ar BREW_PACKAGES=(
	[opencode]=homebrew/core/opencode
	[codex]=homebrew/cask/codex
	[crush]=charmbracelet/tap/crush
	["copilot-cli"]=homebrew/cask/copilot-cli
	[claude]=homebrew/cask/claude-code
)
declare -Ar GITHUB_REPOS=(
	[codex]=openai/codex
	[crush]=charmbracelet/crush
	["copilot-cli"]=github/copilot-cli
)
declare -a SELECTED=() CANDIDATES=() APT_CLAUDE=()
declare -A REQUIRED_PACKAGES=()
declare -A BREW_CHECKED_DEPENDENCIES=()
PLATFORM=""
ORIGINAL_PATH=""
PROBE_PATH=""
HOME_DIR=""
USER_BIN=""
NPM_BIN=""
STATE_DIR=""
WORK_DIR=""
PROFILE=""
SHELL_BIN=""
BREW=""
BREW_PREFIX=""
BREW_UID=""
RELEASE_HELPER=""
ARCH=""
VENDOR_ARCH=""
APT_READY=0
BREW_READY=0
BREW_INSTALLED=0
BREW_DEPENDENCIES=""
DEFAULT_SELECTION=0
LATEST=""
TAG=""
METADATA=""
ASSET_DIGEST=""
MANAGED=""
PREVIOUS=""
FINAL=""
RESULT=""

usage() {
	cat <<'HELP'
Usage: update-ai-clis [all | AGENT ...]
       update-ai-clis --help

Install or update the latest stable release of each selected agent.
Agents: opencode, codex, crush, copilot-cli, claude.
With no agents or with 'all', process every supported agent.

Exit status: 0 success, 1 operation failed, 2 invalid arguments.
HELP
}

warn() { printf 'update-ai-clis: %s\n' "$*" >&2; }

select_agents() {
	local agent
	local -A seen=()
	if [[ $# -eq 0 || ($# -eq 1 && $1 == all) ]]; then
		SELECTED=("${AGENTS[@]}")
		DEFAULT_SELECTION=1
		return
	fi
	for agent in "$@"; do
		case "$agent" in
		opencode | codex | crush | copilot-cli | claude)
			if [[ ! ${seen[$agent]+present} ]]; then
				SELECTED+=("$agent")
				seen[$agent]=1
			fi
			;;
		*)
			warn "Unknown or misplaced argument: $agent"
			return 2
			;;
		esac
	done
}

# Extract the first complete semver token from the agent's version banner.
# Compare decimal components without Bash's fixed-width arithmetic.
version_of() {
	local output
	output=$(PATH=${PROBE_PATH:-$SYSTEM_PATH} /usr/bin/timeout --kill-after=3s 20s "$1" --version 2>&1) || return
	parse_version "$output"
}

parse_version() {
	[[ $1 =~ (^|[[:space:]])v?($VERSION_CORE$VERSION_SUFFIX)\.?([[:space:]]|$) ]] || return 1
	printf '%s\n' "${BASH_REMATCH[2]}"
}

is_stable() { [[ $1 =~ ^$VERSION_CORE(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; }

compare_to_stable() {
	local installed=${1%%+*} stable=${2%%+*} base i a b
	local -a left right
	base=${installed%%-*}
	IFS=. read -r -a left <<<"$base"
	IFS=. read -r -a right <<<"$stable"
	for i in 0 1 2; do
		a=${left[i]} b=${right[i]}
		if ((${#a} > ${#b})) || [[ ${#a} == "${#b}" && $a > $b ]]; then
			printf 'newer\n'
			return
		fi
		if ((${#a} < ${#b})) || [[ ${#a} == "${#b}" && $a < $b ]]; then
			printf 'older\n'
			return
		fi
	done
	if [[ $installed == *-* ]]; then
		printf 'older\n'
	else
		printf 'current\n'
	fi
}

# Walk canonical parents, accepting only directories controlled by this user,
# root, or SecureBlue's dedicated Homebrew account.
safe_ancestors() {
	local path owner mode trusted_brew_uid=${BREW_UID:-0}
	path=$1
	while :; do
		read -r owner mode < <(stat -Lc '%u %a' -- "$path") || return
		[[ $owner == 0 || $owner == "$EUID" || $owner == "$trusted_brew_uid" ]] || return 1
		(((8#$mode & 022) == 0)) || return 1
		[[ $path != / ]] || return 0
		path=${path%/*}
		path=${path:-/}
	done
}

safe_path() {
	local canonical lexical
	[[ $1 == /* ]] || return 1
	canonical=$(realpath -e -- "$1") && lexical=$(realpath -sm -- "$1") || return
	safe_ancestors "$canonical" || return
	if [[ $canonical != "$lexical" ]]; then
		safe_ancestors "$lexical"
	fi
}

set_probe_path() {
	local dir
	local -a paths
	PROBE_PATH=""
	IFS=: read -r -a paths <<<"$ORIGINAL_PATH:$SYSTEM_PATH:$USER_BIN:${BREW_PREFIX:+$BREW_PREFIX/bin}"
	for dir in "${paths[@]}"; do
		if [[ -d $dir ]] && safe_path "$dir"; then
			case ":$PROBE_PATH:" in
			*":$dir:"*) ;;
			*) PROBE_PATH=${PROBE_PATH:+$PROBE_PATH:}$dir ;;
			esac
		fi
	done
}

find_npm_prefix() {
	local npm prefix
	npm=$(PATH=$PROBE_PATH type -P npm) || return 0
	[[ $npm == /* ]] && safe_path "$npm" && safe_path "${npm%/*}" || return 0
	prefix=$(PATH=$PROBE_PATH /usr/bin/timeout 8s "$npm" config get prefix --global 2>/dev/null) || return 0
	if [[ $prefix == /* && $prefix != *:* && $prefix != *[[:cntrl:]]* &&
		-d $prefix/bin ]] && safe_path "$prefix/bin"; then
		NPM_BIN=$prefix/bin
	fi
}

ensure_user_dir() {
	local path=$1 parent=${1%/*}
	if [[ ! -d $path ]]; then
		safe_path "$parent" && [[ ! -L $path ]] && mkdir -- "$path" || return
	fi
	[[ ! -L $path && -O $path && -w $path ]] && safe_path "$path"
}

find_candidates() {
	local binary=$1 dir path target
	local -a paths
	local -A seen=()
	CANDIDATES=()
	IFS=: read -r -a paths <<<"$ORIGINAL_PATH:$SYSTEM_PATH:$USER_BIN:$HOME_DIR/.opencode/bin:$HOME_DIR/.bun/bin:$HOME_DIR/.npm-global/bin:${BREW_PREFIX:+$BREW_PREFIX/bin}:$NPM_BIN"
	for dir in "${paths[@]}"; do
		path=${dir:-.}/$binary
		[[ -f $path && -x $path ]] || continue
		target=$(realpath -e -- "$path") || continue
		if [[ ! ${seen[$target]+present} ]]; then
			seen[$target]=1
			CANDIDATES+=("$path")
		fi
	done
}

locate_brew() {
	local dir candidate
	local -a dirs
	BREW_UID=$(id -u linuxbrew 2>/dev/null || true)
	IFS=: read -r -a dirs <<<"$ORIGINAL_PATH"
	for dir in /home/linuxbrew/.linuxbrew/bin /var/home/linuxbrew/.linuxbrew/bin "$HOME_DIR/.linuxbrew/bin" "${dirs[@]}"; do
		[[ $dir == /* ]] || continue
		candidate=$dir/brew
		if [[ ! -f $candidate || ! -x $candidate ]] || ! safe_path "$dir" || ! safe_path "$candidate"; then
			continue
		fi
		BREW=$candidate
		BREW_PREFIX=$(run_brew --prefix) || return
		[[ $BREW_PREFIX == /* && -d $BREW_PREFIX/bin ]] && safe_path "$BREW_PREFIX/bin" || return 1
		return 0
	done
	warn "Homebrew is unavailable. Set it up through SecureBlue before running this updater."
	return 1
}

run_brew() {
	# Use the normal dispatcher, including SecureBlue's authorization policy.
	env -u NO_BREW_PROXY -u HOMEBREW_CASK_OPTS -u HOMEBREW_API_DOMAIN \
		-u HOMEBREW_BOTTLE_DOMAIN -u HOMEBREW_ARTIFACT_DOMAIN \
		-u HOMEBREW_BREW_GIT_REMOTE -u HOMEBREW_CORE_GIT_REMOTE \
		-u HOMEBREW_NO_VERIFY_ATTESTATIONS HOMEBREW_NO_AUTO_UPDATE=1 \
		HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
		HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 \
		HOMEBREW_NO_ANALYTICS=1 GIT_TERMINAL_PROMPT=0 \
		"$BREW" "$@"
}

run_root() {
	if [[ -x /usr/bin/sudo ]]; then
		/usr/bin/sudo -- "$@"
	else
		warn "sudo is required for Debian package operations."
		return 1
	fi
}

refresh_apt() {
	case "$APT_READY" in
	1) return 0 ;;
	-1) return 1 ;;
	esac
	APT_READY=-1
	run_root /usr/bin/apt-get -o APT::Update::Error-Mode=any update >&2 || return
	APT_READY=1
}

ensure_packages() {
	local agent=$1 phase=${2:-install} command package candidate current
	local -a required=(ca-certificates curl) packages=()
	[[ $PLATFORM == debian ]] || return 0
	# The native agents do not require Node.js, npm, Bun, Python, or gh.
	# APT resolves the package runtime for Claude/Crush. The text/crypto
	# tools below are needed only by the corresponding delivery adapters.
	if [[ $agent != claude ]]; then required+=(jq); fi
	if [[ $phase == install ]]; then
		case "$agent" in
		opencode) required+=(openssl perl) ;;
		codex) required+=(cosign perl) ;;
		crush) required+=(cosign) ;;
		copilot-cli) required+=(perl) ;;
		esac
	fi
	local -A pending=()
	refresh_apt || return
	for package in "${required[@]}"; do
		if [[ ${REQUIRED_PACKAGES[$package]+ready} ]]; then
			continue
		fi
		current=$(dpkg-query -W -f='${db:Status-Status} ${Version}\n' -- "$package" 2>/dev/null) || current=""
		if [[ $phase == metadata && $current == "installed "* ]]; then
			continue
		fi
		candidate=$(apt-cache policy "$package") || return
		candidate=$(awk '/^  Candidate:/ { print $2 }' <<<"$candidate") || return
		if [[ -z $candidate || $candidate == '(none)' ]]; then
			warn "No Debian package candidate for $package."
			return 1
		fi
		if [[ $current != "installed "* ]] || dpkg --compare-versions "${current#installed }" lt "$candidate"; then
			packages+=("$package=$candidate")
			pending[$package]=$candidate
		else
			REQUIRED_PACKAGES[$package]=ready
		fi
	done
	if ((${#packages[@]})); then
		run_root /usr/bin/apt-get --assume-yes --no-remove --no-install-recommends \
			install -- "${packages[@]}" >&2 || return
		for package in "${!pending[@]}"; do
			current=$(dpkg-query -W -f='${db:Status-Status} ${Version}\n' -- "$package") || return
			[[ $current == "installed ${pending[$package]}" ]] || return 1
			REQUIRED_PACKAGES[$package]=ready
		done
	fi
	for command in "${required[@]}"; do
		if [[ $command != ca-certificates ]]; then
			command -v "$command" >/dev/null || return
		fi
	done
	if [[ $phase == install && ($agent == opencode || $agent == codex || $agent == copilot-cli) ]]; then
		command -v perl >/dev/null && [[ -r $RELEASE_HELPER ]] || {
			warn "Perl and the installed release-verify helper are required for archive verification."
			return 1
		}
	fi
}

metadata_ready() {
	command -v curl >/dev/null && [[ -r /etc/ssl/certs/ca-certificates.crt ]] &&
		{ [[ $1 == claude ]] || command -v jq >/dev/null; }
}

refresh_brew() {
	case "$BREW_READY" in
	1) return 0 ;;
	-1) return 1 ;;
	esac
	BREW_READY=-1
	run_brew update >&2 || return
	BREW_READY=1
}

setup_metadata_tools() {
	if command -v jq >/dev/null; then
		return 0
	fi
	local path=$BREW_PREFIX/bin/jq
	if [[ ! -x $path ]]; then
		refresh_brew && run_brew install --formula homebrew/core/jq >&2 || return
	fi
	[[ -x $path ]] && safe_path "$path" || return
	JQ=$path
}

# Never read curlrc or forward authentication tokens to public endpoints.
fetch() {
	curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--connect-timeout 15 --max-time 240 --retry 2 --retry-max-time 300 \
		--max-filesize 536870912 "$@"
}

checksum() {
	local digest
	digest=$(sha256sum -- "$1") || return
	[[ ${digest%% *} == "$2" ]] || {
		warn "SHA-256 mismatch for ${1##*/}"
		return 1
	}
}

github_asset() {
	local repo=$1 name=$2 file=$3 url digest
	url=https://github.com/$repo/releases/download/$TAG/$name
	digest=$(jq -er --arg name "$name" --arg url "$url" '
		[.assets[] | select(.name == $name and .browser_download_url == $url)] |
		select(length == 1) | .[0].digest |
		select(test("^sha256:[0-9a-f]{64}$")) | ltrimstr("sha256:")
	' <<<"$METADATA") || return
	fetch "$url" -o "$file" && checksum "$file" "$digest" || return
	ASSET_DIGEST=$digest
}

release_checksum() {
	local file=$1 list=$2 name=$3 digest
	digest=$(awk -v name="$name" '$2 == name || $2 == "*" name { if (++count == 1) digest=$1 }
		END { if (count != 1) exit 1; print digest }' "$list") || return
	[[ $digest =~ ^[0-9a-f]{64}$ ]] && checksum "$file" "$digest"
}

verify_sigstore() {
	local file=$1 bundle=$2 identity=$3
	TUF_ROOT=$WORK_DIR/sigstore-tuf cosign verify-blob --bundle "$bundle" \
		--certificate-identity "$identity" --certificate-oidc-issuer \
		https://token.actions.githubusercontent.com "$file" >&2
}

claude_release() {
	local candidate
	mkdir -- "$WORK_DIR/claude-lists" || return
	fetch https://downloads.claude.ai/keys/claude-code.asc -o "$WORK_DIR/claude.asc" || return
	# Isolate the unprivileged index refresh from system APT hooks and caches.
	cat >"$WORK_DIR/claude-apt.conf" <<'APT'
Dir::Etc::parts "-";
Dir::Etc::main "-";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT
	printf 'deb [arch=%s signed-by=%s,%s] %s stable main\n' "$ARCH" \
		"$WORK_DIR/claude.asc" "$CLAUDE_SIGNER" "$CLAUDE_REPO" >"$WORK_DIR/claude.list" || return
	APT_CLAUDE=(
		-o "Dir::Etc::sourcelist=$WORK_DIR/claude.list"
		-o Dir::Etc::sourceparts=-
		-o "Dir::State::lists=$WORK_DIR/claude-lists"
		-o "APT::Sandbox::User=$(id -un)"
		-o APT::Update::Error-Mode=any
	)
	claude_apt apt-get update >&2 || return
	candidate=$(claude_apt apt-cache madison claude-code) || return
	TAG=$(awk -F'|' 'NR == 1 { gsub(/ /,"",$2); print $2 }' <<<"$candidate")
	[[ $TAG =~ ^$VERSION_CORE-[0-9]+$ ]] || return 1
	LATEST=${TAG%-*}
}

claude_apt() {
	local command=$1
	shift
	APT_CONFIG=$WORK_DIR/claude-apt.conf "$command" "${APT_CLAUDE[@]}" "$@"
}

latest_debian() {
	local agent=$1 repo
	case "$agent" in
	opencode)
		METADATA=$(fetch 'https://registry.npmjs.org/@opencode%2fcli/latest') || return
		LATEST=$(jq -er 'select(.name == "@opencode/cli") | .version' <<<"$METADATA") || return
		;;
	claude) claude_release || return ;;
	*)
		repo=${GITHUB_REPOS[$agent]}
		METADATA=$(fetch "https://api.github.com/repos/$repo/releases/latest") || return
		TAG=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' <<<"$METADATA") || return
		if [[ $agent == codex ]]; then
			[[ $TAG == rust-v* ]] || return 1
			LATEST=${TAG#rust-v}
		else
			[[ $TAG == v* ]] || return 1
			LATEST=${TAG#v}
		fi
		;;
	esac
	is_stable "$LATEST"
}

brew_kind() {
	case "$1" in
	opencode | crush) printf '%s\n' --formula ;;
	*) printf '%s\n' --cask ;;
	esac
}

latest_brew() {
	local agent=$1 kind metadata package taps
	package=${BREW_PACKAGES[$agent]}
	kind=$(brew_kind "$agent")
	BREW_DEPENDENCIES=""
	refresh_brew || return
	if [[ $agent == crush ]]; then
		taps=$(run_brew tap) || return
		if ! grep -Fxq charmbracelet/tap <<<"$taps"; then
			run_brew tap charmbracelet/tap >&2 || return
		fi
	fi
	metadata=$(run_brew info --json=v2 "$kind" "$package") || return
	if [[ $kind == --formula ]]; then
		# shellcheck disable=SC2016 # The variables below are jq arguments.
		LATEST=$("$JQ" -er --arg name "$package" '
			.formulae[0] | select(.full_name == $name or
				(.tap == "homebrew/core" and ("homebrew/core/" + .name) == $name)) |
			.versions.stable' <<<"$metadata") || return
		BREW_INSTALLED=$("$JQ" -er '.formulae[0].installed | length' <<<"$metadata") || return
		BREW_DEPENDENCIES=$("$JQ" -r '.formulae[0].dependencies[]' <<<"$metadata") || return
	else
		# shellcheck disable=SC2016 # The variables below are jq arguments.
		LATEST=$("$JQ" -er --arg name "${package##*/}" '
			.casks[0] | select(.token == $name and .tap == "homebrew/cask") | .version' \
			<<<"$metadata") || return
		BREW_INSTALLED=$("$JQ" -er 'if .casks[0].installed then 1 else 0 end' <<<"$metadata") || return
	fi
	[[ $BREW_INSTALLED =~ ^[0-9]+$ ]] && is_stable "$LATEST"
}

ensure_brew_runtime() {
	local name package info installed outdated
	[[ -n $BREW_DEPENDENCIES ]] || return 0
	while IFS= read -r name; do
		# Built-in and publisher formulas used here depend on core formulas.
		[[ $name =~ ^[a-z0-9][a-z0-9+._@-]*$ ]] || return 1
		if [[ ${BREW_CHECKED_DEPENDENCIES[$name]+checked} ]]; then
			continue
		fi
		package=homebrew/core/$name
		info=$(run_brew info --json=v2 --formula "$package") || return
		installed=$("$JQ" -er '.formulae[0].installed | length' <<<"$info") || return
		outdated=$("$JQ" -r '.formulae[0].outdated' <<<"$info") || return
		if ((installed == 0)); then
			run_brew install --formula --force-bottle "$package" >&2 || return
		elif [[ $outdated == true ]]; then
			run_brew upgrade --formula --force-bottle "$package" >&2 || return
		fi
		[[ -d $BREW_PREFIX/opt/$name ]] && safe_path "$BREW_PREFIX/opt/$name" || return
		if [[ $name == ripgrep ]]; then
			version_of "$BREW_PREFIX/bin/rg" >/dev/null || return
		fi
		BREW_CHECKED_DEPENDENCIES[$name]=1
	done <<<"$BREW_DEPENDENCIES"
}

release_extract() {
	perl "$RELEASE_HELPER" "$@" 536870912
}

opencode_archive() {
	local platform=linux-$VENDOR_ARCH pkg version_doc url integrity digest keyids keyid key expires sig
	local archive=$WORK_DIR/opencode.tgz keys
	# The baseline build runs on x86-64 CPUs without AVX2. This package
	# contains the native executable, so no npm lifecycle script is needed.
	if [[ $VENDOR_ARCH == x64 ]] && ! grep -qwi avx2 /proc/cpuinfo; then
		platform+=-baseline
	fi
	pkg=@opencode/cli-$platform
	version_doc=$(fetch "https://registry.npmjs.org/@opencode%2fcli-$platform/$LATEST") || return
	url=https://registry.npmjs.org/$pkg/-/cli-$platform-$LATEST.tgz
	integrity=$(jq -er --arg pkg "$pkg" --arg version "$LATEST" --arg url "$url" '
		select(.name == $pkg and .version == $version and .dist.tarball == $url) |
		.dist.integrity | select(test("^sha512-[A-Za-z0-9+/]{86}==$"))
	' <<<"$version_doc") || return
	keys=$(fetch https://registry.npmjs.org/-/npm/v1/keys) || return
	keyids=$(jq -er '[.dist.signatures[].keyid] | unique | .[]' <<<"$version_doc") || return
	while IFS= read -r keyid; do
		key=$(jq -er --arg id "$keyid" '
			.keys[] | select(.keyid == $id and .scheme == "ecdsa-sha2-nistp256") | .key
		' <<<"$keys") || continue
		expires=$(jq -r --arg id "$keyid" '.keys[] | select(.keyid == $id) | .expires // empty' <<<"$keys") || return
		if [[ -n $expires && $expires < $(date -u '+%Y-%m-%dT%H:%M:%S') ]]; then
			continue
		fi
		printf '%s' "$key" | base64 -d >"$WORK_DIR/npm-key" || return
		while IFS= read -r sig; do
			printf '%s' "$sig" | base64 -d >"$WORK_DIR/npm-signature" || continue
			if printf '%s' "$pkg@$LATEST:$integrity" |
				openssl dgst -sha256 -keyform DER -verify "$WORK_DIR/npm-key" \
					-signature "$WORK_DIR/npm-signature" >/dev/null 2>&1; then
				fetch "$url" -o "$archive" || return
				digest=$(openssl dgst -sha512 -binary "$archive" | base64 -w 0) || return
				[[ sha512-$digest == "$integrity" ]] && return 0
				warn "OpenCode archive failed npm integrity verification"
				return 1
			fi
		done < <(jq -r --arg id "$keyid" '.dist.signatures[] | select(.keyid == $id) | .sig' <<<"$version_doc")
	done <<<"$keyids"
	warn "OpenCode npm metadata signature could not be verified"
	return 1
}

check_publisher_sums() {
	local repo=$1 file=$2 name=$3 sums=$4
	github_asset "$repo" "$sums" "$WORK_DIR/$sums" &&
		release_checksum "$file" "$WORK_DIR/$sums" "$name"
}

codex_archive() {
	local stage=$1 repo=${GITHUB_REPOS[codex]} target name archive bundle
	case "$ARCH" in
	amd64) target=x86_64-unknown-linux-musl ;;
	arm64) target=aarch64-unknown-linux-musl ;;
	esac
	name=codex-package-$target.tar.gz
	archive=$WORK_DIR/$name
	bundle=$name.sigstore
	github_asset "$repo" "$name" "$archive" &&
		check_publisher_sums "$repo" "$archive" "$name" codex-package_SHA256SUMS || return
	github_asset "$repo" "$bundle" "$WORK_DIR/$bundle" || return
	verify_sigstore "$archive" "$WORK_DIR/$bundle" \
		"https://github.com/$repo/.github/workflows/rust-release.yml@refs/tags/$TAG" || return
	release_extract tar-extract-all "$archive" "$stage" "" || return
	local executable
	for executable in bin/codex bin/codex-code-mode-host codex-path/rg codex-resources/bwrap; do
		[[ -f $stage/$executable && -x $stage/$executable ]] || return 1
	done
	jq -e --arg version "$LATEST" --arg target "$target" '
		.layoutVersion == 1 and .version == $version and .target == $target and
		.variant == "codex" and .entrypoint == "bin/codex" and
		.resourcesDir == "codex-resources" and .pathDir == "codex-path" and
		(.execServer == null or .execServer == "bin/codex-exec-server")
	' "$stage/codex-package.json" >/dev/null || return
	if jq -e 'has("execServer")' "$stage/codex-package.json" >/dev/null; then
		[[ -x $stage/bin/codex-exec-server ]]
	fi
}

copilot_archive() {
	local stage=$1 repo=${GITHUB_REPOS["copilot-cli"]} name=copilot-linux-$VENDOR_ARCH.tar.gz
	github_asset "$repo" "$name" "$WORK_DIR/$name" &&
		check_publisher_sums "$repo" "$WORK_DIR/$name" "$name" SHA256SUMS.txt &&
		release_extract tar-extract-entry "$WORK_DIR/$name" "$stage/copilot" copilot
}

install_deb() {
	local file=$1 name=$2 version=$3 expected=$4 actual
	[[ $expected =~ ^[0-9a-f]{64}$ ]] && checksum "$file" "$expected" || return
	actual=$(dpkg-deb -f "$file" Package) && [[ $actual == "$name" ]] || return
	actual=$(dpkg-deb -f "$file" Architecture) && [[ $actual == "$ARCH" ]] || return
	actual=$(dpkg-deb -f "$file" Version) && [[ $actual == "$version" ]] || return
	refresh_apt || return
	# Copy and revalidate in a root-owned staging directory. APT must not
	# consume the original user-owned pathname after privilege elevation.
	# shellcheck disable=SC2016 # This fragment runs in the privileged shell.
	run_root /bin/bash -p -c '
		set -euo pipefail
		export PATH=/usr/sbin:/usr/bin:/sbin:/bin
		umask 077
		stage=$(mktemp -d /tmp/scripts-ai-clis-package.XXXXXX)
		trap '\''rm -f -- "$stage/package.deb"; rmdir -- "$stage"'\'' EXIT
		install -m 0644 -- "$1" "$stage/package.deb"
		actual=$(sha256sum -- "$stage/package.deb")
		[[ ${actual%% *} == "$2" ]]
		chmod 0711 -- "$stage"
		apt-get --assume-yes --no-remove --no-install-recommends install -- "$stage/package.deb"
	' update-ai-clis "$file" "$expected" >&2
}

install_crush() {
	local repo=${GITHUB_REPOS[crush]} name=crush_${LATEST}_$ARCH.deb
	local file=$WORK_DIR/$name bundle=checksums.txt.sigstore.json package_version expected
	github_asset "$repo" "$name" "$file" || return
	expected=$ASSET_DIGEST
	check_publisher_sums "$repo" "$file" "$name" checksums.txt &&
		github_asset "$repo" "$bundle" "$WORK_DIR/$bundle" || return
	verify_sigstore "$WORK_DIR/checksums.txt" "$WORK_DIR/$bundle" \
		"https://github.com/$repo/.github/workflows/release.yml@refs/tags/$TAG" || return
	package_version=$(dpkg-deb -f "$file" Version) || return
	[[ $package_version == "$LATEST" || $package_version =~ ^${LATEST//./\\.}-[0-9]+$ ]] || return 1
	install_deb "$file" crush "$package_version" "$expected"
}

install_claude() {
	local file metadata digest
	metadata=$(claude_apt apt-cache show "claude-code=$TAG") || return
	digest=$(awk '/^SHA256: / { digest=$2; count++ } END { if (count != 1) exit 1; print digest }' \
		<<<"$metadata") || return
	(
		cd "$WORK_DIR" || return
		claude_apt apt-get download "claude-code=$TAG" >&2
	) || return
	file=$WORK_DIR/claude-code_${TAG}_$ARCH.deb
	[[ -f $file ]] && install_deb "$file" claude-code "$TAG" "$digest"
}

can_replace_launcher() {
	local agent=$1 launcher=$2 target
	if [[ ! -e $launcher && ! -L $launcher ]]; then
		return 0
	fi
	[[ -L $launcher ]] || return 1
	target=$(realpath -m -- "$launcher") || return
	[[ $target == "$STATE_DIR/$agent/"* ]]
}

activate_user_release() (
	local agent=$1 binary=$2 stage="" links="" verified
	trap 'if [[ -n $stage && -d $stage ]]; then rm -rf -- "$stage"; fi
		if [[ -n $links && -d $links ]]; then rm -rf -- "$links"; fi' EXIT

	ensure_user_dir "$USER_BIN" && ensure_user_dir "$STATE_DIR/$agent" || return
	stage=$(mktemp -d "$STATE_DIR/$agent/$LATEST.XXXXXX") || return
	case "$agent" in
	opencode)
		opencode_archive &&
			release_extract tar-extract-entry "$WORK_DIR/opencode.tgz" "$stage/$binary" "package/bin/$binary" || return
		;;
	codex)
		codex_archive "$stage" || return
		binary=bin/codex
		;;
	copilot-cli) copilot_archive "$stage" || return ;;
	esac
	verified=$(version_of "$stage/$binary") &&
		[[ $(compare_to_stable "$verified" "$LATEST") == current ]] || return
	links=$(mktemp -d "$USER_BIN/.scripts-ai-clis.XXXXXX") || return
	ln -s -- "$stage/$binary" "$links/${COMMANDS[$agent]}" || return
	can_replace_launcher "$agent" "$MANAGED" || {
		warn "Refusing to replace existing launcher $MANAGED"
		return 1
	}
	mv -Tf -- "$links/${COMMANDS[$agent]}" "$MANAGED" || return
	stage=""
)

install_debian() {
	case "$1" in
	crush) install_crush ;;
	claude) install_claude ;;
	*) activate_user_release "$1" "${COMMANDS[$1]}" ;;
	esac
}

install_brew() {
	local agent=$1 kind package
	local -a options
	kind=$(brew_kind "$agent")
	package=${BREW_PACKAGES[$agent]}
	options=("$kind")
	if [[ $kind == --cask ]]; then
		options+=(--require-sha)
	elif [[ $agent == opencode ]]; then
		options+=(--force-bottle)
	fi
	if ((BREW_INSTALLED == 0)); then
		run_brew install "${options[@]}" "$package" >&2
	elif [[ $kind == --cask ]]; then
		run_brew upgrade "${options[@]}" --greedy "$package" >&2
	else
		run_brew upgrade "${options[@]}" "$package" >&2
	fi
}

managed_path() {
	local agent=$1 binary=${COMMANDS[$1]}
	if [[ $PLATFORM == secureblue ]]; then
		MANAGED=$BREW_PREFIX/bin/$binary
	elif [[ $agent == crush || $agent == claude ]]; then
		MANAGED=/usr/bin/$binary
	else
		MANAGED=$USER_BIN/$binary
	fi
}

same_executable() { [[ -e $1 && -e $2 && $1 -ef $2 ]]; }

can_update() {
	local agent=$1 binary=$2 owner expected
	case "$PLATFORM:$agent" in
	debian:crush | debian:claude)
		[[ ! -e $MANAGED && ! -L $MANAGED ]] && return 0
		expected=$agent
		if [[ $agent == claude ]]; then
			expected=claude-code
		fi
		owner=$(dpkg-query -S -- "$MANAGED" 2>/dev/null) || return
		[[ $owner == "$expected: $MANAGED" ]]
		;;
	debian:*) can_replace_launcher "$agent" "$MANAGED" ;;
	secureblue:*)
		[[ ! -e $MANAGED && ! -L $MANAGED ]] && return 0
		local target prefix
		target=$(realpath -e -- "$MANAGED") && prefix=$(realpath -e -- "$BREW_PREFIX") || return
		[[ $target == "$prefix/Cellar/$binary/"* ||
			$target == "$prefix/Caskroom/${BREW_PACKAGES[$agent]##*/}/"* ]]
		;;
	esac
}

# A fresh login shell shows startup-file overrides that the updater's own
# process cannot inherit. Probe the safe, expected executable inside that
# shell only when its command resolution identifies the same file.
session_command() {
	local binary=$1 expected=$2
	if [[ ${SHELL_BIN##*/} == fish ]]; then
		# shellcheck disable=SC2016 # Expanded by Fish.
		timeout --kill-after=2s 20s env PATH="$SYSTEM_PATH" "$SHELL_BIN" -lc '
			set -l resolved (command -s -- $argv[1])
			printf "__scripts_ai_cli_path__%s\n" "$resolved"
			if string match -q "/*" -- "$resolved"; and test "$resolved" -ef "$argv[2]"
				printf "__scripts_ai_cli_version__\n"
				"$argv[2]" --version
			end
		' "$binary" "$expected" 2>&1
	else
		# shellcheck disable=SC2016 # Expanded by the login shell.
		timeout --kill-after=2s 20s env PATH="$SYSTEM_PATH" BASH_ENV= ENV= "$SHELL_BIN" -lc '
			resolved=$(command -v -- "$1") || resolved=
			printf "__scripts_ai_cli_path__%s\n" "$resolved"
			case "$resolved" in
				/*) if [ "$resolved" -ef "$2" ]; then
					printf "__scripts_ai_cli_version__\n"
					"$2" --version
				fi ;;
			esac
		' update-ai-clis "$binary" "$expected" 2>&1
	fi
}

select_profile() {
	case "${SHELL_BIN##*/}" in
	bash)
		for PROFILE in "$HOME_DIR/.bash_profile" "$HOME_DIR/.bash_login" "$HOME_DIR/.profile"; do
			if [[ -e $PROFILE || -L $PROFILE ]]; then
				break
			fi
		done
		;;
	zsh)
		PROFILE=${ZDOTDIR:-$HOME_DIR}/.zprofile
		;;
	fish)
		local config=${XDG_CONFIG_HOME:-$HOME_DIR/.config}
		ensure_user_dir "$config" && ensure_user_dir "$config/fish" || return
		PROFILE=$config/fish/config.fish
		;;
	sh | dash | ksh) PROFILE=$HOME_DIR/.profile ;;
	*)
		warn "PATH setup is unavailable for ${SHELL_BIN##*/}."
		return 1
		;;
	esac
}

persist_path() {
	local dir=$1 label="# update-ai-clis PATH $1" quoted
	select_profile && safe_path "${PROFILE%/*}" && safe_path "$dir" || return
	if [[ -e $PROFILE || -L $PROFILE ]]; then
		[[ ! -L $PROFILE && -f $PROFILE && -O $PROFILE ]] && safe_path "$PROFILE" || return
		if grep -Fxq -- "$label" "$PROFILE"; then
			return 0
		fi
	fi
	# Reject characters that require shell-specific escapes before writing
	# an executable startup fragment.
	if [[ $dir == *[[:cntrl:]]* || $dir == *:* || $dir == *"'"* || $dir == *"\\"* ]]; then
		warn "Cannot safely add $dir to $PROFILE"
		return 1
	fi
	quoted="'$dir'"
	if [[ ${SHELL_BIN##*/} == fish ]]; then
		printf '\n%s\nfish_add_path --path --append %s\n' "$label" "$quoted" >>"$PROFILE"
	else
		# shellcheck disable=SC2016 # Write a literal variable into the profile.
		printf '\n%s\ncase ":$PATH:" in\n  *:%s:*) ;;\n  *) PATH="$PATH":%s ;;\nesac\nexport PATH\n' \
			"$label" "$quoted" "$quoted" >>"$PROFILE"
	fi
}

verify_session() {
	local binary=$1 expected=$2 path output session_version
	output=$(session_command "$binary" "$expected") || return
	path=$(sed -n 's/^__scripts_ai_cli_path__//p' <<<"$output") || return
	if [[ -z $path ]]; then
		persist_path "${expected%/*}" || return
		output=$(session_command "$binary" "$expected") || return
		path=$(sed -n 's/^__scripts_ai_cli_path__//p' <<<"$output") || return
	fi
	same_executable "$path" "$expected" || {
		warn "A fresh ${SHELL_BIN##*/} login resolves $binary to ${path:-nothing}, expected $expected."
		return 1
	}
	session_version=$(sed '1,/^__scripts_ai_cli_version__$/d' <<<"$output") &&
		session_version=$(parse_version "$session_version") &&
		[[ ${session_version%%+*} == "${FINAL%%+*}" ]] || {
		warn "$binary did not report version $FINAL in a fresh login."
		return 1
	}
	# Also make newly discovered executables available to later probes.
	case ":$ORIGINAL_PATH:" in
	*":${expected%/*}:"*) ;;
	*) ORIGINAL_PATH+=:${expected%/*} ;;
	esac
	case ":$PATH:" in
	*":${expected%/*}:"*) ;;
	*) export PATH="$PATH:${expected%/*}" ;;
	esac
	set_probe_path
}

is_supported() {
	case "$PLATFORM:$ARCH:$1" in
	debian:amd64:* | debian:arm64:* | debian:armhf:crush | secureblue:amd64:* | secureblue:arm64:*) return 0 ;;
	*) return 1 ;;
	esac
}

process_agent() {
	local agent=$1 binary=${COMMANDS[$1]} path="" relative update
	PREVIOUS="" LATEST="" FINAL="" RESULT=failed TAG="" METADATA=""
	find_candidates "$binary"
	if ((${#CANDIDATES[@]})); then
		path=${CANDIDATES[0]}
		if [[ $path == /* ]] && safe_path "$path" && safe_path "${path%/*}"; then
			PREVIOUS=$(version_of "$path") || warn "Cannot determine the version of $path."
			FINAL=$PREVIOUS
		fi
	fi
	if ! is_supported "$agent"; then
		RESULT=unsupported
		warn "$agent is unavailable on $PLATFORM ($ARCH)."
		((DEFAULT_SELECTION)) && return 0
		return 1
	fi
	if ((${#CANDIDATES[@]} > 1)); then
		warn "Multiple installations of ${binary}: ${CANDIDATES[*]}"
		return 1
	fi
	if [[ -n $path && -z $PREVIOUS ]]; then
		warn "Cannot safely verify the existing installation of $binary at $path."
		return 1
	fi
	if [[ $PLATFORM == debian ]]; then
		if ! metadata_ready "$agent" && ! ensure_packages "$agent" metadata; then
			warn "Cannot prepare version checks for $agent."
			return 1
		fi
		if ! latest_debian "$agent"; then
			warn "Cannot determine the latest stable release of $agent."
			return 1
		fi
	else
		latest_brew "$agent" || {
			warn "Cannot determine the latest stable Homebrew release of $agent."
			return 1
		}
	fi
	managed_path "$agent"
	if [[ -n $PREVIOUS ]]; then
		relative=$(compare_to_stable "$PREVIOUS" "$LATEST")
		if [[ $relative != older ]]; then
			if [[ $PLATFORM == secureblue ]] && same_executable "$path" "$MANAGED"; then
				ensure_brew_runtime || return
			fi
			verify_session "$binary" "$path" || return
			RESULT=$relative
			return 0
		fi
		if ! same_executable "$path" "$MANAGED"; then
			warn "$binary is managed outside the selected channel at $path. Update it there or remove it before migrating."
			return 1
		fi
	fi
	can_update "$agent" "$binary" || {
		warn "Refusing to overwrite an unmanaged installation at $MANAGED."
		return 1
	}
	update=0
	if [[ $PLATFORM == debian ]]; then
		if ! ensure_packages "$agent" || ! install_debian "$agent"; then
			update=1
		fi
	else
		if ! ensure_brew_runtime || ! install_brew "$agent"; then
			update=1
		fi
	fi
	find_candidates "$binary"
	FINAL=""
	if ((${#CANDIDATES[@]})); then
		path=${CANDIDATES[0]}
		if [[ $path == /* ]] && safe_path "$path" && safe_path "${path%/*}"; then
			FINAL=$(version_of "$path") || true
		fi
	fi
	if ((update)); then
		warn "Installation or update of $agent failed."
		return 1
	fi
	if ((${#CANDIDATES[@]} != 1)) || ! same_executable "$path" "$MANAGED" ||
		[[ -z $FINAL || $(compare_to_stable "$FINAL" "$LATEST") != current ]]; then
		warn "$agent did not resolve to the expected installed stable version $LATEST."
		return 1
	fi
	verify_session "$binary" "$MANAGED" || return
	RESULT=installed
	if [[ -n $PREVIOUS ]]; then
		RESULT=updated
	fi
}

setup_runtime() {
	local source helper
	ORIGINAL_PATH=$PATH
	export PATH=$SYSTEM_PATH LC_ALL=C
	umask 077
	if ((EUID == 0)); then
		warn "Run this command as the target user. Debian package operations request sudo separately."
		return 1
	fi
	HOME_DIR=$(realpath -e -- "$HOME") && [[ $HOME_DIR == /* && -O $HOME_DIR ]] && safe_path "$HOME_DIR" || return
	USER_BIN=$HOME_DIR/.local/bin
	STATE_DIR=$HOME_DIR/.local/share/scripts-ai-clis
	SHELL_BIN=${SHELL:-/bin/bash}
	if [[ ! -x $SHELL_BIN ]] || ! safe_path "$SHELL_BIN"; then
		warn "Cannot safely launch the configured shell $SHELL_BIN."
		return 1
	fi
	JQ=jq
	if [[ $PLATFORM == debian ]]; then
		# Derivatives identify their Debian base in debian_version.
		local debian_version
		[[ -x /usr/bin/dpkg && -r /etc/debian_version ]] &&
			read -r debian_version </etc/debian_version || return
		if [[ $debian_version =~ ^([0-9]+)(\.|$) ]] && ((BASH_REMATCH[1] < 13)); then
			warn "Debian 13 or newer is required."
			return 1
		fi
		ARCH=$(dpkg --print-architecture) || return
		source=$(realpath -e -- "${BASH_SOURCE[0]}") || return
		for helper in "${source%/*}/release-verify" "${source%/*}/release-verify.pl"; do
			if [[ -f $helper ]]; then
				RELEASE_HELPER=$helper
				break
			fi
		done
	else
		case "$(uname -m)" in
		x86_64) ARCH=amd64 ;;
		aarch64) ARCH=arm64 ;;
		*) ARCH=$(uname -m) ;;
		esac
	fi
	case "$ARCH" in
	amd64) VENDOR_ARCH=x64 ;;
	arm64) VENDOR_ARCH=arm64 ;;
	esac
	local supported=0 agent
	for agent in "${SELECTED[@]}"; do
		if is_supported "$agent"; then
			supported=1
			break
		fi
	done
	if ((! supported)); then
		return 0
	fi
	ensure_user_dir "$HOME_DIR/.local" && ensure_user_dir "$HOME_DIR/.local/share" &&
		ensure_user_dir "$STATE_DIR" || return
	exec {LOCK_FD}<"$STATE_DIR" || return
	flock -n "$LOCK_FD" || {
		warn "An update is already running for this user."
		return 1
	}
	WORK_DIR=$(mktemp -d /tmp/scripts-ai-clis.XXXXXX) || return
	if [[ $PLATFORM == secureblue ]]; then
		locate_brew && setup_metadata_tools || return
	fi
	set_probe_path
	find_npm_prefix
}

cleanup() {
	if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
		rm -rf -- "$WORK_DIR"
	fi
}

main() {
	PLATFORM=${1:-}
	shift
	case "$PLATFORM" in
	debian | secureblue) ;;
	*) return 2 ;;
	esac
	if [[ $# -eq 1 && $1 == --help ]]; then
		usage
		return 0
	fi
	select_agents "$@" || {
		usage >&2
		return 2
	}

	local agent status=0 ready=1
	local -a summary=()
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if ! setup_runtime; then
		warn "Cannot prepare the $PLATFORM installation environment."
		ready=0
		status=1
	fi
	for agent in "${SELECTED[@]}"; do
		PREVIOUS="" LATEST="" FINAL="" RESULT=failed
		if ((ready)) && ! process_agent "$agent"; then
			status=1
		fi
		summary+=("$agent"$'\t'"${PREVIOUS:--}"$'\t'"${LATEST:--}"$'\t'"${FINAL:--}"$'\t'"$RESULT")
	done
	printf 'Agent\tPrevious\tLatest stable\tFinal\tResult\n'
	printf '%s\n' "${summary[@]}"
	return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
