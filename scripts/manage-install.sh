#!/bin/sh
#
# Install, uninstall, format, and help operations for the repository Makefile.
# The Makefile passes its declarative lists and paths through the environment;
# this helper owns the loops and error handling.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

set -eu

INFO=${INFO:-==>}
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"

log() {
	printf '%s %s\n' "$INFO" "$*"
}

die() {
	printf '%s ERROR: %s\n' "$INFO" "$*" >&2
	exit 1
}

strip_extension() {
	name=${1##*/}
	name=${name%.bash}
	name=${name%.ksh}
	name=${name%.sh}
	name=${name%.pl}
	printf '%s\n' "$name"
}

install_list() {
	list=$1
	destination=$2
	[ -n "$list" ] || return 0
	install -d "$destination" || die "cannot create $destination"
	# The list is a whitespace-separated Make variable; splitting is intended.
	# shellcheck disable=SC2086
	for source in $list; do
		name=$(strip_extension "$source")
		log "Installing $source -> $destination/$name"
		install -m 0755 "$source" "$destination/$name" ||
			die "cannot install $source"
	done
}

install_wrapper_links() {
	wrapper="$DESTBIN/sudo-wrapper"
	[ -x "$wrapper" ] || return 0
	for link in sudo visudo sudoedit; do
		target="$DESTBIN/$link"
		if [ -e "$target" ] && [ ! -L "$target" ]; then
			die "$target exists and is not a wrapper symlink; refusing to overwrite"
		fi
		log "Symlinking $target -> $wrapper"
		ln -sf "$wrapper" "$target" || die "cannot link $target"
	done
}

install_debian() {
	log 'Installing Debian helpers'
	install_list "${DEBIAN_SCRIPTS:?}" "$DESTBIN"
	log 'Debian helpers installed'
}

install_openbsd() {
	log 'Installing OpenBSD helpers'
	install_list "${OPENBSD_SCRIPTS:?}" "$DESTBIN"
	install_wrapper_links
	log 'OpenBSD helpers installed'
}

install_secureblue_units() {
	[ -d secureblue/systemd ] || return 0
	install -d -m 0755 "$DEST_SYSTEMD_USER" ||
		die "cannot create $DEST_SYSTEMD_USER"
	for source in secureblue/systemd/*.service; do
		[ -f "$source" ] || continue
		log "Installing $source -> $DEST_SYSTEMD_USER/${source##*/}"
		install -m 0644 "$source" "$DEST_SYSTEMD_USER/${source##*/}" ||
			die "cannot install $source"
	done
}

install_secureblue() {
	log 'Installing SecureBlue helpers'
	install_list "${SECUREBLUE_SCRIPTS:?}" "$DESTBIN"
	install_secureblue_units
	install_wrapper_links
	log 'SecureBlue helpers installed'
}

unlock_shell_dir() {
	command -v chattr >/dev/null 2>&1 ||
		die 'chattr not found'
	if [ -e "$BASH_CONF_DST_DIR" ]; then
		log "Removing immutable attribute from $BASH_CONF_DST_DIR"
		chattr -i "$BASH_CONF_DST_DIR" 2>/dev/null || true
	fi
	mkdir -p "$BASH_CONF_DST_DIR" ||
		die "cannot create $BASH_CONF_DST_DIR"
}

restore_shell_dir() {
	status=$?
	trap - 0
	log "Restoring immutable attribute on $BASH_CONF_DST_DIR"
	chattr +i "$BASH_CONF_DST_DIR" || status=1
	exit "$status"
}

copy_shell_files() {
	trap restore_shell_dir 0
	# shellcheck disable=SC2086
	for source in ${BASH_CONF_FILES:-}; do
		log "Installing $source -> $BASH_CONF_DST_DIR/${source##*/}"
		install -m 0644 "$source" "$BASH_CONF_DST_DIR/${source##*/}" ||
			die "cannot install $source"
	done
}

install_shell_bash() {
	log "Installing shell aliases for SecureBlue user '${SECUREBLUE_USER:-}'"
	log 'SecureBlue shell aliases installed'
}

