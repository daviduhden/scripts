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

managed_signature() {
	if [ -L "$1" ]; then
		target=$(readlink "$1") || return 1
		printf 'link %s\n' "$target"
	elif [ -f "$1" ]; then
		cksum <"$1"
	else
		return 1
	fi
}

# The record path identifies the installation family. Its contents capture
# the link target or a portable checksum and byte count for drift detection.
managed_entry() (
	phase=$1
	mode=$2
	source=$3
	destination=$4
	name=$5
	file="$destination/$name"
	if [ "$mode" != link ] && [ ! -f "$source" ]; then
		die "missing installation source: $source"
	fi
	records="$destination/.scripts-install"
	record="$records/$install_family/$name"

	if [ -L "$records" ] || [ -L "$records/$install_family" ]; then
		die "invalid install records directory: $records"
	fi
	if [ -e "$file" ] || [ -L "$file" ]; then
		if [ -L "$file" ] && [ "$mode" != link ]; then
			die "unexpected destination type: $file"
		fi
		actual=$(managed_signature "$file") ||
			die "unexpected destination type: $file"
		if [ ! -f "$record" ] || [ -L "$record" ] ||
			[ "$(cat "$record")" != "$actual" ]; then
			if [ "${ADOPT_LEGACY:-0}" != 1 ] || [ -e "$record" ] ||
				[ -L "$record" ]; then
				die "destination is unmanaged or modified: $file"
			fi
			if [ "$mode" = link ]; then
				case "$actual" in
				"link $source" | "link $destination/$source") : ;;
				*) die "destination is not the expected wrapper link: $file" ;;
				esac
			elif [ -L "$file" ] || ! cmp -s "$source" "$file"; then
				die "destination does not match the source: $file"
			fi
		fi
	fi
	if [ -L "$record" ] || { [ -e "$record" ] && [ ! -f "$record" ]; }; then
		die "invalid install record: $record"
	fi
	for other_record in "$records"/*/"$name"; do
		[ "$other_record" != "$record" ] || continue
		if [ -e "$other_record" ] || [ -L "$other_record" ]; then
			die "destination belongs to another install target: $file"
		fi
	done
	[ "$phase" = publish ] || return 0

	install -d "$destination" "$records/$install_family" ||
		die "cannot create installation directories for $file"
	stage=$(mktemp -d "$destination/.scripts-stage.XXXXXXXX")
	trap 'rm -f "$stage/program" "$stage/record" "$stage/previous"; rmdir "$stage"' 0
	trap 'exit 1' HUP INT TERM
	log "Installing $source -> $file"
	created_link=0
	if [ "$mode" = link ]; then
		# Existing wrapper links are left in place after their target was
		# checked. mv can follow a destination symlink on some platforms.
		if [ -L "$file" ]; then
			case "$(readlink "$file")" in
			"$source" | "$destination/$source") : ;;
			*) die "unexpected wrapper target: $file" ;;
			esac
		else
			ln -s "$source" "$file" || die "cannot link $file"
			created_link=1
		fi
		managed_signature "$file" >"$stage/record"
	else
		install -m "$mode" "$source" "$stage/program" ||
			die "cannot prepare $source"
		managed_signature "$stage/program" >"$stage/record"
		if [ -f "$file" ]; then
			ln "$file" "$stage/previous" || die "cannot prepare rollback for $file"
		fi
		mv -f "$stage/program" "$file" || die "cannot publish $file"
	fi
	if ! mv -f "$stage/record" "$record"; then
		if [ -f "$stage/previous" ]; then
			mv -f "$stage/previous" "$file" ||
				die "cannot record or restore $file; inspect the destination before retrying"
		elif [ "$mode" != link ] || [ "$created_link" -eq 1 ]; then
			rm -f "$file" ||
				die "cannot record or remove $file; inspect the destination before retrying"
		fi
		die "cannot record $file; publication was rolled back"
	fi
)

install_list() {
	# The list is a whitespace-separated Make variable.
	# shellcheck disable=SC2086
	for source in $2; do
		managed_entry "$1" 0755 "$source" "$3" "$(strip_extension "$source")"
	done
}

remove_managed_entries() (
	destination=$1
	records="$destination/.scripts-install"
	family_dir="$records/$install_family"
	if [ -L "$records" ] || [ -L "$family_dir" ]; then
		die "invalid install records directory: $records"
	fi
	[ -d "$family_dir" ] || return 0
	status=0
	for record in "$family_dir"/*; do
		[ -e "$record" ] || [ -L "$record" ] || continue
		file="$destination/${record##*/}"
		actual=
		if [ -e "$file" ] || [ -L "$file" ]; then
			actual=$(managed_signature "$file") || actual=invalid
		fi
		if [ -L "$record" ] || [ ! -f "$record" ] ||
			{ [ -n "$actual" ] && [ "$actual" != "$(cat "$record")" ]; }; then
			printf '%s Preserving modified or unrecognized entry: %s\n' "$INFO" "$file" >&2
			status=1
			continue
		fi
		rm -f -- "$file" "$record" || status=1
	done
	rmdir "$family_dir" "$records" 2>/dev/null || true
	exit "$status"
)

