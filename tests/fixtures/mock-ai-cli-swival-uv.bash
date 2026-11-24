#!/bin/bash
# Exercise the Swival delivery adapter without touching managed software.
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -euo pipefail

if [[ $1 == --version ]]; then
	printf '%s\n' "uv ${FIXTURE_UV_VERSION:-0.13.9}"
	exit
fi

[[ ${UV_INDEX_URL-unset} == unset && ${PIP_INDEX_URL-unset} == unset &&
	${UV_PYTHON_INSTALL_MIRROR-unset} == unset && ${HTTPS_PROXY:-} == fixture-proxy &&
	$UV_PYTHON_INSTALL_DIR == "$FIXTURE_ROOT/home/state/swival-python" &&
	$1 == --no-config && $2 == --no-progress ]] || exit 1
shift 2
python=$UV_PYTHON_INSTALL_DIR/python
case "$1:$2" in
python:install)
	[[ $* == 'python install 3.14 --upgrade --no-bin' ]]
	printf 'python update\n' >>"$FIXTURE_ROOT/events"
	printf '#!/bin/sh\nprintf "Python 3.14.2\\n"\n' >"$python"
	chmod 0700 "$python"
	;;
python:find)
	[[ $* == 'python find 3.14 --managed-python' ]]
	printf '%s\n' "$python"
	;;
tool:install)
	[[ $* == 'tool install --python 3.14 --managed-python --only-binary :all: --default-index https://pypi.org/simple swival @ https://files.pythonhosted.org/packages/'* ]]
	wheel=${!#}
	version=${wheel##*/swival-}
	version=${version%%-py3-*}
	digest=${wheel##*#sha256=}
	[[ $digest == 1111111111111111111111111111111111111111111111111111111111111111 ]]
	printf 'tool install %s\n' "$version" >>"$FIXTURE_ROOT/events"
	[[ ${FIXTURE_SWIVAL_INSTALL_FAIL:-} != 1 ]] || exit 1
	mkdir -p -- "$UV_TOOL_DIR/swival/bin"
	bin=$UV_TOOL_DIR/swival/bin/swival
	printf '#!/bin/sh\nprintf "swival %s\\n"\n' "$version" >"$bin"
	chmod 0700 "$bin"
	ln -s -- "$bin" "$UV_TOOL_BIN_DIR/swival"
	;;
*) exit 1 ;;
esac
