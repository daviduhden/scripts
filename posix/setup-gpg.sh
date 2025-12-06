#!/bin/sh

#
# POSIX shell script to install GnuPG, generate strong keys, upload them
# to keys.openpgp.org, andinstall config files from ./gpg-conf.
#
# Usage:
#   ./script.sh [OPTIONS]
#
# Installation:
# - Linux: prefer Homebrew (no root) if available; otherwise use system package manager.
#   - Debian/Ubuntu/Devuan (amd64/i386): can use official GnuPG upstream repo.
#       * Debian: default to devel branch (can be overridden with --gnupg-branch).
#       * Ubuntu/Devuan: stable vs devel (interactive or via --gnupg-branch).
#   - Secureblue and Fedora Atomic (rpm-ostree): use Homebrew as user.
#   - Termux (Android): use Termux pkg/apt (user-space).
#   - ChromeOS: prefer Chromebrew (crew) when available.
#   - Other Linux distros: detect package manager and use it.
#     Supported package managers include:
#   - apt-get (Debian-like)
#   - dnf (Fedora/RHEL-like)
#   - yum (older Fedora/RHEL/CentOS)
#   - pacman (Arch Linux and derivatives)
#   - zypper (openSUSE/SLES)
#   - apk (Alpine Linux)
#   - xbps-install (Void Linux)
#   - eopkg (Solus)
#   - emerge (Gentoo)
#   - slackpkg/pkgtools (Slackware)
#   - guix (GNU Guix)
#   - nix/nix-env (NixOS and Nix)
# - macOS: install Homebrew (if needed) and then gnupg via brew.
# - BSD:
#   - FreeBSD / GhostBSD / DragonFlyBSD: pkg (shared function).
#   - OpenBSD: pkg_add.
#   - NetBSD: pkgin/pkg_add.
#
# Key generation:
# - Default (no PQC flags):
#     * If GnuPG supports Kyber: ECC+Kyber (PQC) key + RSA 4096-bit compatibility key.
#     * Otherwise: RSA 4096-bit key only.
# - PQC flags:
#     * --no-pqc         : do not generate PQC key, RSA only.
#     * --pqc-only       : generate PQC key only (error if Kyber is unavailable).
# - Identity flags:
#     * --name NAME      : real name to embed in UID (non-interactive).
#     * --email MAIL     : email to embed in UID (non-interactive).
# - Mode flags:
#     * --install-only   : only install GnuPG, do not generate keys.
#     * --keygen-only    : only generate keys, do not install GnuPG.
# - GnuPG repo branch flags (Debian/Ubuntu/Devuan official repo):
#     * --gnupg-branch stable|devel
#       Forces branch and disables the interactive prompt on Ubuntu/Devuan.
#       On Debian it overrides the default devel choice.
#
# Additional behavior:
# - If a ./gpg-conf directory exists, its files are copied into ~/.gnupg/,
#   backing up any existing files as *.bak (or *.bak.TIMESTAMP if needed).
# - After key generation, all generated keys are uploaded automatically to
#   keys.openpgp.org via 'gpg --send-keys'.
#
# All keys are created without passphrase by default (you can add one later).
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#

set -eu

###########
# Helpers #
###########

error() {
    echo "Error: $*" 1>&2
    exit 1
}

# PQC / identity / mode / branch flags
force_no_pqc=0
force_pqc_only=0
name_override=""
email_override=""
install_only=0
keygen_only=0
gnupg_branch_cli=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-pqc)
            force_no_pqc=1
            shift
            ;;
        --pqc-only)
            force_pqc_only=1
            shift
            ;;
        --name)
            if [ "$#" -lt 2 ]; then
                error "--name requires an argument"
            fi
            name_override=$2
            shift 2
            ;;
        --email)
            if [ "$#" -lt 2 ]; then
                error "--email requires an argument"
            fi
            email_override=$2
            shift 2
            ;;
        --install-only)
            install_only=1
            shift
            ;;
        --keygen-only)
            keygen_only=1
            shift
            ;;
        --gnupg-branch)
            if [ "$#" -lt 2 ]; then
                error "--gnupg-branch requires 'stable' or 'devel'"
            fi
            case "$2" in
                stable|STABLE)
                    gnupg_branch_cli="stable"
                    ;;
                devel|DEVEL|development|DEVELOPMENT)
                    gnupg_branch_cli="devel"
                    ;;
                *)
                    error "Invalid value for --gnupg-branch: $2 (expected 'stable' or 'devel')"
                    ;;
            esac
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

