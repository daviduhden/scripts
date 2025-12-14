#!/usr/bin/env perl

# Perl script to install GnuPG, generate strong keys, upload them
# to keys.openpgp.org, and install config files from ./gpg-conf.
#
# Usage:
#   perl gnupg-setup.pl [OPTIONS]
#
# See --help for details.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Copy qw(copy);

my $GREEN = "\e[32m";
my $YELLOW = "\e[33m";
my $RED = "\e[31m";
my $CYAN = "\e[36m";
my $BOLD = "\e[1m";
my $RESET = "\e[0m";

###############
# Error / log #
###############

sub log_info {
    my ($msg) = @_;
    print "${GREEN}[INFO]${RESET} ✅ $msg\n";
}

sub warn_info {
    my ($msg) = @_;
    print STDERR "${YELLOW}[WARN]${RESET} ⚠️ $msg\n";
}

sub error {
    my ($msg, $code) = @_;
    $code //= 1;
    print STDERR "${RED}[ERROR]${RESET} ❌ $msg\n";
    exit $code;
}

########################
# Global configuration #
########################

my $force_no_pqc     = 0;
my $force_pqc_only   = 0;
my $name_override    = '';
my $email_override   = '';
my $install_only     = 0;
my $keygen_only      = 0;
my $gnupg_branch_cli = '';  # stable|devel

#################
# Parse options #
#################

sub usage {
    my $prog = basename($0);
    print <<"EOF";
Usage: $prog [OPTIONS]

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
    as .bak or .bak.TIMESTAMP).
  - Upload all generated keys to keys.openpgp.org automatically.
EOF
}

my $help = 0;

GetOptions(
    'no-pqc'         => \$force_no_pqc,
    'pqc-only'       => \$force_pqc_only,
    'name=s'         => \$name_override,
    'email=s'        => \$email_override,
    'install-only'   => \$install_only,
    'keygen-only'    => \$keygen_only,
    'gnupg-branch=s' => \$gnupg_branch_cli,
    'h|help'         => \$help,
) or error("Error parsing options. Use --help for usage.");

if ($help) {
    usage();
    exit 0;
}

# Normalize gnupg-branch if given
if ($gnupg_branch_cli ne '') {
    if ($gnupg_branch_cli =~ /^(stable|STABLE)$/) {
        $gnupg_branch_cli = 'stable';
    } elsif ($gnupg_branch_cli =~ /^(devel|DEVEL|development|DEVELOPMENT)$/) {
        $gnupg_branch_cli = 'devel';
    } else {
        error("Invalid value for --gnupg-branch: $gnupg_branch_cli (expected 'stable' or 'devel')");
    }
}

if ($force_no_pqc && $force_pqc_only) {
    error("Options --no-pqc and --pqc-only are mutually exclusive.");
}

if ($install_only && $keygen_only) {
    error("Options --install-only and --keygen-only are mutually exclusive.");
}

############################
# Privileged command setup #
############################

my $SUDO             = '';
my $need_root_pkgmgr = 1;  # package managers usually require root

sub find_in_path {
    my ($prog) = @_;
    for my $dir (split /:/, $ENV{PATH} || '') {
        next unless length $dir;
        my $full = "$dir/$prog";
        return $full if -x $full;
    }
    return;
}

sub detect_sudo_wrapper {
    return '' if $> == 0;
    for my $c (qw(run0 sudo doas)) {
        my $path = find_in_path($c);
        return $path if defined $path;
    }
    return '';
}

$SUDO = detect_sudo_wrapper();

###################
# Command helpers #
###################

sub run_cmd {
    my (@cmd) = @_;
    system(@cmd);
    if ($? == -1) {
        warn_info("Failed to execute '@cmd': $!");
        return 0;
    } elsif ($? != 0) {
        my $code = $? >> 8;
        warn_info("Command '@cmd' exited with code $code");
        return 0;
    }
    return 1;
}

# For commands that should run with privilege (pkg managers, etc.)
sub run_pkg {
    my (@cmd) = @_;

    if ($need_root_pkgmgr) {
        if ($SUDO && $> != 0) {
            unshift @cmd, $SUDO;
        } elsif ($> != 0) {
            error("Need root/sudo/run0/doas to run: @cmd");
        }
    }

    return run_cmd(@cmd);
}

##########################
# Install gpg-conf files #
##########################

