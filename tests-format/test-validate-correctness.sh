#!/bin/sh

set -u

# test-validate-correctness.sh
# - Regression tests for tests-format/validate-correctness.sh.
# - Builds a scratch tree with fixture scripts for several
#   targets and checks that the validator detects the expected
#   problems (GNU-only options in OpenBSD scripts, wrong
#   shebangs, nonexistent commands) without false ERRORs on
#   valid Linux scripts.
# - No root privileges are required; nothing outside the scratch
#   tree is touched.
# - Usage: ./test-validate-correctness.sh
#   Exit status: 0 if all tests pass, 1 otherwise.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

fail=0
npass=0

pass() {
	npass=$((npass + 1))
}

fail_test() {
	fail=$((fail + 1))
	printf '%s\n' "[FAIL] $*" >&2
}

# assert_rc <want> <desc> -- checks $?
assert_rc() {
	want=$1
	got=$2
	desc=$3
	if [ "$want" = "$got" ]; then
		pass
	else
		fail_test "$desc: expected rc=$want, got rc=$got"
	fi
}

# assert_error <file-substring> <output> <desc>
assert_error() {
	match=$1
	shift
	out=$1
	shift
	desc=$1
	if printf '%s' "$out" | grep -q "ERROR $match"; then
		pass
	else
		fail_test "$desc: no ERROR for '$match'"
	fi
}

# assert_no_error <file-substring> <output> <desc>
assert_no_error() {
	match=$1
	shift
	out=$1
	shift
	desc=$1
	if printf '%s' "$out" | grep -q "ERROR $match"; then
		fail_test "$desc: unexpected ERROR for '$match'"
	else
		pass
	fi
}

