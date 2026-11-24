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
exec /bin/bash "$helper" secureblue "$@"