sub install_gpg_conf_from_dir {
    my $src_dir = './gpg-conf';
    return 1 unless -d $src_dir;

    log_info("Found $src_dir; installing config files into \$HOME/.gnupg ...");

    my $gnupg_dir = "$ENV{HOME}/.gnupg";

    unless (-d $gnupg_dir) {
        make_path($gnupg_dir) or error("Cannot create directory $gnupg_dir");
        chmod 0700, $gnupg_dir;
    }

    opendir(my $dh, $src_dir) or error("Cannot open directory $src_dir: $!");
    while (my $entry = readdir($dh)) {
        next if $entry =~ /^\./;
        my $src = "$src_dir/$entry";
        next unless -f $src;

        my $dest = "$gnupg_dir/$entry";
        if (-e $dest) {
            my $backup = "$dest.bak";
            if (-e $backup) {
                my $ts = time;
                $backup = "$dest.bak.$ts";
            }
            log_info("Backing up existing $dest to $backup");
            rename $dest, $backup or error("Cannot rename $dest to $backup: $!");
        }

        log_info("Copying $src -> $dest");
        copy($src, $dest) or error("Cannot copy $src to $dest: $!");
        chmod 0600, $dest;
    }
    closedir($dh);

    log_info("GnuPG configuration from $src_dir installed into $gnupg_dir.");
    return 1;
}

##########################
# OS / package detection #
##########################

my $os_uname = $^O;  # 'linux', 'darwin', 'freebsd', 'openbsd', ...

sub read_os_release {
    my %os;
    return %os unless -r '/etc/os-release';

    open my $fh, '<', '/etc/os-release'
      or return %os;

    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        next unless $line =~ /=/;
        my ($k, $v) = split /=/, $line, 2;
        $v =~ s/^"(.*)"$/$1/;
        $v =~ s/^'(.*)'$/$1/;
        $os{$k} = $v;
    }
    close $fh;
    return %os;
}

############################################
# Debian/Ubuntu/Devuan official GnuPG repo #
############################################