install_perl() {
	log 'Installing perl helpers'
	install -d "$DESTBIN" || die "cannot create $DESTBIN"
	programs=$(grep -Ev '^[[:space:]]*(#|$)' "$PERL_PROGRAMS_MANIFEST") ||
		die "cannot read $PERL_PROGRAMS_MANIFEST"
	# shellcheck disable=SC2086
	for name in $programs; do
		source="perl/$name"
		output=${name%.pl}
		log "Installing $source -> $DESTBIN/$output"
		install -m 0755 "$source" "$DESTBIN/$output" ||
			die "cannot install $source"
		install -m 0644 VERSION "$DESTBIN/$output.version" ||
			die "cannot install VERSION"
	done
	log 'Perl helpers installed'
}

install_tests_format() {
	log 'Installing Tests/Format scripts'
	install -d "$DEST_TESTS_FORMAT" ||
		die "cannot create $DEST_TESTS_FORMAT"
	for cfg in \
		"tests-format/clang-format.yaml:clang-format-all" \
		"tests-format/clang-tidy.yaml:clang-tidy-all" \
		"tests-format/fourmolu-all.yaml:fourmolu-all"; do
		source=${cfg%%:*}
		destination=${cfg##*:}
		install -m 0644 "$source" "$DEST_TESTS_FORMAT/$destination" ||
			die "cannot install $source"
	done
	# shellcheck disable=SC2086
	for source in ${TESTS_FORMAT_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		log "Installing $source -> $DEST_TESTS_FORMAT/$name"
		install -m 0755 "$source" "$DEST_TESTS_FORMAT/$name" ||
			die "cannot install $source"
		if [ "${TESTS_FORMAT_LINKS:-0}" = "1" ]; then
			install -d "$DESTBIN" || die "cannot create $DESTBIN"
			ln -sf "$DEST_TESTS_FORMAT/$name" "$DESTBIN/$name" ||
				die "cannot link $name"
		fi
	done
	log "Tests/Format helpers installed in $DEST_TESTS_FORMAT"
}

uninstall_debian() {
	# shellcheck disable=SC2086
	for source in ${DEBIAN_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		rm -f -- "$DESTBIN/$name"
	done
	log "Debian helpers removed from $DESTBIN"
}

uninstall_openbsd() {
	# shellcheck disable=SC2086
	for source in ${OPENBSD_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		rm -f -- "$DESTBIN/$name"
	done
	for link in sudo visudo sudoedit; do
		[ -L "$DESTBIN/$link" ] && rm -f -- "$DESTBIN/$link"
	done
	log "OpenBSD helpers removed from $DESTBIN"
}

uninstall_secureblue() {
	# shellcheck disable=SC2086
	for source in ${SECUREBLUE_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		rm -f -- "$DESTBIN/$name"
	done
	for source in secureblue/systemd/*.service; do
		[ -f "$source" ] || continue
		rm -f -- "$DEST_SYSTEMD_USER/${source##*/}"
	done
	for link in sudo visudo sudoedit; do
		[ -L "$DESTBIN/$link" ] && rm -f -- "$DESTBIN/$link"
	done
	log 'SecureBlue helpers and units removed'
}

uninstall_shell() {
	if [ -e "$BASH_CONF_DST_DIR" ]; then
		chattr -i "$BASH_CONF_DST_DIR" 2>/dev/null || true
	fi
	# shellcheck disable=SC2086
	for source in ${BASH_CONF_FILES:-}; do
		rm -f -- "$BASH_CONF_DST_DIR/${source##*/}"
	done
	if [ -d "$BASH_CONF_DST_DIR" ]; then
		chattr +i "$BASH_CONF_DST_DIR" 2>/dev/null || true
	fi
	log 'Shell helpers removed'
}

uninstall_perl() {
	programs=$(grep -Ev '^[[:space:]]*(#|$)' "$PERL_PROGRAMS_MANIFEST") ||
		die "cannot read $PERL_PROGRAMS_MANIFEST"
	# shellcheck disable=SC2086
	for name in $programs; do
		output=${name%.pl}
		rm -f -- "$DESTBIN/$output" "$DESTBIN/$output.version"
	done
	log "Perl helpers removed from $DESTBIN"
}

uninstall_tests_format() {
	# shellcheck disable=SC2086
	for source in ${TESTS_FORMAT_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		rm -f -- "$DEST_TESTS_FORMAT/$name"
		if [ "${TESTS_FORMAT_LINKS:-0}" = "1" ]; then
			rm -f -- "$DESTBIN/$name"
		fi
	done
	for name in clang-format-all clang-tidy-all fourmolu-all; do
		rm -f -- "$DEST_TESTS_FORMAT/$name"
	done
	log 'Tests/Format helpers removed'
}

format_sources() {
	status=0
	for validator in shell perl make; do
		/bin/sh "tests-format/validate-$validator.sh" --format . || status=1
	done
	exit "$status"
}

show_help() {
	cat <<EOF
Usage: make [target]

Targets:
  all                      Install the OS-independent runtime helper (Perl only)
  install-debian           Install Debian helper scripts into ${DESTBIN}
  install-openbsd          Install OpenBSD helper scripts into ${DESTBIN}
  install-secureblue       Install SecureBlue helpers into ${DESTBIN} and units into ${DEST_SYSTEMD_USER}
  install-shell            Install SecureBlue Bash shell helpers
  install-shell-bash       Install shell aliases into ${BASH_CONF_DST_DIR} (with chattr -i/+i)
  install-shell-openbsd    Guidance for installing shell helpers on OpenBSD
  install-perl             Install perl helper scripts into ${DESTBIN}
  install-tests-format     Install developer validators/formatters into ${DEST_TESTS_FORMAT}
  uninstall-debian         Remove Debian helpers from ${DESTBIN}
  uninstall-openbsd        Remove OpenBSD helpers and wrapper links
  uninstall-secureblue     Remove SecureBlue helpers and user units
  uninstall-perl           Remove Perl helpers
  uninstall-tests-format   Remove developer validators/formatters
  uninstall-shell          Remove installed shell helpers
  check                    Run validation without formatting or caches
  format                   Apply formatters (reports drift as failure)
  test                     Run checks and isolated regression tests
  test-validate            Run only read-only validators
  test-manpages            Run mandoc lint when mandoc is installed
  test-regression          Run only the regression tests
  test-tooling             Run validator/installer temporary-tree regressions
  test-delivery            Run delivery/release transaction regressions
  test-agent-knowledge     Run the agent-knowledge validator contract tests
  fix-permissions          Correct file modes from file(1) content
  check-permissions        Report wrong file modes (read-only, rc != 0)
  check-agent-knowledge    Enforce agent/skills synchronization for repository changes
  clean                    No-op clean target
  help                     Show this help

Variables: PREFIX=${PREFIX} DESTDIR=${DESTDIR} BINDIR=${BINDIR} SYSTEMD_USER_UNIT_DIR=${SYSTEMD_USER_UNIT_DIR} TESTS_FORMAT_DIR=${TESTS_FORMAT_DIR} TESTS_FORMAT_LINKS=${TESTS_FORMAT_LINKS}
EOF
}

command=${1:-}
shift || true
case "$command" in
install-debian) install_debian ;;
install-openbsd) install_openbsd ;;
install-secureblue) install_secureblue ;;
install-shell-bash-unlock) unlock_shell_dir ;;
install-shell-bash-copy) copy_shell_files ;;
install-shell-bash) install_shell_bash ;;
install-shell) log 'Shell helpers installed' ;;
install-shell-openbsd)
	log 'OpenBSD does not support chattr immutable flags like Linux.'
	log 'Copy shell/aliases.bash manually to your preferred shell profile location.'
	;;
install-perl) install_perl ;;
install-tests-format) install_tests_format ;;
uninstall-debian) uninstall_debian ;;
uninstall-openbsd) uninstall_openbsd ;;
uninstall-secureblue) uninstall_secureblue ;;
uninstall-shell) uninstall_shell ;;
uninstall-perl) uninstall_perl ;;
uninstall-tests-format) uninstall_tests_format ;;
format) format_sources ;;
help) show_help ;;
*)
	die "unknown operation: ${command:-<none>}"
	;;
esac
