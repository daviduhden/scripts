#!/bin/bash
# Shared user-side MCP registration for the POSIX xerj installers.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

XERJ_CLIENTS=()
declare -A XERJ_COMMANDS=()
XERJ_CLIENT_PATH=''
XERJ_BREW_UID=0
XERJ_ALL=0
XERJ_EXPLICIT=0
XERJ_BINARY_ONLY=0
XERJ_URL_SELECTED=0
NODE_URL=${XERJ_URL:-http://127.0.0.1:9200}

xerj_usage_error() {
	printf 'update-xerj: %s\n' "$1" >&2
	exit 2
}

xerj_client_help() {
	cat <<'HELP'
  all                  Register MCP with all installed agents (default)
  AGENT ...            Register MCP only with the selected installed agents
                       opencode, codex, crush, copilot-cli, claude, swival
  --binary-only        Skip agent configuration
  --url URL            Node endpoint (XERJ_URL or http://127.0.0.1:9200)
HELP
}

xerj_select() {
	local client=${1#--} selected
	case "$client" in
	all) XERJ_ALL=1 ;;
	binary-only) XERJ_BINARY_ONLY=1 ;;
	*)
		for selected in "${XERJ_CLIENTS[@]}"; do
			[[ $selected != "$client" ]] || return 0
		done
		XERJ_CLIENTS+=("$client")
		;;
	esac
}