sub install_gnupg_debian_like {
    my ($osinfo_ref) = @_;
    my %osinfo = %{$osinfo_ref};

    -r '/etc/os-release'
      or error("/etc/os-release not found; cannot detect Debian/Ubuntu/Devuan.");

    my $id   = $osinfo{ID}   // '';
    my $arch = qx(dpkg --print-architecture 2>/dev/null);
    chomp $arch if defined $arch;

    find_in_path('dpkg')    or error("dpkg not found; this does not look like a Debian-like system.");
    find_in_path('apt-get') or error("apt-get not found; cannot use GnuPG official repository.");

    # Only amd64/i386 supported by upstream repo
    if ($arch !~ /^(amd64|i386)$/) {
        log_info("Architecture '$arch' not supported by official GnuPG repo; using distro gnupg instead.");
        run_pkg('apt-get', 'update') or error("apt-get update failed.");
        run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
        return;
    }

    my $codename =
           $osinfo{VERSION_CODENAME}
        || $osinfo{DEBIAN_CODENAME}
        || $osinfo{UBUNTU_CODENAME}
        || '';

    $codename ne ''
      or error("Could not detect distribution codename (VERSION_CODENAME/DEBIAN_CODENAME/UBUNTU_CODENAME).");

    my $suite      = '';
    my $base_suite = '';
    my $chosen_branch = '';

    # Determine base_suite based on ID + codename
    if ($id eq 'debian') {
        if ($codename =~ /^(bookworm|trixie)$/) {
            $base_suite = $codename;
        } else {
            log_info("Debian codename '$codename' not covered by official GnuPG repo; using distro gnupg.");
            run_pkg('apt-get', 'update') or error("apt-get update failed.");
            run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
            return;
        }
    } elsif ($id eq 'ubuntu') {
        if ($codename =~ /^(jammy|noble|plucky)$/) {
            $base_suite = $codename;
        } else {
            log_info("Ubuntu codename '$codename' not covered by official GnuPG repo; using distro gnupg.");
            run_pkg('apt-get', 'update') or error("apt-get update failed.");
            run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
            return;
        }
    } elsif ($id eq 'devuan') {
        if ($codename eq 'daedalus') {
            $base_suite = $codename;
        } else {
            log_info("Devuan codename '$codename' not covered by official GnuPG repo; using distro gnupg.");
            run_pkg('apt-get', 'update') or error("apt-get update failed.");
            run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
            return;
        }
    } else {
        log_info("ID '$id' is not a direct Debian/Ubuntu/Devuan system; using distro gnupg.");
        run_pkg('apt-get', 'update') or error("apt-get update failed.");
        run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
        return;
    }

    print "\n";

    # Branch selection (stable/devel)
    if ($gnupg_branch_cli ne '') {
        $chosen_branch = $gnupg_branch_cli;
        log_info("Using GnuPG upstream $chosen_branch branch for $id (set via --gnupg-branch).");
    } else {
        if ($id eq 'debian') {
            # Default devel for Debian, non-interactive
            $chosen_branch = 'devel';
            log_info("Using GnuPG upstream development repository for Debian (default): ${base_suite}-devel");
        } else {
            # Ubuntu/Devuan interactive prompt
            print "Select GnuPG upstream repository branch for $id ($codename):\n";
            print "  stable : latest stable release (recommended)\n";
            print "  devel  : latest development release with newest features (may be less tested)\n";
            print "Branch [stable]: ";
            my $ans = <STDIN>;
            $ans //= '';
            chomp $ans;

            if ($ans =~ /^(d|devel|development)$/i) {
                $chosen_branch = 'devel';
                log_info("Using development repository branch: ${base_suite}-devel");
            } elsif ($ans =~ /^(s|stable)?$/i) {
                $chosen_branch = 'stable';
                log_info("Using stable repository branch: $base_suite");
            } else {
                $chosen_branch = 'stable';
                warn_info("Unrecognized answer '$ans'; defaulting to stable branch: $base_suite");
            }
        }
    }

    if    ($chosen_branch eq 'devel')  { $suite = "$base_suite-devel"; }
    elsif ($chosen_branch eq 'stable' || $chosen_branch eq '') { $suite = $base_suite; }
    else {
        warn_info("Internal warning: unknown chosen_branch '$chosen_branch'; defaulting to stable branch: $base_suite");
        $suite = $base_suite;
    }

    log_info("Using official GnuPG upstream repository for $id (suite: $suite) on $arch.");

    # Ensure curl and gpg available
    unless (find_in_path('curl')) {
        run_pkg('apt-get', 'update') or error("apt-get update failed.");
        run_pkg('apt-get', 'install', '-y', 'curl') or error("Failed to install curl.");
    }
    unless (find_in_path('gpg')) {
        run_pkg('apt-get', 'update') or error("apt-get update failed.");
        run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg for key handling.");
    }

    my $keyring = '/usr/share/keyrings/gnupg-keyring.gpg';
    my $key_url = "https://repos.gnupg.org/deb/gnupg/${suite}/gnupg-signing-key.gpg";

    log_info("Fetching GnuPG signing key from ${key_url} ...");

    my $sudo_prefix = '';
    if ($SUDO && $> != 0) {
        $sudo_prefix = "$SUDO ";
    }

    my $curl_cmd = "curl -fLsS --retry 5 '$key_url' | ${sudo_prefix}gpg --dearmor --yes -o '$keyring'";
    system($curl_cmd);
    if ($? != 0) {
        error("Failed to fetch or dearmor GnuPG signing key from $key_url");
    }

    # chmod a+r keyring
    if ($> == 0) {
        chmod 0644, $keyring or warn_info("Warning: chmod a+r $keyring failed: $!");
    } else {
        run_cmd($SUDO, 'chmod', 'a+r', $keyring)
          or warn_info("Warning: chmod a+r $keyring via $SUDO failed.");
    }

    log_info("Writing /etc/apt/sources.list.d/gnupg.sources ...");

    my $sources_content = <<"EOF";
Types: deb
URIs: https://repos.gnupg.org/deb/gnupg/${suite}/
Suites: ${suite}
Components: main
Signed-By: /usr/share/keyrings/gnupg-keyring.gpg
EOF

    my $tmp_sources = "/tmp/gnupg.sources.$$";
    open my $sfh, '>', $tmp_sources
      or error("Cannot write temporary sources file $tmp_sources: $!");
    print $sfh $sources_content;
    close $sfh;

    my $dest_sources = '/etc/apt/sources.list.d/gnupg.sources';
    if ($> == 0) {
        rename $tmp_sources, $dest_sources
          or copy($tmp_sources, $dest_sources)
          or error("Cannot install $tmp_sources to $dest_sources: $!");
        unlink $tmp_sources;
    } else {
        run_cmd($SUDO, 'cp', $tmp_sources, $dest_sources)
          or error("Failed to copy $tmp_sources to $dest_sources via $SUDO.");
        unlink $tmp_sources;
    }

    log_info("Updating APT index (including official GnuPG repo)...");
    run_pkg('apt-get', 'update') or error("apt-get update failed.");

    log_info("Installing gnupg from official GnuPG repo (branch: $suite)...");
    if (!run_pkg('apt-get', 'install', '-y', '-t', $suite, 'gnupg2')) {
        if (!run_pkg('apt-get', 'install', '-y', '-t', $suite, 'gnupg')) {
            run_pkg('apt-get', 'install', '-y', 'gnupg')
              or error("Failed to install gnupg from either upstream or distro.");
        }
    }

    return;
}

