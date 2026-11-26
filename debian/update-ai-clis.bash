#!/bin/bash
set -euo pipefail

# See the LICENSE file at the top of the project tree for copyright
# and license details.

script=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]}")
dir=${script%/*}
helper=$dir/update-ai-clis-linux
if [[ ! -f $helper ]]; then
	helper=$dir/../scripts/update-ai-clis-linux.bash
fi
if [[ ! -f $helper ]]; then
	printf 'update-ai-clis: cannot locate the Linux updater\n' >&2
	exit 1
fi
if ((EUID != 0)) && [[ $# != 1 || $1 != --help ]]; then
	# Agents are installed system-wide, so the whole updater runs as root.
	if [[ ! -x /usr/bin/sudo ]]; then
		printf 'update-ai-clis: sudo is required to install agents globally\n' >&2
		exit 1
	fi
	exec /usr/bin/sudo -H -- /bin/bash "$helper" debian "$@"
fi
exec /bin/bash "$helper" debian "$@"