VALIDATE=
case "$0" in
*/*) VALIDATE=$(cd "$(dirname "$0")" && pwd)/validate-correctness.sh ;;
*) VALIDATE=$(pwd)/validate-correctness.sh ;;
esac
[ -x "$VALIDATE" ] || {
	printf '%s\n' "[ERROR] cannot find validate-correctness.sh" >&2
	exit 1
}

BASE=$(mktemp -d "${TMPDIR:-/tmp}/vcorr-test-XXXXXX") || {
	printf '%s\n' "[ERROR] cannot create temp dir" >&2
	exit 1
}
trap 'rm -rf "$BASE"' EXIT HUP INT TERM

T="$BASE/tree"
mkdir -p "$T/openbsd" "$T/debian"

# ---- OpenBSD fixture: GNU-only find -printf ----
cat >"$T/openbsd/gnu-only.ksh" <<'EOF'
#!/bin/ksh
set -eu
find . -printf '%p\n'
EOF

# ---- OpenBSD fixture: multi-line mktemp WITH a template is
#      fine; without a template it must be an ERROR ----
cat >"$T/openbsd/mktemp-ok.ksh" <<'EOF'
#!/bin/ksh
set -eu
t="$(mktemp -d \
	/tmp/mktemp-test-XXXXXX)"
EOF
cat >"$T/openbsd/mktemp-bad.ksh" <<'EOF'
#!/bin/ksh
set -eu
t="$(mktemp -d \
	/tmp)"
EOF

# ---- Debian fixture: same option is fine on Linux (INFO) ----
cat >"$T/debian/gnu-ok.bash" <<'EOF'
#!/bin/bash
set -eu
find . -printf '%p\n'
EOF

# ---- Wrong shebang: bash content with sh shebang ----
cat >"$T/debian/wrong-shebang.bash" <<'EOF'
#!/bin/sh
set -eu
[[ -f /etc/os-release ]] && echo yes
EOF

# ---- Warning-only fixture (rm -rf with unquoted operand) ----
cat >"$T/debian/warn-only.bash" <<'EOF'
#!/bin/bash
set -eu
rm -rf /var/tmp/something
EOF

# ---- pipefail + early-exit pipeline consumer (head) ----
cat >"$T/debian/pipe-head.bash" <<'EOF'
#!/bin/bash
set -euo pipefail
ps -eo pid,cmd | head -n 3
EOF

# ---- pipefail + multi-line pipeline ending in head ----
cat >"$T/debian/pipe-head-ml.bash" <<'EOF'
#!/bin/bash
set -euo pipefail
ps -eo pid,cmd |
	head -n 3
EOF

# ---- pipefail + early-exit pipeline consumer (grep -q) ----
cat >"$T/debian/pipe-grep.bash" <<'EOF'
#!/bin/bash
set -euo pipefail
apt-cache policy | grep -q foo
EOF

# ---- same pipeline but no pipefail: no SIGPIPE finding ----
cat >"$T/debian/pipe-safe.bash" <<'EOF'
#!/bin/bash
set -eu
ps -eo pid,cmd | head -n 3
EOF

# ---- Host-family fixture with a nonexistent command ----
HOST_FAMILY=
case "$(uname -s)" in
OpenBSD) HOST_FAMILY=openbsd ;;
Linux)
	os_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
		tr -d '"')
	os_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null |
		tr -d '"')
	case " $os_id $os_like " in
	*" fedora "*) HOST_FAMILY=secureblue ;;
	*" debian "* | *" ubuntu "*) HOST_FAMILY=debian ;;
	esac
	;;
esac

if [ -n "$HOST_FAMILY" ]; then
	mkdir -p "$T/$HOST_FAMILY"
	cat >"$T/$HOST_FAMILY/bogus-cmd.bash" <<'EOF'
#!/bin/bash
set -eu
definitely-not-a-real-command-xyz --flag
EOF
fi

# ---- Run with --target all (static checks for everything) ----
out=$("$VALIDATE" --target all "$T" 2>&1)
rc=$?
assert_error 'openbsd/gnu-only.ksh' "$out" \
	"GNU-only find -printf flagged in OpenBSD fixture"
assert_no_error 'openbsd/mktemp-ok.ksh' "$out" \
	"multi-line mktemp WITH template not flagged"
assert_error 'openbsd/mktemp-bad.ksh' "$out" \
	"multi-line mktemp WITHOUT template flagged"
assert_no_error 'debian/gnu-ok.bash' "$out" \
	"GNU find -printf not an ERROR in Debian fixture"
assert_error 'debian/wrong-shebang.bash' "$out" \
	"wrong shebang detected"
if [ -n "$HOST_FAMILY" ]; then
	assert_error "$HOST_FAMILY/bogus-cmd.bash" "$out" \
		"nonexistent command detected on host family"
fi
assert_rc 1 "$rc" "--target all with ERRORs exits 1"

# pipefail SIGPIPE rules: warnings on pipefail scripts, silence
# on the same pipeline without pipefail
if printf '%s' "$out" | grep -q 'WARNING debian/pipe-head.bash'; then
	pass
else
	fail_test "pipefail + | head not flagged"
fi
if printf '%s' "$out" | grep -q 'WARNING debian/pipe-head-ml.bash'; then
	pass
else
	fail_test "pipefail + multi-line | head not flagged"
fi
if printf '%s' "$out" | grep -q 'WARNING debian/pipe-grep.bash'; then
	pass
else
	fail_test "pipefail + | grep -q not flagged"
fi
if printf '%s' "$out" | grep -q 'WARNING debian/pipe-safe.bash'; then
	fail_test "pipeline without pipefail falsely flagged"
else
	pass
fi

# ---- The OpenBSD fixture alone must be flagged from a Linux
#      host (target different from host) ----
out=$("$VALIDATE" --target openbsd "$T" 2>&1)
rc=$?
assert_error 'openbsd/gnu-only.ksh' "$out" \
	"non-host target still analyzed statically"
assert_rc 1 "$rc" "non-host target with ERRORs exits 1"

# ---- WARNING-only fixture: rc 0 in normal mode ----
T2="$BASE/tree2"
mkdir -p "$T2/debian"
cat >"$T2/debian/warn-only.bash" <<'EOF'
#!/bin/bash
set -eu
rm -rf /var/tmp/something
EOF
out=$("$VALIDATE" --target debian "$T2" 2>&1)
rc=$?
printf '%s' "$out" | grep -q 'WARNING debian/warn-only.bash' ||
	fail_test "WARNING expected for unbounded rm -rf"
assert_rc 0 "$rc" "WARNING alone exits 0 (normal mode)"

# ---- --strict fails on WARNINGs ----
"$VALIDATE" --target debian --strict "$T2" >/dev/null 2>&1
assert_rc 1 $? "--strict with WARNINGs exits 1"

# ---- --strict passes on a clean tree ----
T3="$BASE/tree3"
mkdir -p "$T3/debian"
cat >"$T3/debian/clean.bash" <<'EOF'
#!/bin/bash
set -eu
echo ok
EOF
"$VALIDATE" --target debian --strict "$T3" >/dev/null 2>&1
assert_rc 0 $? "--strict with clean tree exits 0"

# ---- JSON output is valid (with and without findings) ----
if command -v python3 >/dev/null 2>&1; then
	out=$("$VALIDATE" --target all --format json "$T" 2>/dev/null)
	if printf '%s' "$out" | python3 -c \
		'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
		pass
	else
		fail_test "JSON output is not valid JSON (with findings)"
	fi
	out=$("$VALIDATE" --target debian --format json "$T3" 2>/dev/null)
	if printf '%s' "$out" | python3 -c \
		'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
		pass
	else
		fail_test "JSON output is not valid JSON (clean tree)"
	fi
fi

# ---- --quiet prints only ERRORs ----
out=$("$VALIDATE" --target all --quiet "$T" 2>/dev/null)
if printf '%s' "$out" | grep -q 'WARNING'; then
	fail_test "--quiet still prints WARNINGs"
else
	pass
fi

printf '%s\n' \
	"[INFO] test-validate-correctness.sh:" \
	" $npass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
	exit 1
fi
exit 0