###########
# Install #
###########

sub install_gnupg_linux {
    # Termux (Android)
    if ($ENV{TERMUX_VERSION} || ($ENV{ANDROID_ROOT} && (find_in_path('pkg') || find_in_path('apt')))) {
        log_info("Detected Termux on Android.");
        if (my $pkg = find_in_path('pkg')) {
            run_cmd($pkg, 'install', '-y', 'gnupg') or error("Failed to install gnupg via pkg.");
        } elsif (my $apt = find_in_path('apt')) {
            run_cmd($apt, 'update') or error("apt update failed.");
            run_cmd($apt, 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt.");
        } else {
            error("Termux environment detected but neither 'pkg' nor 'apt' found.");
        }
        return;
    }

    # Prefer Homebrew (Linuxbrew) when available and not root
    if (my $brew = find_in_path('brew')) {
        if ($> != 0) {
            log_info("Detected Homebrew on Linux. Installing gnupg via brew (no root)...");
            run_cmd($brew, 'install', 'gnupg') or error("Failed to install gnupg via Homebrew.");
            return;
        }
    }

    my %osinfo = read_os_release();
    my $id     = $osinfo{ID}      // '';
    my $id_like= $osinfo{ID_LIKE} // '';

    # Debian/Ubuntu/Devuan: use official GnuPG upstream repo logic
    if ($id =~ /^(debian|ubuntu|devuan)$/) {
        install_gnupg_debian_like(\%osinfo);
        return;
    }

    # ChromeOS + Chromebrew
    if ($id eq 'chromeos' || $ENV{CHROMEOS_RELEASE_NAME}) {
        log_info("Detected ChromeOS.");
        if (my $crew = find_in_path('crew')) {
            log_info("Installing gnupg via Chromebrew (crew)...");
            run_cmd($crew, 'install', 'gnupg') or error("Failed to install gnupg via crew.");
            return;
        }
        log_info("Chromebrew (crew) not found; falling back to generic Linux package manager detection.");
    }

    # Generic Debian-like (ID_LIKE=debian) but not direct Debian/Ubuntu/Devuan
    if ($id_like =~ /debian/ && $id !~ /^(debian|ubuntu|devuan)$/) {
        log_info("Detected Debian-like system via ID_LIKE; using distro gnupg.");
        run_pkg('apt-get', 'update') or error("apt-get update failed.");
        run_pkg('apt-get', 'install', '-y', 'gnupg') or error("Failed to install gnupg via apt-get.");
        return;
    }

    # Fedora / RHEL (dnf or yum)
    if (find_in_path('dnf')) {
        log_info("Detected dnf (Fedora/RHEL-like).");
        run_pkg('dnf', 'install', '-y', 'gnupg2') or error("Failed to install gnupg2 via dnf.");
        return;
    }
    if (find_in_path('yum')) {
        log_info("Detected yum (older RHEL/CentOS).");
        run_pkg('yum', 'install', '-y', 'gnupg2') or error("Failed to install gnupg2 via yum.");
        return;
    }

    # Arch / Manjaro
    if (find_in_path('pacman')) {
        log_info("Detected pacman (Arch-like).");
        run_pkg('pacman', '-Sy', '--noconfirm', 'gnupg') or error("Failed to install gnupg via pacman.");
        return;
    }

    # openSUSE / SLES
    if (find_in_path('zypper')) {
        log_info("Detected zypper (openSUSE/SLES).");
        run_pkg('zypper', '--non-interactive', 'install', 'gpg2') or error("Failed to install gpg2 via zypper.");
        return;
    }

    # Alpine
    if (find_in_path('apk')) {
        log_info("Detected apk (Alpine).");
        run_pkg('apk', 'add', 'gnupg') or error("Failed to install gnupg via apk.");
        return;
    }

    error("Could not detect a supported Linux package manager to install gnupg.");
}

sub install_gnupg_macos {
    log_info("Detected macOS.");
    if ($> == 0) {
        warn_info("Homebrew is normally installed as a regular user, not root.");
    }

    my $brew = find_in_path('brew');

    unless ($brew) {
        log_info("Homebrew not found. Installing Homebrew...");
        my $gh   = find_in_path('gh');
        my $git  = find_in_path('git');
        my $curl = find_in_path('curl');

        my $cmd;
        if ($gh) {
            $cmd = "$gh api -H 'Accept: application/vnd.github.raw' repos/Homebrew/install/contents/install.sh --output - | /bin/bash";
        } elsif ($git) {
            $cmd = "tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t brewinst) && git clone --depth 1 https://github.com/Homebrew/install.git \"\$tmpdir/install\" && /bin/bash \"\$tmpdir/install/install.sh\" && rm -rf \"\$tmpdir\"";
        } elsif ($curl) {
            $cmd  = "$curl -fLsS --retry 5 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash";
        } else {
            error("Neither gh, git, nor curl is available to install Homebrew.");
        }

        system($cmd);
        if ($? != 0) {
            error("Homebrew installation seems to have failed.");
        }

        # Try standard locations
        if (-x '/opt/homebrew/bin/brew') {
            $brew = '/opt/homebrew/bin/brew';
            $ENV{PATH} = "/opt/homebrew/bin:$ENV{PATH}";
        } elsif (-x '/usr/local/bin/brew') {
            $brew = '/usr/local/bin/brew';
            $ENV{PATH} = "/usr/local/bin:$ENV{PATH}";
        } else {
            $brew = find_in_path('brew') or error("Homebrew installation failed; 'brew' not found.");
        }
    }

    log_info("Installing gnupg via Homebrew...");
    run_cmd($brew, 'install', 'gnupg') or error("Failed to install gnupg via Homebrew.");
}

sub install_gnupg_freebsd {
    log_info("Detected FreeBSD-like system.");
    my $pkg = find_in_path('pkg') or error("'pkg' not found; cannot install gnupg.");
    run_pkg($pkg, 'install', '-y', 'gnupg') or error("Failed to install gnupg via pkg.");
}

sub install_gnupg_openbsd {
    log_info("Detected OpenBSD.");
    my $pkg_add = find_in_path('pkg_add') or error("'pkg_add' not found; cannot install gnupg.");
    run_pkg($pkg_add, 'gnupg') or error("Failed to install gnupg via pkg_add.");
}

sub install_gnupg_netbsd {
    log_info("Detected NetBSD.");
    if (my $pkgin = find_in_path('pkgin')) {
        run_pkg($pkgin, '-y', 'install', 'gnupg') or error("Failed to install gnupg via pkgin.");
    } elsif (my $pkg_add = find_in_path('pkg_add')) {
        run_pkg($pkg_add, 'gnupg') or error("Failed to install gnupg via pkg_add.");
    } else {
        error("NetBSD pkgin/pkg_add not found; cannot install gnupg.");
    }
}

#####################
# Install if needed #
#####################

unless ($keygen_only) {
    if    ($os_uname eq 'linux')   { install_gnupg_linux()  }
    elsif ($os_uname eq 'darwin')  { $need_root_pkgmgr = 0; install_gnupg_macos() }
    elsif ($os_uname eq 'freebsd') { install_gnupg_freebsd() }
    elsif ($os_uname eq 'dragonfly') { install_gnupg_freebsd() }
    elsif ($os_uname eq 'openbsd') { install_gnupg_openbsd() }
    elsif ($os_uname eq 'netbsd')  { install_gnupg_netbsd() }
    else {
        error("Unsupported OS: $os_uname");
    }
} else {
    log_info("Key-generation-only mode requested; skipping GnuPG installation.");
}

find_in_path('gpg') or error("gpg binary not found. Please ensure GnuPG is installed and in PATH.");

# Install config before keygen / exit
install_gpg_conf_from_dir();

if ($install_only) {
    log_info("Install-only mode: GnuPG is installed and available as 'gpg'.");
    log_info("Config files from ./gpg-conf were installed into ~/.gnupg/ (if present).");
    log_info("No keys were generated.");
    exit 0;
}

#########################
# PQC / Kyber detection #
#########################

log_info("Checking for Kyber (post-quantum) support in this GnuPG build...");

my $gpg_version = qx(gpg --version 2>/dev/null);
my $kyber_supported = 0;

if ($gpg_version =~ /(Kyber(?:512|768|1024)|X25519\+Kyber|X448\+Kyber)/i) {
    $kyber_supported = 1;
} elsif ($gpg_version =~ /Kyber/i) {
    $kyber_supported = 1;
}

if ($force_no_pqc) {
    log_info("PQC support explicitly disabled via --no-pqc.");
    $kyber_supported = 0;
}

if (!$kyber_supported && $force_pqc_only) {
    error("Option --pqc-only was requested, but this GnuPG build does not advertise any Kyber/PQC algorithms.");
}

if ($kyber_supported) {
    log_info("Kyber/PQC algorithms detected in this GnuPG build.");
} else {
    log_info("No Kyber/PQC algorithms detected in this GnuPG build.");
}

my $generate_pqc = 0;
my $generate_rsa = 1;

if ($kyber_supported && !$force_no_pqc) {
    $generate_pqc = 1;
}

if ($force_pqc_only) {
    $generate_pqc = 1;
    $generate_rsa = 0;
}

print "\n";
if ($generate_pqc && $generate_rsa) {
    log_info("Key generation plan: ECC+Kyber (PQC) key + RSA 4096-bit compatibility key.");
} elsif ($generate_pqc) {
    log_info("Key generation plan: ECC+Kyber (PQC) key only (no RSA compatibility key).");
} else {
    log_info("Key generation plan: RSA 4096-bit key only.");
}

####################
# Identity prompts #
####################

print "\nPlease enter the information to embed in your new GnuPG key(s).\n";

my $default_user_name  = $ENV{USER} // 'user';
my $default_host_name  = qx(hostname 2>/dev/null);
chomp $default_host_name if defined $default_host_name;
$default_host_name ||= 'localhost';

my $default_user_email = "$default_user_name\@$default_host_name";

my $user_name;
my $user_email;

if ($name_override) {
    $user_name = $name_override;
    log_info("Using provided name: $user_name");
} else {
    print "Real name [$default_user_name]: ";
    my $input = <STDIN>;
    defined $input or error("Input closed.");
    chomp $input;
    $user_name = $input || $default_user_name;
}

if ($email_override) {
    $user_email = $email_override;
    log_info("Using provided email: $user_email");
} else {
    print "Email address [$default_user_email]: ";
    my $input = <STDIN>;
    defined $input or error("Input closed.");
    chomp $input;
    $user_email = $input || $default_user_email;
}

my $uid = "$user_name <$user_email>";

##################
# Key generation #
##################

my ($pqc_key_id, $pqc_fpr) = ('', '');
my ($rsa_key_id, $rsa_fpr) = ('', '');

sub latest_sec_key_id {
    my @lines = qx(gpg --list-secret-keys --with-colons --keyid-format LONG 2>/dev/null);
    my $kid = '';
    for my $l (@lines) {
        if ($l =~ /^sec:/) {
            my @f = split /:/, $l;
            $kid = $f[4] if defined $f[4];
        }
    }
    return $kid;
}

sub key_fingerprint {
    my ($keyid) = @_;
    my @lines = qx(gpg --with-colons --fingerprint $keyid 2>/dev/null);
    for my $l (@lines) {
        if ($l =~ /^fpr:/) {
            my @f = split /:/, $l;
            return $f[9] if defined $f[9];
        }
    }
    return '';
}

# 1) PQC key
if ($generate_pqc) {
    log_info("Generating a composite ECC+Kyber (PQC) key (no expiry, no passphrase)...");
    my @cmd = (
        'gpg', '--batch', '--yes',
        '--pinentry-mode', 'loopback',
        '--passphrase', '',
        '--quick-gen-key', "$uid (PQC)", 'pqc', 'default', '0'
    );
    if (run_cmd(@cmd)) {
        $pqc_key_id = latest_sec_key_id();
        if ($pqc_key_id) {
            $pqc_fpr = key_fingerprint($pqc_key_id);
        }
    } else {
        warn_info("GnuPG appears to support Kyber, but PQC key generation failed.");
        $pqc_key_id   = '';
        $pqc_fpr      = '';
        $generate_pqc = 0;
        if ($force_pqc_only) {
            error("PQC key generation failed and --pqc-only was requested. No RSA fallback will be created.");
        } else {
            log_info("Continuing with RSA key generation only.");
        }
    }
}

# 2) RSA key
if ($generate_rsa) {
    log_info("Generating an RSA 4096-bit key (no expiry, no passphrase) for compatibility...");

    my $tmpdir = $ENV{TMPDIR} || '/tmp';
    my $conf   = "$tmpdir/gpg-key-rsa-$$.conf";

    open my $out, '>', $conf or error("Cannot write temp RSA key conf $conf: $!");
    print $out <<"EOF";
Key-Type: rsa
Key-Length: 4096
Subkey-Type: rsa
Subkey-Length: 4096
Name-Real: $user_name
Name-Email: $user_email
Name-Comment: RSA compatibility key
Expire-Date: 0
%no-protection
%commit
EOF
    close $out;

    if (!run_cmd('gpg', '--batch', '--generate-key', $conf)) {
        unlink $conf;
        error("RSA key generation failed.");
    }

    unlink $conf;
    $rsa_key_id = latest_sec_key_id() or error("Could not determine generated RSA key ID.");
    $rsa_fpr    = key_fingerprint($rsa_key_id);
}

# Determine primary key for examples
my $primary_key_id = '';
if ($generate_pqc && $pqc_key_id) {
    $primary_key_id = $pqc_key_id;
} elsif ($generate_rsa && $rsa_key_id) {
    $primary_key_id = $rsa_key_id;
}
$primary_key_id or error("Could not determine any key ID for usage examples; key generation seems to have failed.");

print "\n";
if ($generate_pqc && $pqc_key_id && $generate_rsa && $rsa_key_id) {
    log_info("New composite ECC+Kyber (PQC) key created:");
    log_info("  Key ID:       $pqc_key_id");
    log_info("  Fingerprint:  $pqc_fpr") if $pqc_fpr;
    log_info("Additional RSA 4096-bit compatibility key created:");
    log_info("  Key ID:       $rsa_key_id");
    log_info("  Fingerprint:  $rsa_fpr") if $rsa_fpr;
} elsif ($generate_pqc && $pqc_key_id) {
    log_info("New composite ECC+Kyber (PQC) key created:");
    log_info("  Key ID:       $pqc_key_id");
    log_info("  Fingerprint:  $pqc_fpr") if $pqc_fpr;
} elsif ($generate_rsa && $rsa_key_id) {
    log_info("New RSA 4096-bit key created:");
    log_info("  Key ID:       $rsa_key_id");
    log_info("  Fingerprint:  $rsa_fpr") if $rsa_fpr;
} else {
    error("Key generation did not produce any usable keys.");
}

##############################
# Upload to keys.openpgp.org #
##############################

sub upload_keys_to_keyserver {
    my $keyserver = 'hkps://keys.openpgp.org';
    my @keys;

    push @keys, $pqc_fpr if $pqc_fpr;
    push @keys, $rsa_fpr if $rsa_fpr;

    unless (@keys) {
        print "\n";
        log_info("No fingerprints available to upload to $keyserver.");
        return;
    }

    print "\n";
    log_info("Uploading generated keys to $keyserver:");
    log_info("  @keys");

    if (!run_cmd('gpg', '--keyserver', $keyserver, '--send-keys', @keys)) {
        warn_info("Failed to upload keys to $keyserver");
    } else {
        log_info("Keys successfully submitted to $keyserver.");
        log_info("Note: keys.openpgp.org require email verification before your UID appears as 'published'.");
    }
}

upload_keys_to_keyserver();

######################
# Final instructions #
######################

print "\n";
log_info("IMPORTANT:");
if ($generate_pqc && $pqc_key_id && $generate_rsa && $rsa_key_id) {
    log_info("  Both the ECC+Kyber key and the RSA key currently have NO passphrase.");
} elsif ($generate_pqc && $pqc_key_id) {
    log_info("  The ECC+Kyber key currently has NO passphrase.");
} elsif ($generate_rsa && $rsa_key_id) {
    log_info("  This RSA key currently has NO passphrase.");
}
log_info("  For better security, you should set a passphrase on the key(s) you actually use:");
print "    gpg --edit-key $pqc_key_id\n    gpg> passwd\n" if $generate_pqc && $pqc_key_id;
print "    gpg --edit-key $rsa_key_id\n    gpg> passwd\n" if $generate_rsa && $rsa_key_id;
print "\n";

print <<"EOF";
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

log_info("Done.");