install_wrapper_links() {
	for link in sudo visudo sudoedit; do
		managed_entry "$1" link sudo-wrapper "$DESTBIN" "$link"
	done
}

with_install_lock() (
	destination=$1
	operation=$2
	shift 2
	if [ ! -d "$destination" ]; then
		if [ "$operation" = remove ]; then
			"$@"
			return
		fi
		mkdir -p "$destination" || die "cannot create $destination"
	fi
	lock_directory="$destination/.scripts-install.lock"
	mkdir "$lock_directory" ||
		die "cannot acquire install lock: $lock_directory"
	trap 'rmdir "$lock_directory"' 0
	trap 'exit 1' HUP INT TERM
	"$@"
)

with_platform_install_locks() {
	operation=$1
	family=$2
	shift 2
	if [ "$family" = secureblue ] && [ "$DESTBIN" != "$DEST_SYSTEMD_USER" ]; then
		# Keep the bin/unit lock order consistent across install and removal.
		with_install_lock "$DESTBIN" "$operation" \
			with_install_lock "$DEST_SYSTEMD_USER" "$operation" "$@" "$family"
	else
		with_install_lock "$DESTBIN" "$operation" "$@" "$family"
	fi
}

install_platform() {
	install_family=$1
	# Preflight every entry under the same locks before publishing any of
	# them. Publication can still fail after earlier entries have landed.
	for phase in check publish; do
		install_list "$phase" "$platform_list" "$DESTBIN"
		if [ "$install_family" = secureblue ]; then
			for unit in secureblue/systemd/*.service; do
				[ -f "$unit" ] || continue
				managed_entry "$phase" 0644 "$unit" \
					"$DEST_SYSTEMD_USER" "${unit##*/}"
			done
		fi
		if [ "$install_family" != debian ]; then
			case " $platform_list " in
			*"/sudo-wrapper."*) install_wrapper_links "$phase" ;;
			esac
		fi
	done
	log "$install_family helpers installed"
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
	install_family=perl
	programs=$(grep -Ev '^[[:space:]]*(#|$)' "$PERL_PROGRAMS_MANIFEST") ||
		die "cannot read $PERL_PROGRAMS_MANIFEST"
	for phase in check publish; do
		# shellcheck disable=SC2086
		for program in $programs; do
			output=${program%.pl}
			managed_entry "$phase" 0755 "perl/$program" "$DESTBIN" "$output"
			managed_entry "$phase" 0644 VERSION "$DESTBIN" "$output.version"
		done
	done
	log 'Perl helpers installed'
}

is_managed_tests_format_profile() {
	[ -f "$1" ] && [ ! -L "$1" ] &&
		[ "$(sed -n '1p' "$1")" = '# Managed by make install-tests-format.' ]
}

install_tests_format_profile() (
	[ -n "$TESTS_FORMAT_PROFILE_DIR" ] || exit 0
	profile_dir=$DESTDIR/${TESTS_FORMAT_PROFILE_DIR#/}
	profile=$profile_dir/scripts-tests-format.sh
	mkdir -p "$profile_dir" || die "cannot create $profile_dir"
	if [ -e "$profile" ] || [ -L "$profile" ]; then
		is_managed_tests_format_profile "$profile" ||
			die "refusing to replace an unmanaged profile: $profile"
	fi
	umask 077
	tmp_profile=$(mktemp "$profile_dir/.scripts-tests-format.XXXXXX") ||
		die "cannot create a temporary profile in $profile_dir"
	trap 'rm -f -- "$tmp_profile"' 0
	trap 'exit 1' HUP INT TERM
	quoted_dir=$(printf '%s\n' "$TESTS_FORMAT_DIR" | sed "s/'/'\\\\''/g")
	cat >"$tmp_profile" <<EOF
# Managed by make install-tests-format.
case ":\${PATH-}:" in
	*:'$quoted_dir':*) ;;
	*) export PATH="\${PATH:+\$PATH:}"'$quoted_dir' ;;
esac
EOF
	chmod 0644 "$tmp_profile"
	mv -f "$tmp_profile" "$profile" || die "cannot install $profile"
	log "Installed PATH configuration in $profile"
)

