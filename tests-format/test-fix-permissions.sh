#!/bin/sh

set -u

# test-fix-permissions.sh
# - Regression tests for tests-format/fix-permissions.sh.
# - Creates a scratch tree in ${TMPDIR:-/tmp}, exercises the
#   fixer's classification, its --check/--dry-run/--verbose modes,
#   its .git/symlink exclusion and its error handling.
# - No root privileges are required and nothing outside the
#   scratch tree is touched.
# - Usage: ./test-fix-permissions.sh
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

assert_mode() {
	want=$1
	file=$2
	desc=$3
	# ls -ld is used because it is portable and this is a test
	# fixture with controlled names.
	# shellcheck disable=SC2012
	got=$(ls -ld "$file" 2>/dev/null | awk '{print $1}')
	case "$got" in
	*"$want"*)
		pass
		;;
	*)
		fail_test "$desc: expected mode $want, got '$got' ($file)"
		;;
	esac
}

FIXPERM=
case "$0" in
*/*) FIXPERM=$(cd "$(dirname "$0")" && pwd)/fix-permissions.sh ;;
*) FIXPERM=$(pwd)/fix-permissions.sh ;;
esac
[ -x "$FIXPERM" ] || {
	printf '%s\n' "[ERROR] cannot find fix-permissions.sh" >&2
	exit 1
}

BASE=$(mktemp -d "${TMPDIR:-/tmp}/fixperm-test-XXXXXX") || {
	printf '%s\n' "[ERROR] cannot create temp dir" >&2
	exit 1
}
trap 'rm -rf "$BASE"' EXIT HUP INT TERM

T="$BASE/tree"
mkdir -p "$T/.git" "$T/dir0700" "$T/space dir"
printf '%s\n' 'placeholder' >"$T/.git/index"
chmod 700 "$T/dir0700"

# 1. shell script 0644 -> 0755
printf '%s\n' '#!/bin/sh' 'echo hi' >"$T/s.sh"
chmod 644 "$T/s.sh"

# 2. Perl script 0644 -> 0755
printf '%s\n' '#!/usr/bin/perl' 'print 1;' >"$T/t.pl"
chmod 644 "$T/t.pl"

# 3. config file 0755 -> 0644
printf '%s\n' 'key=value' >"$T/setup.conf"
chmod 755 "$T/setup.conf"

# 4. plain text 0755 -> 0644
printf '%s\n' 'just text' >"$T/README.txt"
chmod 755 "$T/README.txt"

# 5. Makefile 0644 -> 0755
printf '%s\n' 'all:' >"$T/Makefile"
chmod 644 "$T/Makefile"

# 6. file with spaces in its name
printf '%s\n' '#!/bin/sh' 'echo hi' >"$T/space dir/with space.sh"
chmod 644 "$T/space dir/with space.sh"

# 7. symlinks: must never be modified or followed
printf '%s\n' '#!/bin/sh' 'echo hi' >"$T/real.sh"
chmod 644 "$T/real.sh"
ln -s real.sh "$T/link.sh"
ln -s setup.conf "$T/link-conf.conf"

# 8. ELF executable (portable when a C compiler is available)
if command -v cc >/dev/null 2>&1; then
	printf '%s\n' 'int main(void){return 0;}' >"$T/h.c"
	if cc -o "$T/hello" "$T/h.c" 2>/dev/null; then
		chmod 644 "$T/hello"
	fi
fi

# ---- --check mode: discrepancies -> rc 1, no modification ----
"$FIXPERM" --check "$T" >/dev/null 2>&1
assert_rc 1 $? "--check with wrong permissions exits 1"
assert_mode 'rw-r--r--' "$T/s.sh" "--check must not modify files"
assert_mode 'rwxr-xr-x' "$T/setup.conf" "--check must not modify files"
assert_mode 'rwx------' "$T/dir0700" "--check must not modify files"

# ---- --dry-run: shows changes, applies nothing ----
out=$("$FIXPERM" --dry-run "$T" 2>&1)
assert_rc 0 $? "--dry-run exits 0"
printf '%s' "$out" | grep -q 'would' ||
	fail_test "--dry-run prints 'would' lines"
assert_mode 'rw-r--r--' "$T/s.sh" "--dry-run must not modify files"
assert_mode 'rwx------' "$T/dir0700" "--dry-run must not modify files"

# ---- real fix run ----
"$FIXPERM" "$T" >/dev/null 2>&1
assert_rc 0 $? "fix run exits 0"

assert_mode 'rwxr-xr-x' "$T/s.sh" "shell script -> 0755"
assert_mode 'rwxr-xr-x' "$T/t.pl" "Perl script -> 0755"
assert_mode 'rw-r--r--' "$T/setup.conf" "config -> 0644"
assert_mode 'rw-r--r--' "$T/README.txt" "plain text -> 0644"
assert_mode 'rwxr-xr-x' "$T/Makefile" "Makefile -> 0755"
assert_mode 'rwxr-xr-x' "$T/dir0700" "directory -> 0755"
assert_mode 'rwxr-xr-x' "$T/space dir/with space.sh" "spaced name -> 0755"
if [ -f "$T/hello" ]; then
	assert_mode 'rwxr-xr-x' "$T/hello" "ELF executable -> 0755"
fi

# symlinks still symlinks; targets are classified by their own
# content (script target -> 0755, config target stays 0644)
if [ -L "$T/link.sh" ] && [ -L "$T/link-conf.conf" ]; then
	pass
else
	fail_test "symlink was modified/removed"
fi
assert_mode 'rwxr-xr-x' "$T/real.sh" \
	"symlink target script classified by content (0755)"
assert_mode 'rw-r--r--' "$T/setup.conf" \
	"symlink target config stays 0644"

# .git untouched (still writable group/owner per its original mode)
if [ -d "$T/.git" ]; then
	pass
else
	fail_test ".git directory was removed"
fi

# ---- --check after fix: clean, rc 0 ----
"$FIXPERM" --check "$T" >/dev/null 2>&1
assert_rc 0 $? "--check after fix exits 0"

# ---- verbose mode prints classification ----
out=$("$FIXPERM" --verbose --check "$T" 2>&1)
printf '%s' "$out" | grep -q 'ok 755' ||
	fail_test "--verbose prints 'ok' lines for correct files"
printf '%s' "$out" | grep -q 'Perl script' ||
	fail_test "--verbose prints the classification"

# ---- individual chmod failures do not abort the run ----
T2="$BASE/tree2"
mkdir -p "$T2/bin"
printf '%s\n' '#!/bin/sh' 'echo hi' >"$T2/good.sh"
printf '%s\n' '#!/bin/sh' 'echo hi' >"$T2/failme.sh"
chmod 644 "$T2/good.sh" "$T2/failme.sh"
real_chmod=$(command -v chmod)
cat >"$T2/bin/chmod" <<EOF
#!/bin/sh
case " \$* " in
*failme.sh*) exit 1 ;;
esac
exec $real_chmod "\$@"
EOF
chmod 755 "$T2/bin/chmod"
out=$(PATH="$T2/bin:$PATH" "$FIXPERM" "$T2" 2>&1)
assert_rc 1 $? "chmod failure makes the run exit 1"
printf '%s' "$out" | grep -q 'chmod' ||
	fail_test "chmod failure is reported"
assert_mode 'rwxr-xr-x' "$T2/good.sh" \
	"other files still fixed after a chmod failure"

printf '%s\n' \
	"[INFO] test-fix-permissions.sh:" \
	" $npass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
	exit 1
fi
exit 0
