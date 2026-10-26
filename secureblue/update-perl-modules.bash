#!/bin/bash
set -euo pipefail

# SecureBlue local Perl module updater.
#
# Updates only the distributions installed in the user's local::lib (the tree
# produced by cpanm --local-lib, by default $HOME/perl5). Run it as the user who
# owns that tree; it performs no elevation and prepends the tree to PERL5LIB
# and PATH for the tools it invokes.
#
# cpan-outdated lists outdated distributions, and cpanm reinstalls them with
# --local-lib so they stay in the same tree. Dual-life core modules are excluded
# by default: it is usually undesirable for a local copy of a module that ships
# with the system or Homebrew Perl to shadow the packaged version.
# --include-core considers them anyway, and --list only reports without
# installing.
#
# App::cpanoutdated is installed into the local::lib on demand, so the first run
# may need network access. cpanm then fetches distributions from CPAN; no root
# access is used and nothing is installed system-wide.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PERL_LOCAL_LIB="${PERL_LOCAL_LIB:-$HOME/perl5}"
CPANM_BIN="${CPANM_BIN:-cpanm}"
PERL_BIN="${PERL_BIN:-perl}"

# EXCLUDE_CORE passes --exclude-core unless --include-core was given;
# LIST_ONLY reports outdated distributions without installing them.
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

# Make the local::lib visible to the tools this script runs. Existing PERL5LIB
# entries are preserved after the local tree rather than overwritten.
setup_local_lib() {
	export PERL5LIB="$PERL_LOCAL_LIB/lib/perl5${PERL5LIB:+:$PERL5LIB}"
	export PATH="$PERL_LOCAL_LIB/bin:$PATH"
}

# Prefer cpanm from PATH, but accept one already installed in the local::lib
# (App::cpanminus installs its launcher there).
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

	# Split the captured output into one distribution per line. mapfile needs
	# Bash 4, which SecureBlue provides.
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