PQC options:
  --no-pqc         Do not generate a PQC (Kyber) key, even if supported.
  --pqc-only       Generate only a PQC (ECC+Kyber) key (error if PQC is unavailable).

Identity options:
  --name NAME      Real name to embed in the key UID (non-interactive).
  --email EMAIL    Email to embed in the key UID (non-interactive).

Mode options:
  --install-only   Install GnuPG but do not generate any keys.
  --keygen-only    Generate keys only; do not attempt to install GnuPG.

GnuPG official repo options (Debian/Ubuntu/Devuan):
  --gnupg-branch stable|devel
      Force the use of the 'stable' or 'devel' branch of the official GnuPG
      repository when this script configures it.
      - On Debian, this overrides the default 'devel' choice.
      - On Ubuntu/Devuan, this disables the interactive branch prompt.

General:
  -h, --help       Show this help and exit.

Default behavior (no install/keygen mode flags):
  - Install GnuPG (if needed) and then generate keys.
  - If GnuPG supports Kyber and --no-pqc is not set:
      * ECC+Kyber (PQC) key + RSA 4096-bit compatibility key.
    Otherwise:
      * RSA 4096-bit key only.

Additional behavior:
  - If ./gpg-conf exists, copy its files into ~/.gnupg/ (backing up old ones
    as .bak).
  - Upload all generated keys to keys.openpgp.org automatically.
EOF
            exit 0
            ;;
        *)
            echo "Warning: unknown option '$1' ignored." 1>&2
            shift
            ;;
    esac
done

if [ "$force_no_pqc" -eq 1 ] && [ "$force_pqc_only" -eq 1 ]; then
    error "Options --no-pqc and --pqc-only are mutually exclusive."
fi

if [ "$install_only" -eq 1 ] && [ "$keygen_only" -eq 1 ]; then
    error "Options --install-only and --keygen-only are mutually exclusive."
fi

# Detect whether we can run privileged commands
SUDO=""
need_root_pkgmgr=1  # by default package managers need root

if [ "$(id -u)" -ne 0 ]; then
    # Prefer run0 if available (systemd-based systems)
    if command -v run0 >/dev/null 2>&1; then
        SUDO="run0"
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    elif command -v doas >/dev/null 2>&1; then
        SUDO="doas"
    else
        SUDO=""
    fi
else
    # Already root, no wrapper needed
    SUDO=""
fi

# Helper to run package manager commands with or without sudo/run0/doas
run_pkg() {
    if [ "$need_root_pkgmgr" -eq 1 ]; then
        if [ -n "$SUDO" ]; then
            # run0/sudo/doas <pkgmgr> ...
            $SUDO "$@"
        else
            error "Need root/sudo/run0/doas to run: $*"
        fi
    else
        "$@"
    fi
}

os_uname=$(uname -s)

###########################################
# GPG config installation from ./gpg-conf #
###########################################