install_tests_format() {
	if [ "${TESTS_FORMAT_LINKS:-0}" = "1" ]; then
		case "$TESTS_FORMAT_DIR" in
		/*) ;;
		*) die 'TESTS_FORMAT_DIR must be absolute for compatibility links' ;;
		esac
	fi
	if [ -n "$TESTS_FORMAT_PROFILE_DIR" ]; then
		case "$TESTS_FORMAT_DIR" in
		*:*) die 'TESTS_FORMAT_DIR cannot contain a colon when added to PATH' ;;
		/*) ;;
		*) die 'TESTS_FORMAT_DIR must be absolute when added to PATH' ;;
		esac
	fi
	log 'Installing Tests/Format scripts'
	install -d "$DEST_TESTS_FORMAT/config" ||
		die "cannot create $DEST_TESTS_FORMAT/config"
	for cfg in \
		"tests-format/clang-format.yaml:clang-format-all" \
		"tests-format/clang-tidy.yaml:clang-tidy-all" \
		"tests-format/fourmolu-all.yaml:fourmolu-all"; do
		source=${cfg%%:*}
		destination=${cfg##*:}
		install -m 0644 "$source" "$DEST_TESTS_FORMAT/config/$destination" ||
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
			if [ -L "$DESTBIN/$name" ] &&
				[ "$(readlink "$DESTBIN/$name")" = "$TESTS_FORMAT_DIR/$name" ]; then
				continue
			fi
			if [ -e "$DESTBIN/$name" ] || [ -L "$DESTBIN/$name" ]; then
				die "refusing to replace $DESTBIN/$name"
			fi
			ln -s "$TESTS_FORMAT_DIR/$name" "$DESTBIN/$name" ||
				die "cannot link $name without replacing an existing path"
		fi
	done
	install_tests_format_profile
	log "Tests/Format helpers installed in $DEST_TESTS_FORMAT"
}

uninstall_platform() {
	install_family=$1
	status=0
	remove_managed_entries "$DESTBIN" || status=1
	if [ "$install_family" = secureblue ]; then
		remove_managed_entries "$DEST_SYSTEMD_USER" || status=1
	fi
	[ "$status" -eq 0 ] || return "$status"
	log "$install_family helpers removed"
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

uninstall_tests_format() {
	# shellcheck disable=SC2086
	for source in ${TESTS_FORMAT_SCRIPTS:?}; do
		name=$(strip_extension "$source")
		rm -f -- "$DEST_TESTS_FORMAT/$name"
		if [ "${TESTS_FORMAT_LINKS:-0}" = "1" ] &&
			[ -L "$DESTBIN/$name" ] &&
			[ "$(readlink "$DESTBIN/$name")" = "$TESTS_FORMAT_DIR/$name" ]; then
			rm -f -- "$DESTBIN/$name"
		fi
	done
	for name in clang-format-all clang-tidy-all fourmolu-all; do
		rm -f -- "$DEST_TESTS_FORMAT/config/$name"
	done
	rmdir "$DEST_TESTS_FORMAT/config" 2>/dev/null || true
	if [ -n "$TESTS_FORMAT_PROFILE_DIR" ]; then
		profile="$DESTDIR/${TESTS_FORMAT_PROFILE_DIR#/}/scripts-tests-format.sh"
		if is_managed_tests_format_profile "$profile"; then
			rm -f -- "$profile"
		fi
	fi
	log 'Tests/Format helpers removed'
}

format_sources() {
	status=0
	for validator in python shell perl make; do
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
  test-python              Run cache-free Python validation with Ruff
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
           TESTS_FORMAT_PROFILE_DIR=${TESTS_FORMAT_PROFILE_DIR} (empty disables PATH integration)
EOF
}

command=${1:-}
shift || true
case "$command" in
install-debian)
	platform_list=${DEBIAN_SCRIPTS:?}
	with_platform_install_locks install debian install_platform
	;;
install-openbsd)
	platform_list=${OPENBSD_SCRIPTS:?}
	with_platform_install_locks install openbsd install_platform
	;;
install-secureblue)
	platform_list=${SECUREBLUE_SCRIPTS:?}
	with_platform_install_locks install secureblue install_platform
	;;
install-shell-bash-unlock) unlock_shell_dir ;;
install-shell-bash-copy) copy_shell_files ;;
install-shell-bash) install_shell_bash ;;
install-shell) log 'Shell helpers installed' ;;
install-shell-openbsd)
	log 'OpenBSD does not support chattr immutable flags like Linux.'
	log 'Copy shell/aliases.bash manually to your preferred shell profile location.'
	;;
install-perl) with_install_lock "$DESTBIN" install install_perl ;;
install-tests-format) install_tests_format ;;
uninstall-debian) with_platform_install_locks remove debian uninstall_platform ;;
uninstall-openbsd) with_platform_install_locks remove openbsd uninstall_platform ;;
uninstall-secureblue) with_platform_install_locks remove secureblue uninstall_platform ;;
uninstall-shell) uninstall_shell ;;
uninstall-perl) with_platform_install_locks remove perl uninstall_platform ;;
uninstall-tests-format) uninstall_tests_format ;;
format) format_sources ;;
help) show_help ;;
*)
	die "unknown operation: ${command:-<none>}"
	;;
esac
