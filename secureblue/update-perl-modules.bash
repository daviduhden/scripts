#!/bin/bash
set -euo pipefail

# Secureblue local Perl module updater
# Automated script to update the Perl distributions installed in the
# user's local::lib (the modules installed with cpanm -l).
#
# - Checks the local::lib for outdated distributions with cpan-outdated
# - Reinstalls them with cpanm so they stay in the local::lib
# - Excludes dual-life core modules by default, so the system or
#   Homebrew Perl installation is not shadowed
#
# The local::lib is produced by cpanm --local-lib (for example when
# installing Perl::Critic). Modules already loaded through the system
# or Homebrew Perl are left untouched unless --include-core is given.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PERL_LOCAL_LIB="${PERL_LOCAL_LIB:-$HOME/perl5}"
CPANM_BIN="${CPANM_BIN:-cpanm}"
PERL_BIN="${PERL_BIN:-perl}"

EXCLUDE_CORE=1
LIST_ONLY=0

log() {
	printf '%s [INFO]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
	printf '%s [WARN]  %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
error() {
	printf '%s [ERROR] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

usage() {
	cat <<'EOF'
Usage: update-perl-modules.bash [options]

Update the Perl distributions installed in the user's local::lib.

Options:
  -h, --help        Show this help and exit
      --list        Only list the outdated distributions
      --include-core
                    Also consider dual-life core modules
                    (default: exclude them)

Environment:
  PERL_LOCAL_LIB    local::lib root (default: $HOME/perl5)
  CPANM_BIN         cpanm command (default: cpanm)
  PERL_BIN          perl command (default: perl)
EOF
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		error "Required command '$1' not found."
		exit 1
	}
}

# Homebrew on SecureBlue may not be on PATH for non-login shells.
ensure_path() {
	if command -v "$PERL_BIN" >/dev/null 2>&1 &&
		command -v "$CPANM_BIN" >/dev/null 2>&1; then
		return 0
	fi

	local prefix
	for prefix in \
		/var/home/linuxbrew/.linuxbrew \
		/home/linuxbrew/.linuxbrew \
		"$HOME/.linuxbrew"; do
		if [[ -x "$prefix/bin/perl" ]]; then
			export PATH="$prefix/bin:$prefix/sbin:$PATH"
			return 0
		fi
	done

	return 0
}

parse_args() {
	while (($# > 0)); do
		case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--list)
			LIST_ONLY=1
			;;
		--include-core)
			EXCLUDE_CORE=0
			;;
		*)
			error "Unknown option: $1"
			usage >&2
			exit 2
			;;
		esac
		shift
	done
}

# Make the local::lib visible to the tools this script runs.
setup_local_lib() {
	export PERL5LIB="$PERL_LOCAL_LIB/lib/perl5${PERL5LIB:+:$PERL5LIB}"
	export PATH="$PERL_LOCAL_LIB/bin:$PATH"
}

ensure_cpanm() {
	if command -v "$CPANM_BIN" >/dev/null 2>&1; then
		return 0
	fi
	if [[ -x "$PERL_LOCAL_LIB/bin/cpanm" ]]; then
		CPANM_BIN="$PERL_LOCAL_LIB/bin/cpanm"
		return 0
	fi
	error "cpanm not found; install App::cpanminus" \
		"(for example 'brew install cpanminus')."
	exit 1
}

# cpan-outdated ships with App::cpanoutdated; install it on demand in the
# local::lib so it is updated together with the other local modules.
ensure_cpan_outdated() {
	if command -v cpan-outdated >/dev/null 2>&1; then
		return 0
	fi
	log "Installing App::cpanoutdated into $PERL_LOCAL_LIB..."
	"$CPANM_BIN" --local-lib "$PERL_LOCAL_LIB" App::cpanoutdated
}

update_local_lib() {
	local raw
	local -a flags=()
	local -a outdated=()

	if [[ $EXCLUDE_CORE -eq 1 ]]; then
		flags+=(--exclude-core)
	fi

	if ! raw="$(cpan-outdated -l "$PERL_LOCAL_LIB" "${flags[@]}")"; then
		error "cpan-outdated failed; is '$PERL_LOCAL_LIB' usable?"
		exit 1
	fi

	if [[ -n $raw ]]; then
		mapfile -t outdated <<<"$raw"
	fi

	if ((${#outdated[@]} == 0)); then
		log "All local Perl distributions in $PERL_LOCAL_LIB are up to date."
		return 0
	fi

	log "Outdated distribution(s):"
	printf '  - %s\n' "${outdated[@]}"

	if [[ $LIST_ONLY -eq 1 ]]; then
		return 0
	fi

	log "Updating ${#outdated[@]} distribution(s) with $CPANM_BIN..."
	"$CPANM_BIN" --local-lib "$PERL_LOCAL_LIB" "${outdated[@]}"
	log "Local Perl distributions updated."
}

main() {
	parse_args "$@"
	ensure_path
	setup_local_lib
	require_cmd "$PERL_BIN"
	ensure_cpanm
	ensure_cpan_outdated

	if [[ ! -d $PERL_LOCAL_LIB ]]; then
		warn "Local Perl library does not exist yet: $PERL_LOCAL_LIB"
		warn "It will be created by the first cpanm install."
	fi

	log "Checking $PERL_LOCAL_LIB for outdated distributions..."
	update_local_lib
}

main "$@"