install_gpg_conf_from_dir() {
    conf_src="./gpg-conf"

    if [ ! -d "$conf_src" ]; then
        return 0
    fi

    echo
    echo "Found $conf_src; installing config files into \$HOME/.gnupg ..."

    GNUPG_DIR="$HOME/.gnupg"

    if [ ! -d "$GNUPG_DIR" ]; then
        mkdir -p "$GNUPG_DIR" || error "Cannot create directory $GNUPG_DIR"
        chmod 700 "$GNUPG_DIR" || :
    fi

    for src in "$conf_src"/*; do
        # Skip if glob didn't match or it's not a regular file
        [ -f "$src" ] || continue

        base=$(basename "$src")
        dest="$GNUPG_DIR/$base"

        if [ -e "$dest" ]; then
            backup="$dest.bak"
            if [ -e "$backup" ]; then
                # If .bak already exists, use timestamped backup
                backup="$dest.bak.$(date +%Y%m%d%H%M%S)"
            fi
            echo "Backing up existing $dest to $backup"
            mv "$dest" "$backup"
        fi

        echo "Copying $src -> $dest"
        cp "$src" "$dest"
        chmod 600 "$dest" || :
    done

    echo "GnuPG configuration from $conf_src installed into $GNUPG_DIR."
}

##############################################################
# Debian/Ubuntu/Devuan: Official GnuPG repo (stable / devel) #
##############################################################

install_gnupg_debian_like() {
    if [ ! -r /etc/os-release ]; then
        error "/etc/os-release not found; cannot detect Debian/Ubuntu/Devuan."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    if ! command -v dpkg >/dev/null 2>&1; then
        error "dpkg not found; this does not look like a Debian-like system."
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        error "apt-get not found; cannot use GnuPG official repository."
    fi

    arch=$(dpkg --print-architecture 2>/dev/null || echo "")
    case "$arch" in
        amd64|i386) ;;
        *)
            echo "Architecture '$arch' not supported by official GnuPG repo; using distro gnupg instead."
            run_pkg apt-get update
            run_pkg apt-get install -y gnupg
            return 0
            ;;
    esac

    codename=""
    if [ -n "${VERSION_CODENAME:-}" ]; then
        codename=$VERSION_CODENAME
    elif [ -n "${DEBIAN_CODENAME:-}" ]; then
        codename=$DEBIAN_CODENAME
    elif [ -n "${UBUNTU_CODENAME:-}" ]; then
        codename=$UBUNTU_CODENAME
    fi

    if [ -z "$codename" ]; then
        error "Could not detect distribution codename (VERSION_CODENAME/DEBIAN_CODENAME/UBUNTU_CODENAME)."
    fi

    suite=""
    case "$ID" in
        debian)
            case "$codename" in
                bookworm|trixie) suite=$codename ;;
                *)
                    echo "Debian codename '$codename' not covered by official GnuPG repo; using distro gnupg."
                    run_pkg apt-get update
                    run_pkg apt-get install -y gnupg
                    return 0
                    ;;
            esac
            ;;
        ubuntu)
            case "$codename" in
                jammy|noble|plucky) suite=$codename ;;
                *)
                    echo "Ubuntu codename '$codename' not covered by official GnuPG repo; using distro gnupg."
                    run_pkg apt-get update
                    run_pkg apt-get install -y gnupg
                    return 0
                    ;;
            esac
            ;;
        devuan)
            case "$codename" in
                daedalus) suite=$codename ;;
                *)
                    echo "Devuan codename '$codename' not covered by official GnuPG repo; using distro gnupg."
                    run_pkg apt-get update
                    run_pkg apt-get install -y gnupg
                    return 0
                    ;;
            esac
            ;;
        *)
            echo "ID '$ID' is not a direct Debian/Ubuntu/Devuan system; using distro gnupg."
            run_pkg apt-get update
            run_pkg apt-get install -y gnupg
            return 0
            ;;
    esac

    echo

    base_suite="$suite"
    chosen_branch=""

    if [ -n "$gnupg_branch_cli" ]; then
        # CLI flag overrides everything
        chosen_branch="$gnupg_branch_cli"
        echo "Using GnuPG upstream $chosen_branch branch for $ID (set via --gnupg-branch)."
    else
        if [ "$ID" = "debian" ]; then
            # Default for Debian: devel branch, non-interactive
            chosen_branch="devel"
            echo "Using GnuPG upstream development repository for Debian (default): ${base_suite}-devel"
        else
            # Ubuntu/Devuan: interactive prompt if no CLI override
            echo "Select GnuPG upstream repository branch for $ID ($codename):"
            echo "  stable : latest stable release (recommended)"
            echo "  devel  : latest development release with newest features (may be less tested)"
            printf "Branch [stable]: "
            if ! IFS= read -r gnupg_branch; then
                gnupg_branch=""
            fi

            case "$gnupg_branch" in
                d|D|devel|DEVEL|development|DEVELOPMENT)
                    chosen_branch="devel"
                    echo "Using development repository branch: ${base_suite}-devel"
                    ;;
                ""|s|S|stable|STABLE)
                    chosen_branch="stable"
                    echo "Using stable repository branch: $base_suite"
                    ;;
                *)
                    chosen_branch="stable"
                    echo "Unrecognized answer '$gnupg_branch'; defaulting to stable branch: $base_suite"
                    ;;
            esac
        fi
    fi

    case "$chosen_branch" in
        devel)
            suite="${base_suite}-devel"
            ;;
        ""|stable)
            suite="$base_suite"
            ;;
        *)
            echo "Internal warning: unknown chosen_branch '$chosen_branch'; defaulting to stable branch: $base_suite"
            suite="$base_suite"
            ;;
    esac

    echo "Using official GnuPG upstream repository for $ID (suite: $suite) on $arch."

    if ! command -v curl >/dev/null 2>&1; then
        run_pkg apt-get update
        run_pkg apt-get install -y curl
    fi

    if ! command -v gpg >/dev/null 2>&1; then
        run_pkg apt-get update
        run_pkg apt-get install -y gnupg
    fi

    keyring="/usr/share/keyrings/gnupg-keyring.gpg"
    key_url="https://repos.gnupg.org/deb/gnupg/${suite}/gnupg-signing-key.gpg"

    echo "Fetching GnuPG signing key from ${key_url} ..."
    curl -fLsS --retry 5 "$key_url" | ${SUDO:+$SUDO }gpg --dearmor --yes -o "$keyring"
    ${SUDO:+$SUDO }chmod a+r "$keyring"

    echo "Writing /etc/apt/sources.list.d/gnupg.sources ..."
    cat <<EOF | ${SUDO:+$SUDO }tee /etc/apt/sources.list.d/gnupg.sources >/dev/null
Types: deb
URIs: https://repos.gnupg.org/deb/gnupg/${suite}/
Suites: ${suite}
Components: main
Signed-By: /usr/share/keyrings/gnupg-keyring.gpg
EOF

    echo "Updating APT index (including official GnuPG repo)..."
    run_pkg apt-get update

    echo "Installing gnupg from official GnuPG repo (branch: $suite)..."
    if ! run_pkg apt-get install -y -t "$suite" gnupg2 2>/dev/null; then
        if ! run_pkg apt-get install -y -t "$suite" gnupg 2>/dev/null; then
            run_pkg apt-get install -y gnupg
        fi
    fi
}

#########################################################
# rpm-ostree (Secureblue or Fedora Atomic) via Homebrew #
#########################################################

install_gnupg_rpm_ostree_brew() {
    distro_label=$1  # e.g. "Secureblue" or "Fedora Atomic"
    if [ "$(id -u)" -eq 0 ]; then
        error "On ${distro_label}, this script should NOT be run as root. Run it as a regular user so Homebrew can be used."
    fi

    if command -v brew >/dev/null 2>&1; then
        echo "Installing gnupg via Homebrew on ${distro_label}..."
        brew install gnupg
    else
        echo "This looks like a ${distro_label} rpm-ostree based system."
        echo "You should install Homebrew in user space first, then run:"
        echo "  brew install gnupg"
        error "Homebrew not found; cannot install gnupg automatically on ${distro_label}."
    fi
}

######################################
# Linux: General installation helper #
######################################

install_gnupg_linux() {
    # Termux (Android) support
    if [ -n "${TERMUX_VERSION:-}" ] || { [ -n "${ANDROID_ROOT:-}" ] && command -v pkg >/dev/null 2>&1; }; then
        echo "Detected Termux on Android."
        if command -v pkg >/dev/null 2>&1; then
            pkg install -y gnupg
        elif command -v apt >/dev/null 2>&1; then
            apt update
            apt install -y gnupg
        else
            error "Termux environment detected but could not find 'pkg' or 'apt' to install gnupg."
        fi
        return 0
    fi

    # Prefer Homebrew (Linuxbrew) when available and running unprivileged
    if command -v brew >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
        echo "Detected Homebrew on Linux. Installing gnupg via brew (no root)..."
        brew install gnupg
        return 0
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
    else
        ID=""
        ID_LIKE=""
    fi

    # ChromeOS
    if [ "${ID:-}" = "chromeos" ] || [ -n "${CHROMEOS_RELEASE_NAME:-}" ]; then
        echo "Detected ChromeOS."
        if command -v crew >/dev/null 2>&1; then
            echo "Installing gnupg via Chromebrew (crew)..."
            crew install gnupg
            return 0
        fi
        echo "Chromebrew (crew) not found; falling back to generic Linux package manager detection."
    fi

    # secureblue (rpm-ostree derivative)
    if [ "${ID:-}" = "secureblue" ]; then
        install_gnupg_rpm_ostree_brew "secureblue"
        return 0
    fi

    # Debian/Ubuntu/Devuan official repo case
    case "${ID:-}" in
        debian|ubuntu|devuan)
            install_gnupg_debian_like
            return 0
            ;;
    esac

    # Fedora Atomic / rpm-ostree Fedora
    if [ "${ID:-}" = "fedora" ] && [ -e /run/ostree-booted ]; then
        echo "Detected Fedora Atomic / rpm-ostree based Fedora system."
        install_gnupg_rpm_ostree_brew "Fedora Atomic"
        return 0
    fi

    # GNU Guix
    if [ "${ID:-}" = "guix" ] || command -v guix >/dev/null 2>&1; then
        echo "Detected GNU Guix. Installing gnupg into current Guix profile..."
        guix install gnupg
        return 0
    fi

    # NixOS / Nix
    if [ "${ID:-}" = "nixos" ] || command -v nix >/dev/null 2>&1 || command -v nix-env >/dev/null 2>&1; then
        echo "Detected Nix / NixOS. Trying to install gnupg into user profile via Nix..."
        if command -v nix >/dev/null 2>&1; then
            if nix profile install nixpkgs#gnupg 2>/dev/null; then
                return 0
            fi
        fi
        if command -v nix-env >/dev/null 2>&1; then
            nix-env -iA nixpkgs.gnupg
            return 0
        fi
        echo "Nix detected but automatic install failed; falling back to generic package manager detection."
    fi

    # Other Linux: package manager heuristics
    if command -v apt-get >/dev/null 2>&1; then
        echo "Detected apt-get (generic Debian-like)."
        run_pkg apt-get update
        run_pkg apt-get install -y gnupg
    elif command -v dnf >/dev/null 2>&1; then
        echo "Detected dnf (Fedora/RHEL-like)."
        run_pkg dnf install -y gnupg2
    elif command -v pacman >/dev/null 2>&1; then
        echo "Detected pacman (Arch/Manjaro/etc)."
        run_pkg pacman -Sy --noconfirm gnupg
    elif command -v zypper >/dev/null 2>&1; then
        echo "Detected zypper (openSUSE/SLES)."
        run_pkg zypper --non-interactive install gpg2
    elif command -v xbps-install >/dev/null 2>&1; then
        echo "Detected xbps-install (Void Linux)."
        run_pkg xbps-install -Sy gnupg
    elif command -v eopkg >/dev/null 2>&1; then
        echo "Detected eopkg (Solus)."
        run_pkg eopkg it -y gnupg || run_pkg eopkg install -y gnupg
    elif command -v emerge >/dev/null 2>&1; then
        echo "Detected emerge (Gentoo)."
        run_pkg emerge app-crypt/gnupg
    elif command -v slackpkg >/dev/null 2>&1 || [ -f /etc/slackware-version ]; then
        echo "Detected Slackware (slackpkg/pkgtools)."
        if command -v slackpkg >/dev/null 2>&1; then
            run_pkg slackpkg install gnupg
        else
            error "Slackware detected but 'slackpkg' not found. Please install 'gnupg' manually using pkgtools (installpkg)."
        fi
    elif command -v apk >/dev/null 2>&1; then
        echo "Detected apk (Alpine)."
        run_pkg apk add gnupg
    else
        error "Could not detect a supported Linux package manager to install gnupg."
    fi
}

###############################################################
# macOS: Install Homebrew (if needed) and then GNUPG via brew #
###############################################################

install_gnupg_macos() {
    echo "Detected macOS."
    if [ "$(id -u)" -eq 0 ]; then
        echo "Warning: Homebrew is normally installed as a regular user, not root."
    fi

    BREW_CMD=""

    if command -v brew >/dev/null 2>&1; then
        BREW_CMD=$(command -v brew)
    else
        echo "Homebrew not found. Installing Homebrew..."
        if ! command -v curl >/dev/null 2>&1; then
            error "curl is required to install Homebrew."
        fi
        /bin/bash -c "$(curl -fLsS --retry 5 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        if [ -x /opt/homebrew/bin/brew ]; then
            BREW_CMD="/opt/homebrew/bin/brew"
            PATH="/opt/homebrew/bin:$PATH"
        elif [ -x /usr/local/bin/brew ]; then
            BREW_CMD="/usr/local/bin/brew"
            PATH="/usr/local/bin:$PATH"
        elif command -v brew >/dev/null 2>&1; then
            BREW_CMD=$(command -v brew)
        else
            error "Homebrew installation seems to have failed; 'brew' not found."
        fi
    fi

    echo "Installing gnupg via Homebrew..."
    "$BREW_CMD" install gnupg
}

####################################################################
# BSD: FreeBSD / GhostBSD / DragonFlyBSD (pkg), OpenBSD and NetBSD #
####################################################################

install_gnupg_freebsd_family() {
    echo "Detected FreeBSD-family system (FreeBSD / GhostBSD / DragonFlyBSD)."
    if command -v pkg >/dev/null 2>&1; then
        run_pkg pkg install -y gnupg
    else
        error "'pkg' not found; cannot install gnupg on this FreeBSD-family system."
    fi
}

install_gnupg_openbsd() {
    echo "Detected OpenBSD."
    if command -v pkg_add >/dev/null 2>&1; then
        run_pkg pkg_add gnupg
    else
        error "OpenBSD 'pkg_add' not found; cannot install gnupg."
    fi
}

install_gnupg_netbsd() {
    echo "Detected NetBSD."
    if command -v pkgin >/dev/null 2>&1; then
        run_pkg pkgin -y install gnupg
    elif command -v pkg_add >/dev/null 2>&1; then
        run_pkg pkg_add gnupg
    else
        error "NetBSD 'pkgin'/'pkg_add' not found; cannot install gnupg."
    fi
}

######################################################
# Install gnupg depending on OS (unless keygen-only) #
######################################################

if [ "$keygen_only" -eq 0 ]; then
    case "$os_uname" in
        Linux)
            install_gnupg_linux
            ;;
        Darwin)
            need_root_pkgmgr=0
            install_gnupg_macos
            ;;
        FreeBSD)
            install_gnupg_freebsd_family
            ;;
        DragonFly)
            install_gnupg_freebsd_family
            ;;
        OpenBSD)
            install_gnupg_openbsd
            ;;
        NetBSD)
            install_gnupg_netbsd
            ;;
        *)
            error "Unsupported OS: $os_uname"
            ;;
    esac
else
    echo "Key-generation-only mode requested; skipping GnuPG installation."
fi

if ! command -v gpg >/dev/null 2>&1; then
    error "gpg binary not found. Please ensure GnuPG is installed and in PATH."
fi

# Install GnuPG configuration from ./gpg-conf (if present) before keygen / exit.
install_gpg_conf_from_dir

if [ "$install_only" -eq 1 ]; then
    echo "Install-only mode: GnuPG is installed and available as 'gpg'."
    echo "Config files from ./gpg-conf were installed into ~/.gnupg/ (if present)."
    echo "No keys were generated."
    exit 0
fi

#################################################################
# Generate strong keys: Kyber (PQC) if available, plus RSA 4096 #
#################################################################

echo
echo "Checking for Kyber (post-quantum) support in this GnuPG build..."

kyber_supported=0

# Stricter detection: look for concrete Kyber or hybrid algorithm names first
if gpg --version 2>/dev/null | grep -E 'Kyber(512|768|1024)|X25519\+Kyber|X448\+Kyber' >/dev/null 2>&1; then
    kyber_supported=1
elif gpg --version 2>/dev/null | grep -i 'Kyber' >/dev/null 2>&1; then
    kyber_supported=1
fi

if [ "$force_no_pqc" -eq 1 ]; then
    echo "PQC support explicitly disabled via --no-pqc."
    kyber_supported=0
fi

if [ "$kyber_supported" -eq 0 ] && [ "$force_pqc_only" -eq 1 ]; then
    error "Option --pqc-only was requested, but this GnuPG build does not advertise any Kyber/PQC algorithms."
fi

if [ "$kyber_supported" -eq 1 ]; then
    echo "Kyber/PQC algorithms detected in this GnuPG build."
else
    echo "No Kyber/PQC algorithms detected in this GnuPG build."
fi

generate_pqc=0
generate_rsa=1

if [ "$kyber_supported" -eq 1 ] && [ "$force_no_pqc" -eq 0 ]; then
    generate_pqc=1
fi

if [ "$force_pqc_only" -eq 1 ]; then
    generate_pqc=1
    generate_rsa=0
fi

echo
if [ "$generate_pqc" -eq 1 ] && [ "$generate_rsa" -eq 1 ]; then
    echo "Key generation plan: ECC+Kyber (PQC) key + RSA 4096-bit compatibility key."
elif [ "$generate_pqc" -eq 1 ]; then
    echo "Key generation plan: ECC+Kyber (PQC) key only (no RSA compatibility key)."
else
    echo "Key generation plan: RSA 4096-bit key only."
fi

echo
echo "Please enter the information to embed in your new GnuPG key(s)."

default_user_name=$(id -un 2>/dev/null || echo "user")
default_host_name=$(hostname 2>/dev/null || echo "localhost")
default_user_email="${default_user_name}@${default_host_name}"

# Name
if [ -n "$name_override" ]; then
    user_name="$name_override"
    echo "Using provided name: $user_name"
else
    printf "Real name [%s]: " "$default_user_name"
    if ! IFS= read -r input_name; then
        input_name=""
    fi
    if [ -n "$input_name" ]; then
        user_name="$input_name"
    else
        user_name="$default_user_name"
    fi
fi

# Email
if [ -n "$email_override" ]; then
    user_email="$email_override"
    echo "Using provided email: $user_email"
else
    printf "Email address [%s]: " "$default_user_email"
    if ! IFS= read -r input_email; then
        input_email=""
    fi
    if [ -n "$input_email" ]; then
        user_email="$input_email"
    else
        user_email="$default_user_email"
    fi
fi

uid="${user_name} <${user_email}>"

pqc_key_id=""
pqc_fpr=""
rsa_key_id=""
rsa_fpr=""

# 1) PQC key (if selected and supported)
if [ "$generate_pqc" -eq 1 ]; then
    echo
    echo "Generating a composite ECC+Kyber (PQC) key (no expiry, no passphrase)..."
    if gpg --batch --yes --pinentry-mode loopback --passphrase '' \
         --quick-gen-key "$uid (PQC)" pqc default 0; then
        pqc_key_id=$(gpg --list-secret-keys --with-colons --keyid-format LONG 2>/dev/null \
            | awk -F: '/^sec:/ {kid=$5} END {print kid}')
        if [ -n "$pqc_key_id" ]; then
            pqc_fpr=$(gpg --with-colons --fingerprint "$pqc_key_id" 2>/dev/null \
                | awk -F: '/^fpr:/ {print $10; exit}')
        fi
    else
        echo "Warning: GnuPG appears to support Kyber, but PQC key generation with 'pqc' failed."
        pqc_key_id=""
        pqc_fpr=""
        generate_pqc=0
        if [ "$force_pqc_only" -eq 1 ]; then
            error "PQC key generation failed and --pqc-only was requested. No RSA fallback will be created."
        else
            echo "Continuing with RSA key generation only."
        fi
    fi
fi

# 2) RSA key (if selected)
if [ "$generate_rsa" -eq 1 ]; then
    echo
    echo "Generating an RSA 4096-bit key (no expiry, no passphrase) for compatibility..."
    if command -v mktemp >/dev/null 2>&1; then
        key_conf_rsa=$(mktemp "${TMPDIR:-/tmp}/gpg-key-rsa-XXXXXX.conf")
    else
        key_conf_rsa="${TMPDIR:-/tmp}/gpg-key-rsa-$$.conf"
    fi

    cat >"$key_conf_rsa" <<EOF
Key-Type: rsa
Key-Length: 4096
Subkey-Type: rsa
Subkey-Length: 4096
Name-Real: ${user_name}
Name-Email: ${user_email}
Name-Comment: RSA compatibility key
Expire-Date: 0
%no-protection
%commit
EOF

    gpg --batch --generate-key "$key_conf_rsa"
    rm -f "$key_conf_rsa"

    rsa_key_id=$(gpg --list-secret-keys --with-colons --keyid-format LONG 2>/dev/null \
        | awk -F: '/^sec:/ {kid=$5} END {print kid}')
    if [ -z "$rsa_key_id" ]; then
        error "Could not determine generated RSA key ID."
    fi

    rsa_fpr=$(gpg --with-colons --fingerprint "$rsa_key_id" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}')
    if [ -z "$rsa_fpr" ]; then
        echo "Warning: could not determine fingerprint for RSA key $rsa_key_id."
    fi
fi

# Choose primary key ID for examples
primary_key_id=""
if [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ]; then
    primary_key_id="$pqc_key_id"
elif [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    primary_key_id="$rsa_key_id"
fi

if [ -z "$primary_key_id" ]; then
    error "Could not determine any key ID for usage examples; key generation seems to have failed."
fi

echo
if [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ] && [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    echo "New composite ECC+Kyber (PQC) key created:"
    echo "  Key ID:       $pqc_key_id"
    [ -n "$pqc_fpr" ] && echo "  Fingerprint:  $pqc_fpr"
    echo
    echo "Additional RSA 4096-bit compatibility key created:"
    echo "  Key ID:       $rsa_key_id"
    [ -n "$rsa_fpr" ] && echo "  Fingerprint:  $rsa_fpr"
elif [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ]; then
    echo "New composite ECC+Kyber (PQC) key created:"
    echo "  Key ID:       $pqc_key_id"
    [ -n "$pqc_fpr" ] && echo "  Fingerprint:  $pqc_fpr"
elif [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    echo "New RSA 4096-bit key created:"
    echo "  Key ID:       $rsa_key_id"
    [ -n "$rsa_fpr" ] && echo "  Fingerprint:  $rsa_fpr"
else
    error "Key generation did not produce any usable keys."
fi

#############################################
# Upload generated keys to keys.openpgp.org #
#############################################

upload_keys_to_keyserver() {
    keyserver="hkps://keys.openpgp.org"
    keys_to_send=""

    if [ -n "$pqc_fpr" ]; then
        keys_to_send=$pqc_fpr
    fi

    if [ -n "$rsa_fpr" ]; then
        if [ -n "$keys_to_send" ]; then
            keys_to_send="$keys_to_send $rsa_fpr"
        else
            keys_to_send=$rsa_fpr
        fi
    fi

    if [ -z "$keys_to_send" ]; then
        echo
        echo "No fingerprints available to upload to $keyserver."
        return 0
    fi

    echo
    echo "Uploading generated keys to $keyserver:"
    echo "  $keys_to_send"
    if ! gpg --keyserver "$keyserver" --send-keys $keys_to_send; then
        echo "Warning: failed to upload keys to $keyserver" 1>&2
    else
        echo "Keys successfully submitted to $keyserver."
        echo "Note: keys.openpgp.org require email verification before your UID appears as 'published'."
    fi
}

upload_keys_to_keyserver

echo
echo "IMPORTANT:"
if [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ] && [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    echo "  Both the ECC+Kyber key and the RSA key currently have NO passphrase."
elif [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ]; then
    echo "  The ECC+Kyber key currently has NO passphrase."
elif [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    echo "  This RSA key currently has NO passphrase."
fi
echo "  For better security, you should set a passphrase on the key(s) you actually use:"
if [ "$generate_pqc" -eq 1 ] && [ -n "$pqc_key_id" ]; then
    echo "    gpg --edit-key $pqc_key_id"
    echo "    gpg> passwd"
fi
if [ "$generate_rsa" -eq 1 ] && [ -n "$rsa_key_id" ]; then
    echo "    gpg --edit-key $rsa_key_id"
    echo "    gpg> passwd"
fi
echo

###########################################################
# Instructions for encrypting plaintext from the terminal #
###########################################################

cat <<EOF
How to encrypt plaintext to your key from the terminal:

(When Kyber/PQC is available and enabled, the examples below use your ECC+Kyber key.
Otherwise they use your RSA 4096-bit key.)

1) Example: encrypt a short message and write it to 'secret.asc':

   echo "my secret message" | gpg --armor --encrypt --recipient $primary_key_id > secret.asc

2) To decrypt that message:

   gpg --decrypt secret.asc

3) To encrypt interactively (type text, then Ctrl+D to end):

   gpg --armor --encrypt --recipient $primary_key_id > mymessage.asc
   [type your message here]
   [press Ctrl+D to finish]

EOF

echo "Done."