xerj_validate_selection() {
	local endpoint='^https?://(\[[a-fA-F0-9:.]+\]|[A-Za-z0-9._-]+)(:([0-9]{1,5}))?(/[A-Za-z0-9._~/-]*)?$'
	if (((XERJ_ALL + XERJ_BINARY_ONLY) > 1 || ((XERJ_ALL || XERJ_BINARY_ONLY) && ${#XERJ_CLIENTS[@]}))); then
		printf 'update-xerj: select all, --binary-only, or named agents\n' >&2
		return 2
	fi
	if ((XERJ_BINARY_ONLY && XERJ_URL_SELECTED == 0)); then
		return 0
	fi
	if [[ ! $NODE_URL =~ $endpoint ]]; then
		printf 'update-xerj: invalid HTTP(S) node endpoint\n' >&2
		return 2
	fi
	local port=${BASH_REMATCH[3]}
	if [[ -n $port ]] && ((10#$port < 1 || 10#$port > 65535)); then
		printf 'update-xerj: invalid node port\n' >&2
		return 2
	fi
}

xerj_safe_path() {
	local path=$1 owner mode
	while :; do
		read -r owner mode < <(stat -Lc '%u %a' -- "$path") || return
		[[ $owner == 0 || $owner == "$EUID" || $owner == "$XERJ_BREW_UID" ]] || return 1
		(((8#$mode & 022) == 0)) || return 1
		[[ $path != / ]] || return 0
		path=${path%/*}
		path=${path:-/}
	done
}

xerj_client_path() {
	local dir resolved
	local -a entries
	XERJ_BREW_UID=$(id -u linuxbrew 2>/dev/null) || XERJ_BREW_UID=0
	IFS=: read -r -a entries <<<"$XERJ_USER_PATH:$HOME/.local/bin:$HOME/.opencode/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
	for dir in "${entries[@]}"; do
		[[ $dir == /* && -d $dir ]] || continue
		resolved=$(realpath -e -- "$dir") || continue
		xerj_safe_path "$dir" || continue
		xerj_safe_path "$resolved" || continue
		case ":$XERJ_CLIENT_PATH:" in
		*":$dir:"*) ;;
		*) XERJ_CLIENT_PATH=${XERJ_CLIENT_PATH:+$XERJ_CLIENT_PATH:}$dir ;;
		esac
	done
}

xerj_find_clients() {
	local client command path resolved missing=0
	local -a agents
	((XERJ_BINARY_ONLY == 0)) || return 0
	xerj_client_path
	if ((${#XERJ_CLIENTS[@]})); then
		agents=("${XERJ_CLIENTS[@]}")
		XERJ_EXPLICIT=1
	else
		agents=(opencode codex crush copilot-cli claude swival)
	fi
	for client in "${agents[@]}"; do
		command=$client
		if [[ $client == copilot-cli ]]; then command=copilot; fi
		path=$(PATH="$XERJ_CLIENT_PATH" type -P -- "$command") || path=''
		# Skip aliases and relative paths from the current directory.
		if [[ $path == /* && -f $path && -x $path ]] &&
			resolved=$(realpath -e -- "$path") && xerj_safe_path "$resolved"; then
			XERJ_COMMANDS[$client]=$path
		elif ((XERJ_EXPLICIT)); then
			printf 'update-xerj: requested agent %s is not installed or available on PATH\n' "$client" >&2
			missing=1
		fi
	done
	XERJ_CLIENTS=("${agents[@]}")
	((missing == 0))
}

# Codex owns its configuration file. Read its registration through the CLI
# and confirm the result through the same interface after adding an entry.
xerj_configure_codex() {
	local command=$1 helper=$2 binary=$3 perl=$4 payload action
	if payload=$(/usr/bin/timeout --kill-after=3s 20s "$command" mcp get xerj --json 2>/dev/null); then
		action=$(printf '%s\n' "$payload" | "$perl" "$helper" codex-check "$binary" "$NODE_URL") || return
	else
		payload=$(/usr/bin/timeout --kill-after=3s 20s "$command" mcp get xerj --json 2>&1 >/dev/null) && return 1
		if ! /usr/bin/grep -Fqx -e "Error: No MCP server named 'xerj' found." -e "No MCP server named 'xerj' found." <<<"$payload"; then
			return 1
		fi
		action=add
	fi
	if [[ $action == current ]]; then return 0; fi
	[[ $action == add ]] || return 1
	/usr/bin/timeout --kill-after=3s 20s "$command" mcp add xerj -- "$binary" mcp --url "$NODE_URL" >/dev/null 2>&1 || return
	payload=$(/usr/bin/timeout --kill-after=3s 20s "$command" mcp get xerj --json 2>/dev/null) || return
	action=$(printf '%s\n' "$payload" | "$perl" "$helper" codex-check "$binary" "$NODE_URL") || return
	[[ $action == current ]]
}

xerj_config_kind() {
	local client=$1 command=$2 output line major minor
	case "$client" in
	opencode | crush)
		output=$(/usr/bin/timeout --kill-after=3s 20s "$command" --version 2>/dev/null) || return
		;;
	*)
		printf '%s\n' "$client"
		return
		;;
	esac
	if [[ $client == opencode ]]; then
		[[ $output =~ ^(opencode\ )?v?([0-9]+)\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+-]+)?$ ]] || return 1
		major=${BASH_REMATCH[2]}
		[[ $major == 1 || $major == 2 ]] || return 2
		printf 'opencode%s\n' "$major"
		return
	fi
	# Crush added the global Bash configuration loader in v0.88.0.
	while IFS= read -r line; do
		if [[ $line =~ ^([Cc]rush\ )?(version\ )?v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.[0-9]+([-+][A-Za-z0-9.+-]+)?$ ]]; then
			major=${BASH_REMATCH[3]} minor=${BASH_REMATCH[4]}
			if [[ $major != 0 || ${#minor} -gt 2 || $minor -ge 88 ]]; then
				printf 'crush\n'
				return
			fi
			return 2
		fi
	done <<<"$output"
	return 1
}

xerj_configure_clients() {
	local binary=$1 client command helper kind perl status failed=0
	local -a client_args
	((XERJ_BINARY_ONLY == 0)) || return 0
	[[ $EUID -ne 0 ]] || return 1
	local directory=${BASH_SOURCE[0]%/*}
	for helper in "$directory/xerj-config" "$directory/xerj-config.pl" "$directory/../secureblue/xerj-config.pl"; do
		[[ ! -f $helper ]] || break
	done
	perl=$(type -P perl) || perl=''
	if ((${#XERJ_COMMANDS[@]})) && [[ ! -f $helper || -z $perl ]]; then
		printf 'update-xerj: Perl and the xerj-config helper are required for agent configuration\n' >&2
		return 1
	fi
	# Retain the calling user's PATH for wrappers and their runtimes only in this
	# unprivileged configuration phase. Use the actual xerj path for all agents.
	local PATH="$XERJ_CLIENT_PATH"
	for client in "${XERJ_CLIENTS[@]}"; do
		command=${XERJ_COMMANDS[$client]:-}
		if [[ -z $command ]]; then
			printf 'xerj MCP %-12s skipped (not installed)\n' "$client"
			continue
		fi
		if [[ $client == codex ]]; then
			if (cd "$HOME" && xerj_configure_codex "$command" "$helper" "$binary" "$perl"); then
				printf 'xerj MCP %-12s configured\n' "$client"
				continue
			fi
		else
			if kind=$(xerj_config_kind "$client" "$command"); then
				status=0
			else
				status=$?
			fi
			if ((status)); then
				if ((status == 2 && XERJ_EXPLICIT == 0)); then
					printf 'xerj MCP %-12s skipped (unsupported client version)\n' "$client"
				else
					printf 'xerj MCP %-12s failed (unsupported or unknown client version)\n' "$client" >&2
					failed=1
				fi
				continue
			fi
			client_args=("$kind" "$binary" "$NODE_URL")
			if [[ $kind == swival ]]; then client_args+=("$command"); fi
			if "$perl" "$helper" "${client_args[@]}"; then
				printf 'xerj MCP %-12s configured\n' "$client"
				continue
			fi
		fi
		printf 'xerj MCP %-12s failed\n' "$client" >&2
		failed=1
	done
	return "$failed"
}
