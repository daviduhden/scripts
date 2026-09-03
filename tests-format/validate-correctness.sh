#!/bin/sh

set -u

# validate-correctness.sh
# - Static semantic/correctness auditor for the scripts in this
#   repository. Complements (does not duplicate) the format/syntax
#   validators (validate-shell.sh, validate-perl.sh,
#   validate-make.sh): this one checks that the commands, options,
#   paths and assumptions used by each script are actually valid on
#   the system the script targets.
# - Usage:
#     ./validate-correctness.sh [OPTIONS] [ROOT_DIR]
#   Options:
#     --target T     Audit only target T: openbsd, debian, secureblue,
#                    all (static checks for every target) or host
#                    (auto-detect; default).
#     --strict       Exit non-zero also on WARNING and UNVERIFIED
#                    findings (by default only ERROR findings make the
#                    exit status non-zero).
#     --verbose      Also print INFO findings.
#     --quiet        Only print ERROR findings.
#     --format F     Output format: text (default) or json.
#     -h, --help     Show this help.
#   Exit status:
#     0  no ERROR findings (in --strict mode: also no WARNING or
#        UNVERIFIED findings)
#     1  ERROR findings present (in --strict mode: also WARNING or
#        UNVERIFIED)
#     2  usage error
#
# How rules were established:
# - Option availability for OpenBSD was verified against the manual
#   pages on man.openbsd.org and, where needed, the OpenBSD source
#   tree: find(1) has -mindepth/-maxdepth/-print0/-delete but not
#   -printf/-quit; readlink(1) has -f and -n but not -m/-e; xargs(1)
#   has -0/-r/-P but no long options; stat(1) uses -f format (no -c);
#   date(1) has no -d; head(1) has no -c; sort(1) has no -V/-h/-R;
#   cp(1) has -a; rcctl(8) has -q; basename(1) has no options at all;
#   ksh(1) is pdksh: no local, no declare, no pipefail, no <<<,
#   print(1) supports only -n/-e/-E.
# - GNU-only behavior was verified against the coreutils/findutils
#   documentation.
# - The pipefail/SIGPIPE rules reflect verified behavior: a
#   pipeline consumer that exits early (`grep -q`, `head`) closes
#   the pipe; the producer then dies of SIGPIPE and, with
#   `set -o pipefail`, the whole pipeline reports 141 even when
#   the data was found.
# - Each rule below carries a "Reference:" pointing at the manual or
#   project that documents the behavior it relies on.
#
# UNVERIFIED findings are emitted when a construct cannot be
# classified with enough confidence (e.g. an unknown interpreter in
# a shebang); they never turn into errors on their own.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

usage() {
	printf '%s\n' \
		"Usage: $0 [--target openbsd|debian|secureblue|all|host]" \
		"        [--strict] [--verbose] [--quiet]" \
		"        [--format text|json] [ROOT_DIR]" >&2
	exit 2
}

err() {
	printf '%s\n' "[ERROR] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || err "$1 not found in PATH"
}

# ------------------------------------------------------------------
# Findings handling. Records are TAB-separated:
#   severity<TAB>file<TAB>line<TAB>message<TAB>reference<TAB>fix
# ------------------------------------------------------------------

TAB=$(printf '\t')

note() {
	sev=$1
	ln=$2
	file=$3
	msg=$4
	ref=$5
	fix=$6
	printf '%s\n' \
		"$sev${TAB}$file${TAB}$ln${TAB}$msg${TAB}$ref${TAB}$fix" \
		>>"$FINDINGS"
}

# ------------------------------------------------------------------
# Language / target detection
# ------------------------------------------------------------------

detect_host() {
	HOST_OS=$(uname -s 2>/dev/null || printf '%s' unknown)
	HOST_FAMILY=
	case "$HOST_OS" in
	OpenBSD)
		HOST_FAMILY=openbsd
		;;
	Linux)
		if [ -r /etc/os-release ]; then
			# Read the file without sourcing shell code.
			os_id=$(sed -n 's/^ID=//p' /etc/os-release |
				tr -d '"')
			os_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release |
				tr -d '"')
			case " $os_id $os_like " in
			*" fedora "*) HOST_FAMILY=secureblue ;;
			*" debian "* | *" ubuntu "*) HOST_FAMILY=debian ;;
			esac
		fi
		;;
	esac
}

# ------------------------------------------------------------------
# Shell keywords and builtins that are never external commands.
# ------------------------------------------------------------------

KEYWORDS='if then else elif fi for while until do done case esac in function select time local typeset declare readonly export unset set shift return exit break continue echo printf print read cd eval exec source . : true false test [ [[ command builtin env umask ulimit wait trap hash type pwd getopts let whence emulate autoload newgrp'

# ------------------------------------------------------------------
# Commands known to exist on each platform (used by the probe that
# verifies command existence for scripts targeting the host system).
# ------------------------------------------------------------------

COMMON_CMDS='awk bash basename bmake bzip2 cat cc chgrp chmod chown chsh clang cmake cmp comm cp csh cut date dd df diff dirname du expr false fgrep file find fmt ftp getent git gh git-lfs gmake gpg grep gunzip gzip head hostname id install join jq kill ksh ksh93 ldconfig less ln ls make mandoc md5 mkdir mount mv netstat nice nl nohup od openssl passwd paste patch perl pgrep pkill printf ps pwd readlink reboot rm rmdir scp sed seq sh sha1 sha256 sha384 sha512 sleep sort ssh stat su sudo tail tar tee test touch tr true tty uname uniq unzip uptime vi wc wget who xargs xz zip curl rsync mktemp'

OPENBSD_CMDS='doas rcctl sysmerge sysupgrade syspatch pkg_add pkg_delete pkg_info acme-client crush lynis signify'

DEBIAN_CMDS='apt apt-get apt-cache dpkg dpkg-query lsb_release needrestart runuser lscpu lspci lsusb free uptime ip ss journalctl systemctl update-rc.d chkconfig service sv herd rc-update rc-service s6-rc s6-svc systemd runit runit-init openrc-init shepherd s6-svscan tor torsocks i2pd monerod monero-wallet-cli monero-lws-daemon useradd groupadd logname sha256sum certbot lynis systemcheck nproc sysctl btop fastfetch edit signify go'

SECUREBLUE_CMDS='rpm rpm-ostree bootc ujust flatpak fwupdmgr fwupdtool fpaste run0 run0edit runuser journalctl systemctl ip ss lsblk blkid free uptime logname brew brew-proxy pipx task kpackagetool6 7z socat clamonacc clamdscan freshclam clamd semanage restorecon getenforce setenforce setsebool yt-dlp ffmpeg cargo rustc rustup go nproc dmesg sysctl lynis'

is_allowed() {
	fam=$1
	cmd=$2
	case " $COMMON_CMDS " in
	*" $cmd "*) return 0 ;;
	esac
	extra=
	case "$fam" in
	openbsd) extra=$OPENBSD_CMDS ;;
	debian) extra=$DEBIAN_CMDS ;;
	secureblue) extra=$SECUREBLUE_CMDS ;;
	*) return 1 ;;
	esac
	case " $extra " in
	*" $cmd "*) return 0 ;;
	esac
	return 1
}

# ------------------------------------------------------------------
# awk programs. Written to temporary files at startup so that the
# regexes can contain arbitrary characters (single quotes, etc.).
# ------------------------------------------------------------------

write_awk_programs() {
	cat >"$VCSCANAWK" <<'AWK_SCAN'
function gsev(   s) {
    # Severity for GNU-only constructs: a bug on OpenBSD targets,
    # an informational portability note on Linux targets, and a
    # portability warning in generic/POSIX contexts.
    s = "WARNING"
    if (fam == "openbsd") s = "ERROR"
    else if (fam == "debian" || fam == "secureblue") s = "INFO"
    return s
}
function emit(sev, ln, msg, ref, fix) {
    printf "%s\t%s\t%d\t%s\t%s\t%s\n", sev, FILENAME, ln, msg, ref, fix
    if (sev == "ERROR") n_err++
    else if (sev == "WARNING") n_warn++
    else if (sev == "INFO") n_info++
    else if (sev == "UNVERIFIED") n_unver++
}
function check(line, raw) {
    # ---- GNU-only options (severity depends on target) ----
    if (line ~ /(^|[[:space:];|&()])(grep|egrep)[[:space:]]+(-P|--perl-regexp)([[:space:]]|$)/)
        emit(gsev(), NR, "grep -P is a GNU extension", "GNU grep(1); OpenBSD grep(1)", "Use grep -E (extended regex) or awk")
    if (line ~ /(^|[[:space:];|&()])sed[[:space:]]+(-r|--regexp-extended)([[:space:]]|$)/)
        emit(gsev(), NR, "sed -r is GNU-only", "GNU sed(1); OpenBSD sed(1)", "Use sed -E (portable extended regex)")
    if (line ~ /(^|[[:space:];|&()])xargs[[:space:]]+(-a|--null|--no-run-if-empty|--max-args|--max-procs|--verbose)([[:space:]]|$)/)
        emit(gsev(), NR, "GNU-only xargs option", "GNU xargs(1); OpenBSD xargs(1)", "OpenBSD xargs supports -0, -r, -n, -P, -s, -L, -I, -J")
    if (line ~ /(^|[[:space:]])-(printf|quit|fprintf)([[:space:]="]|$)/)
        emit(gsev(), NR, "find -printf/-quit/-fprintf are GNU extensions", "OpenBSD find(1)", "Use -print/-print0 and -exec (both in OpenBSD find)")
    if (line ~ /(^|[[:space:];|&()])stat[[:space:]]+(-c|--format)([[:space:]]|$)/)
        emit(gsev(), NR, "stat -c/--format is GNU-only", "GNU stat(1); OpenBSD stat(1)", "OpenBSD stat uses -f format")
    if (line ~ /(^|[[:space:];|&()])date[[:space:]]+(-d|--date)([[:space:]]|$)/)
        emit(gsev(), NR, "date -d/--date is GNU-only", "GNU date(1); OpenBSD date(1)", "Use date -r seconds or compute the date differently")
    if (line ~ /(^|[[:space:];|&()])sort[[:space:]]+(-V|--version-sort|-h|--human-numeric-sort|-R|--random-sort)([[:space:]]|$)/)
        emit(gsev(), NR, "GNU-only sort option", "GNU sort(1); OpenBSD sort(1)", "Implement version/numeric/random ordering explicitly")
    if (line ~ /(^|[[:space:];|&()])head[[:space:]]+(-c|--bytes)([[:space:]]|$)/)
        emit(gsev(), NR, "head -c is GNU-only", "GNU head(1); OpenBSD head(1)", "Use dd bs=N count=1 or head -n")
    if (line ~ /(^|[[:space:];|&()])tail[[:space:]]+--bytes([[:space:]]|$)/)
        emit(gsev(), NR, "tail --bytes is GNU-only", "GNU tail(1)", "Use portable short options")
    if (line ~ /(^|[[:space:];|&()])install[[:space:]]+--[a-z-]+/)
        emit(gsev(), NR, "install long options are GNU-only", "GNU install(1); OpenBSD install(1)", "Use -m, -d, -o, -g short options")
    if (line ~ /(^|[[:space:];|&()])cp[[:space:]]+--[a-z-]+/)
        emit(gsev(), NR, "cp long options are GNU-only", "GNU cp(1); OpenBSD cp(1)", "Use short options (-a, -R, -p, ...)")
    # mktemp without a template is GNU-only. Handle the common
    # case where the template sits on a continuation line.
    if (mktemp_pending != 0) {
        if (raw ~ /XXXX/) mktemp_pending = 0
        else {
            emit(gsev(), mktemp_pending, "mktemp without a template is GNU-only", "GNU mktemp(1); OpenBSD mktemp(1)", "Always pass a template ending in XXXXXX")
            mktemp_pending = 0
        }
    }
    if (line ~ /(^|[;|&(])mktemp([[:space:]]|$)/ && raw !~ /XXXX/) {
        if (line ~ /\\[[:space:]]*$/) mktemp_pending = NR
        else
            emit(gsev(), NR, "mktemp without a template is GNU-only", "GNU mktemp(1); OpenBSD mktemp(1)", "Always pass a template ending in XXXXXX")
    }
    if (line ~ /(^|[[:space:];|&()])readlink[[:space:]]+(-m|-e)([[:space:]]|$)/)
        emit(gsev(), NR, "readlink -m/-e are GNU-only", "GNU readlink(1); OpenBSD readlink(1)", "OpenBSD readlink supports -f and -n")

    # ---- OS-specific commands in the wrong tree ----
    if (fam == "openbsd") {
        if (line ~ /(^|[[:space:];|&()])(systemctl|journalctl|apt|apt-get|apt-cache|dpkg|dpkg-query|rpm-ostree|bootc|ujust|run0|run0edit|flatpak|fwupdmgr|fwupdtool|fpaste|firewall-cmd|loginctl|usermod|groupadd|useradd|runuser|needrestart|update-rc\.d|chkconfig|lsb_release|hostnamectl|localectl|timedatectl|lsblk|blkid|sha256sum|sha1sum|md5sum|nproc|gmake|lscpu|lspci|lsusb|free)([[:space:]]|$)/)
            emit("ERROR", NR, "Linux-specific command used in an OpenBSD script", "OpenBSD base system; man.openbsd.org", "Replace with the OpenBSD equivalent")
        if (line ~ /(^|[^[:alnum:]_$])(ip|ss)([[:space:]]|$)/)
            emit("ERROR", NR, "iproute2 command not available in OpenBSD base", "OpenBSD ifconfig(8), route(8)", "Use ifconfig/route on OpenBSD")
        if (line ~ /(^|[[:space:];|&()])chattr([[:space:]]|$)/)
            emit("ERROR", NR, "chattr/lsattr do not exist on OpenBSD", "OpenBSD chflags(1)", "Use chflags instead")
    }
    if (fam == "debian" || fam == "secureblue") {
        if (line ~ /(^|[[:space:];|&()])(pkg_add|pkg_delete|pkg_info|rcctl|syspatch|sysmerge|fw_update|pfctl|bioctl|disklabel|acme-client|doas)([[:space:]]|$)/)
            emit("WARNING", NR, "OpenBSD-specific command used in a Linux script", "OpenBSD base system", "Verify this code path is guarded and use the Linux equivalent")
        if (line ~ /(^|[[:space:];|&()])(ifconfig|netstat)([[:space:]]|$)/)
            emit("WARNING", NR, "deprecated networking tool on Linux", "iproute2 ip(8), ss(8)", "Use ip and ss")
        if (line ~ /(^|[[:space:];|&()])apt-key([[:space:]]|$)/)
            emit("WARNING", NR, "apt-key is deprecated", "Debian wiki: AptKey deprecation", "Install keys into /etc/apt/keyrings and use Signed-By")
        if (line ~ /(^|[[:space:];|&()])stat[[:space:]]+-f([[:space:]]|$)/)
            emit("ERROR", NR, "stat -f means 'filesystem' on GNU stat", "GNU stat(1)", "Use stat -c or --format on Linux")
    }

    # ---- OS-specific paths in the wrong tree ----
    if (fam == "openbsd" && line ~ /(\/etc\/apt\/|\/etc\/systemd\/|\/var\/lib\/dpkg|\/etc\/ld\.so\.preload|\/run\/user\/|\/etc\/os-release|\/etc\/logrotate\.d\/|\/etc\/sysctl\.d\/|\/etc\/default\/|\/usr\/lib\/systemd\/|\/proc\/)/)
        emit("ERROR", NR, "Linux-specific path in an OpenBSD script", "OpenBSD filesystem layout (hier(7))", "These paths do not exist on OpenBSD")
    if ((fam == "debian" || fam == "secureblue") && line ~ /(\/etc\/doas\.conf|\/etc\/rc\.conf\.local|\/var\/sysmerge\/|\/etc\/rc\.firsttime|\/upgrade\.site|\/var\/db\/pkg\/|\/etc\/firmware\/|\/etc\/hostname\.[a-z]|\/usr\/ports\/)/)
        emit("WARNING", NR, "OpenBSD-specific path in a Linux script", "OpenBSD filesystem layout (hier(7))", "These paths do not exist on Debian/Fedora")

    # ---- bashisms in ksh/POSIX contexts ----
    if (fam == "openbsd") {
        if (line ~ /(^|[^[:alnum:]_])local([[:space:]]|$)/)
            emit("ERROR", NR, "bash 'local' is not available in OpenBSD ksh (pdksh)", "OpenBSD ksh(1)", "Use typeset inside functions")
        if (line ~ /(^|[[:space:];|&()])(declare|readarray|mapfile|shopt)([[:space:]]|$)/)
            emit("ERROR", NR, "bash builtin not available in OpenBSD ksh", "OpenBSD ksh(1)", "Use typeset and ksh constructs")
        if (line ~ /PIPESTATUS|BASH_SOURCE|BASH_VERSION|\$\{BASH_/)
            emit("ERROR", NR, "bash-specific variable in an OpenBSD script", "OpenBSD ksh(1)", "Use ksh equivalents or declare the script as bash")
        if (line ~ /<<</)
            emit("ERROR", NR, "here-string <<< is bash-only", "OpenBSD ksh(1)", "Use printf '%s' \"$x\" | cmd or a here-document")
        if (line ~ /\(\(</)
            emit("ERROR", NR, "process substitution <(...) is bash-only", "OpenBSD ksh(1)", "Use a temporary file or a FIFO")
        if (raw ~ /\$'[^']*\\/)
            emit("ERROR", NR, "$'...' quoting is not available in OpenBSD ksh (pdksh)", "OpenBSD ksh(1)", "Use printf with octal escapes instead")
    }
    if (fam == "generic") {
        if (line ~ /\[\[/)
            emit("WARNING", NR, "[[ ]] is not POSIX sh", "POSIX sh(1)", "Use [ ] with care or declare the script as bash/ksh")
        if (raw ~ /\$'[^']*\\/)
            emit("WARNING", NR, "$'...' is not POSIX sh", "POSIX sh(1)", "Use printf with octal escapes")
    }

    # ---- destructive operations ----
    if (line ~ /(^|[[:space:];|&()])rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]]|$)/) {
        if (raw ~ /\$|"|\{\}|--/)
            emit("INFO", NR, "rm -rf with quoted/bounded operand", "rm(1)", "Ensure the operand is bounded and quoted")
        else
            emit("WARNING", NR, "rm -rf with unquoted/unbounded operand", "rm(1)", "Quote the path and bound the deletion")
        has_destructive = 1
    }
    if (line ~ /(^|[[:space:];|&()])(chmod|chown)[[:space:]]+-R/) {
        if (raw ~ /"/)
            emit("INFO", NR, "chmod/chown -R with quoted target", "chmod(1), chown(1)", "Ensure the recursive target is bounded")
        else
            emit("WARNING", NR, "chmod/chown -R with unquoted target", "chmod(1), chown(1)", "Quote the path and bound the recursion")
        has_destructive = 1
    }
    if (line ~ /(^|[[:space:];|&()])find[[:space:]]+\/([[:space:]]|$)/)
        emit("WARNING", NR, "find rooted at / walks the whole root filesystem", "find(1)", "Bound the search (e.g. /var/log) or use -xdev")
    if (line ~ /(^|[[:space:];|&()])xargs([[:space:]]|$)/ && line !~ /(-0|--null)/)
        emit("WARNING", NR, "xargs without -0 breaks on filenames with spaces", "xargs(1)", "Use find -print0 | xargs -0 (both supported by OpenBSD find/xargs)")

    # ---- pipe to shell / eval / temp files / TOCTOU ----
    if (line ~ /(curl|wget|ftp)[^;|&]*\|[[:space:]]*(ba)?sh([[:space:]]|$)/)
        emit("ERROR", NR, "piping a remote script directly into a shell", "ShellCheck SC2320", "Download to a file, verify it, then execute it")
    if (lang != "perl" && lang != "python" && line ~ /(^|[^[:alnum:]_])eval([[:space:]]|$)/)
        emit("WARNING", NR, "eval usage", "POSIX sh(1)", "Avoid eval; pass arguments explicitly")
    if (line ~ /\[[[:space:]]+-[ef][[:space:]]+[^]]*\][[:space:]]*(&&|;)[[:space:]]*rm[[:space:]]/)
        emit("INFO", NR, "check-then-remove pattern (TOCTOU-prone)", "POSIX sh(1)", "Use rm -f and test within the same operation")
    if (line ~ />[[:space:]]*"\/tmp\/[^"]*"([[:space:]]|$)/ && line !~ /\$\$|mktemp|\$\(date/)
        emit("WARNING", NR, "fixed-name temporary file under /tmp", "mktemp(1)", "Use mktemp for unpredictable temp file names")

    # ---- set -e / pipefail analysis (per file) ----
    if (line ~ /pipefail/) {
        if (line ~ /\(set -o pipefail\)/) has_guard = 1
        else has_pipefail = 1
    }
    if (line ~ /(^|[[:space:];|&])set[[:space:]]+(-e([[:space:]]|$)|-[^-]*e)|-o[[:space:]]+errexit/)
        has_sete = 1

    # ---- early-exit pipeline consumers (reported in END only
    #      when the script actually enables pipefail) ----
    if (line ~ /\|[[:space:]]*head([[:space:]]|$|-)/)
        pipe_head[++ph_n] = NR
    if (prev_pipe && line ~ /^head([[:space:]]|$|-)/)
        pipe_head[++ph_n] = NR
    if (line ~ /\|[[:space:]]*grep([[:space:]]+-[A-Za-z]*q|--quiet)/ &&
        line !~ /-quit/)
        pipe_grep[++pg_n] = NR
}
{
    if (skip_hd) {
        if ($0 ~ ("^" hd_delim "[[:space:]]*$")) {
            skip_hd = 0
            hd_delim = ""
        }
        next
    }
    raw = $0
    masked = $0
    if (masked ~ /^[[:space:]]*#/) next
    sub(/^[[:space:]]*/, "", masked)
    # Mask quoted strings so that rule texts and string literals
    # cannot trigger the patterns below. The raw line is still
    # available for checks that need the quoting context.
    gsub(/"[^"]*"/, "QQ", masked)
    gsub(/'[^']*'/, "QQ", masked)
    check(masked, raw)
    prev_pipe = 0
    if (masked ~ /\|[[:space:]]*$/) prev_pipe = 1
    # Track here-document bodies: they are skipped entirely
    # (they are generated code or config, not shell to audit).
    if ($0 ~ /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/) {
        m = $0
        sub(/^.*<<-?[[:space:]]*/, "", m)
        if (m ~ /^['"]/) {
            hd_delim = substr(m, 2)
            sub(/['"].*$/, "", hd_delim)
        } else {
            match(m, /^[A-Za-z_][A-Za-z0-9_]*/)
            hd_delim = substr(m, RSTART, RLENGTH)
        }
        skip_hd = 1
    }
}
END {
    if (has_pipefail) {
        for (i = 1; i <= ph_n; i++)
            emit("WARNING", pipe_head[i], "head closes the pipe early; under pipefail the producer may die of SIGPIPE and fail the pipeline", "bash(1) pipefail; signal(7) SIGPIPE", "Use sed -n '1p' (reads the whole stream) or capture the output first")
        for (i = 1; i <= pg_n; i++)
            emit("WARNING", pipe_grep[i], "grep -q closes the pipe early; under pipefail the producer may die of SIGPIPE and fail the pipeline", "bash(1) pipefail; signal(7) SIGPIPE", "Capture the output first, or drop -q and redirect grep's output")
    }
    if (fam == "openbsd" && has_pipefail && !has_guard)
        emit("ERROR", 1, "set -o pipefail is not available in OpenBSD ksh (pdksh)", "OpenBSD ksh(1)", "Guard it: if (set -o pipefail) >/dev/null 2>&1; then set -o pipefail; fi")
    if (fam == "generic" && has_pipefail)
        emit("WARNING", 1, "pipefail is not POSIX", "POSIX sh(1)", "Guard the option or document the required shell")
    if ((fam == "debian" || fam == "secureblue" || fam == "openbsd") && has_destructive && !has_sete)
        emit("INFO", 1, "script has destructive operations but no 'set -e'", "POSIX sh(1)", "Consider 'set -e' so critical failures stop the script")
}
AWK_SCAN

	cat >"$VCEXTAWK" <<'AWK_EXTRACT'
# Extract external-command candidates from a shell script:
# the first word of every statement, skipping keywords, case
# labels, assignments, quoted strings, redirect targets,
# here-document bodies, multi-line quoted strings and line
# continuations.
BEGIN { skip_hd = 0; str_cont = 0; code_cont = 0; in_sq = 0 }
skip_hd == 1 {
    if ($0 ~ "^" hd_delim "[[:space:]]*$") {
        skip_hd = 0
        hd_delim = ""
    }
    next
}
{
    orig = $0
    line = $0
    sub(/^[[:space:]]*/, "", line)
    if (line ~ /^#/) next

    # Body of a multi-line single-quoted string (e.g. an awk
    # program embedded in the script).
    if (in_sq == 1) {
        if (line ~ /'/) in_sq = 0
        next
    }

    # Continuation of a double-quoted string broken with ""\ .
    if (str_cont == 1) {
        str_cont = 0
        if (line ~ /"[[:space:]\\]*$/) {
            if (line ~ /""\\[[:space:]]*$/) str_cont = 1
            next
        }
    }
    if (line ~ /""\\[[:space:]]*$/) str_cont = 1

    # Detect a here-document opener, remember the delimiter and
    # remove the opener from the line so it contributes no tokens.
    if (line ~ /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/) {
        m = line
        sub(/^.*<<-?[[:space:]]*/, "", m)
        if (m ~ /^['"]/) {
            hd_delim = substr(m, 2)
            sub(/['"].*$/, "", hd_delim)
        } else {
            match(m, /^[A-Za-z_][A-Za-z0-9_]*/)
            hd_delim = substr(m, RSTART, RLENGTH)
        }
        sub(/<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?.*$/, "", line)
        skip_hd = 1
    }

    # Mask quoted strings so that separators (;, |, &, <, >)
    # inside them cannot create fake command tokens. A remaining
    # unbalanced quote starts a multi-line single-quoted string.
    gsub(/"[^"]*"/, "QQUOTED", line)
    gsub(/'[^']*'/, "QQUOTED", line)
    nq = gsub(/'/, "'", line)
    if (nq % 2 == 1) in_sq = 1

    # Continuation of a command line ending with a backslash:
    # the next line's first statement segment contains arguments,
    # not a command. Runs after masking so that separators inside
    # quoted arguments cannot shorten the removed segment.
    if (code_cont == 1) {
        code_cont = 0
        sub(/^[^;|&<>]+/, "", line)
    }
    if (orig ~ /\\[[:space:]]*$/ && orig !~ /""\\[[:space:]]*$/)
        code_cont = 1

    # Remove redirect targets (> file, >>file, 2>/dev/null, ...).
    while (sub(/>[[:space:]]*[^[:space:];|&<>]*/, "", line)) {
        ;
    }

    n = split(line, segs, /[;|&<>]/)
    for (i = 1; i <= n; i++) {
        seg = segs[i]
        sub(/^[[:space:]]+/, "", seg)
        if (seg == "") continue
        # quoted strings (masked above)
        if (seg ~ /^QQUOTED/) continue
        # case labels: word(s) followed by ')' (EOL or space)
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_.|[:space:]-]*\)([[:space:]]|$)/)
            continue
        # command substitution in an assignment: VAR=$(cmd ...)
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_]*="?\$\(/) {
            sub(/^[^($]*\$\(/, "", seg)
            sub(/^[[:space:]]+/, "", seg)
            if (match(seg, /^[A-Za-z_][A-Za-z0-9_.\/-]*/))
                print substr(seg, 1, RLENGTH)
            continue
        }
        # plain assignments (VAR=value, VAR+=(...), VAR=$(cmd ...))
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=[^[:space:]]*[[:space:]]*$/)
            continue
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=\([^)]*\)[[:space:]]*$/)
            continue
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_]*=\$\([^)]*\)[[:space:]]*$/)
            continue
        # array assignments (VAR[..]=value)
        if (seg ~ /^[A-Za-z_][A-Za-z0-9_]*\[[^]]*\][[:space:]]*\+?=[^[:space:]]*[[:space:]]*$/)
            continue
        # env-prefix chains: consume VAR=val pairs
        while (sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+/, "", seg)) {
            ;
        }
        sub(/^[[:space:]]+/, "", seg)
        if (seg == "" || seg ~ /^QQUOTED/) continue
        if (match(seg, /^[A-Za-z_][A-Za-z0-9_.\/-]*/))
            print substr(seg, 1, RLENGTH)
    }
}
AWK_EXTRACT
}

# ------------------------------------------------------------------
# Per-file scanning
# ------------------------------------------------------------------

scan_one() {
	f=$1
	fam=${VCFAMILY:-generic}

	# Read the first line: it is only a shebang when it starts
	# with "#!"; other first lines (comments such as
	# "# shellcheck shell=bash") are not shebangs.
	shebang=
	if IFS= read -r first_line <"$f" 2>/dev/null; then
		case "$first_line" in
		'#!'*) shebang=$first_line ;;
		esac
	fi

	lang=unknown
	case "$f" in
	*.bash) lang=bash ;;
	*.ksh) lang=ksh ;;
	*.sh) lang='sh' ;;
	*.pl | *.pm) lang=perl ;;
	*.bat) lang='batch' ;;
	esac

	if [ "$lang" = "unknown" ]; then
		case "$shebang" in
		'#!'*)
			case "$shebang" in
			*bash*) lang=bash ;;
			*ksh*) lang=ksh ;;
			*perl*) lang=perl ;;
			*python*) lang=python ;;
			*sh*) lang='sh' ;;
			esac
			;;
		esac
	fi

	if [ "$lang" = "unknown" ]; then
		# Config files, unit files, documentation: scan them
		# with the static rules when they are text, skip
		# binaries entirely.
		ftype=$(file -b "$f" 2>/dev/null || true)
		case "$ftype" in
		*script* | *text* | *ASCII* | *Unicode*) lang=data ;;
		*) return ;;
		esac
	fi

	# Static rule engine.
	awk -v fam="$fam" -v lang="$lang" \
		-f "$VCSCANAWK" "$f" >>"$FINDINGS"

	# Shebang checks.
	case "$lang" in
	bash)
		case "$fam" in
		openbsd)
			note ERROR 1 "$f" \
				"bash script inside the OpenBSD tree (OpenBSD scripts must be ksh)" \
				"OpenBSD ksh(1)" \
				"Rewrite as ksh (#!/bin/ksh)"
			;;
		esac
		case "$shebang" in
		'#!/bin/bash'* | '#!/usr/bin/env bash'*) : ;;
		'')
			if [ -x "$f" ]; then
				note ERROR 1 "$f" \
					"missing shebang in an executable .bash script (it cannot be executed directly)" \
					"execve(2); bash(1)" \
					"Add #!/bin/bash"
			else
				note INFO 1 "$f" \
					"no shebang in a non-executable .bash file (sourced helper)" \
					"bash(1)" \
					"Nothing to do if the file is only sourced"
			fi
			;;
		*)
			note ERROR 1 "$f" \
				"wrong shebang for a bash script: ${shebang}" \
				"execve(2); bash(1)" \
				"Use #!/bin/bash or #!/usr/bin/env bash"
			;;
		esac
		;;
	ksh)
		case "$shebang" in
		'#!/bin/ksh'* | '#!/usr/bin/env ksh'*) : ;;
		'')
			note ERROR 1 "$f" \
				"missing shebang in a .ksh script" \
				"execve(2); OpenBSD ksh(1)" \
				"Add #!/bin/ksh"
			;;
		*)
			note ERROR 1 "$f" \
				"wrong shebang for a ksh script: ${shebang}" \
				"execve(2); OpenBSD ksh(1)" \
				"Use #!/bin/ksh or #!/usr/bin/env ksh"
			;;
		esac
		;;
	esac

	if [ "$lang" != "batch" ] && [ "$lang" != "data" ] &&
		[ "$lang" != "unknown" ] && [ -x "$f" ] &&
		[ -z "$shebang" ]; then
		note WARNING 1 "$f" \
			"executable script without a shebang" \
			"execve(2)" \
			"Add an interpreter line (#!/bin/sh, ...)"
	fi

	if [ -n "$shebang" ] && [ "$lang" = "unknown" ]; then
		note UNVERIFIED 1 "$f" \
			"cannot verify interpreter: ${shebang}" \
			"execve(2)" \
			"Review manually or add to the known-interpreter list"
	fi

	# Probe external commands on scripts that target the host
	# system. Never probes scripts for other OSes: their commands
	# cannot be meaningfully checked from here.
	case "$lang" in
	sh | bash | ksh) : ;;
	*) return ;;
	esac
	[ "${VCPROBE:-0}" = "1" ] || return

	awk -f "$VCEXTAWK" "$f" 2>/dev/null | sort -u |
		while IFS= read -r c; do
			[ -n "$c" ] || continue
			case " $KEYWORDS " in
			*" $c "*) continue ;;
			esac
			# Functions defined in this very file are fine.
			if grep -Eq \
				"^[[:space:]]*${c}[[:space:]]*\([[:space:]]*\)" \
				"$f" 2>/dev/null; then
				continue
			fi
			if is_allowed "$fam" "$c"; then
				continue
			fi
			if command -v "$c" >/dev/null 2>&1; then
				continue
			fi
			note ERROR 1 "$f" \
				"command not found on this system and not in the ${fam} allowlist: $c" \
				"command -v(1); validator allowlist" \
				"Fix the typo, install the tool, or add it to the allowlist if it is target-specific"
		done
}

scan_files() {
	for f in "$@"; do
		scan_one "$f"
	done
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------

jesc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

report() {
	if [ ! -s "$FINDINGS" ]; then
		if [ "$FORMAT" = "json" ]; then
			printf '[]\n'
		else
			printf '%s\n' \
				"[INFO] No correctness findings for target: $TARGET"
		fi
		exit 0
	fi

	n_err=$(awk -F"$TAB" '$1 == "ERROR" {n++} END {print n + 0}' \
		"$FINDINGS")
	n_warn=$(awk -F"$TAB" '$1 == "WARNING" {n++} END {print n + 0}' \
		"$FINDINGS")
	n_info=$(awk -F"$TAB" '$1 == "INFO" {n++} END {print n + 0}' \
		"$FINDINGS")
	n_unv=$(awk -F"$TAB" '$1 == "UNVERIFIED" {n++} END {print n + 0}' \
		"$FINDINGS")

	if [ "$FORMAT" = "json" ]; then
		printf '%s\n' \
			"[INFO] Correctness audit ($TARGET):" \
			" $n_err error(s), $n_warn warning(s)," \
			" $n_info info(s), $n_unv unverified." >&2
	else
		printf '%s\n' \
			"[INFO] Correctness audit ($TARGET):" \
			" $n_err error(s), $n_warn warning(s)," \
			" $n_info info(s), $n_unv unverified."
	fi

	if [ "$FORMAT" = "json" ]; then
		printf '[\n'
		first=1
		sort -t"$TAB" -k2,2 -k3,3n "$FINDINGS" |
			while IFS="$TAB" read -r sev file ln msg ref fix; do
				[ "$sev" = "INFO" ] && [ "$VERBOSE" -eq 0 ] &&
					continue
				[ "$QUIET" -eq 1 ] && [ "$sev" != "ERROR" ] &&
					continue
				if [ "$first" -eq 1 ]; then
					first=0
				else
					printf ',\n'
				fi
				printf \
					'{"severity":"%s","file":"%s","line":%s,"message":"%s","reference":"%s","fix":"%s"}' \
					"$(jesc "$sev")" \
					"$(jesc "$file")" \
					"${ln:-0}" \
					"$(jesc "$msg")" \
					"$(jesc "$ref")" \
					"$(jesc "$fix")"
			done
		printf '\n]\n'
	else
		sort -t"$TAB" -k2,2 -k3,3n "$FINDINGS" |
			while IFS="$TAB" read -r sev file ln msg ref fix; do
				[ "$sev" = "INFO" ] && [ "$VERBOSE" -eq 0 ] &&
					continue
				[ "$QUIET" -eq 1 ] && [ "$sev" != "ERROR" ] &&
					continue
				printf '%s %s:%s\n  %s\n  Reference: %s\n  Suggested fix: %s\n' \
					"$sev" "$file" "${ln:-0}" \
					"$msg" "$ref" "$fix"
			done
	fi

	if [ "$n_err" -gt 0 ]; then
		exit 1
	fi
	if [ "$STRICT" -eq 1 ] &&
		[ "$((n_warn + n_unv))" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

main() {
	TARGET=host
	STRICT=0
	VERBOSE=0
	QUIET=0
	FORMAT=text
	ROOT_DIR=

	while [ $# -gt 0 ]; do
		case "$1" in
		--target)
			shift
			[ $# -gt 0 ] || usage
			TARGET=$1
			;;
		--strict) STRICT=1 ;;
		--verbose) VERBOSE=1 ;;
		--quiet) QUIET=1 ;;
		--format)
			shift
			[ $# -gt 0 ] || usage
			FORMAT=$1
			;;
		-h | --help) usage ;;
		--)
			shift
			break
			;;
		-*) usage ;;
		*) break ;;
		esac
		shift
	done

	ROOT_DIR=${1:-.}
	[ $# -le 1 ] || usage
	[ -d "$ROOT_DIR" ] || err "not a directory: $ROOT_DIR"

	case "$TARGET" in
	host | openbsd | debian | secureblue | all) ;;
	*) usage ;;
	esac
	case "$FORMAT" in
	text | json) ;;
	*) usage ;;
	esac

	require_cmd uname
	require_cmd find
	require_cmd awk
	require_cmd sort
	require_cmd sed
	require_cmd grep
	require_cmd tr
	require_cmd printf
	require_cmd file
	require_cmd mktemp

	detect_host
	if [ "$TARGET" = "host" ]; then
		if [ -n "$HOST_FAMILY" ]; then
			TARGET=$HOST_FAMILY
		else
			TARGET=all
		fi
	fi

	# The script re-executes itself as a worker from find(1), so
	# it must be reachable through an absolute path even after
	# changing directory to ROOT_DIR.
	SELF=$(command -v "$0" 2>/dev/null || printf '%s' "$0")
	case "$SELF" in
	/*) : ;;
	*) SELF=$(pwd)/$SELF ;;
	esac

	if ! cd "$ROOT_DIR" 2>/dev/null; then
		err "cannot change to directory: $ROOT_DIR"
	fi

	TMPD=$(mktemp -d "${TMPDIR:-/tmp}/vcorr-XXXXXX") || {
		printf '%s\n' "[ERROR] cannot create temporary directory" >&2
		exit 1
	}
	trap 'rm -rf "$TMPD"' EXIT HUP INT TERM
	FINDINGS="$TMPD/findings.txt"
	VCSCANAWK="$TMPD/scan.awk"
	VCEXTAWK="$TMPD/extract.awk"
	: >"$FINDINGS"
	write_awk_programs

	export FINDINGS VCSCANAWK VCEXTAWK

	scan_dir() {
		family=$1
		dir=$2
		probe=0
		[ "$family" = "$HOST_FAMILY" ] && probe=1
		[ -d "$dir" ] || return 0
		VCFAMILY=$family VCPROBE=$probe \
			find "$dir" \
			\( -name .git -type d \) -prune -o \
			-type f -exec "$SELF" --scan-file {} +
	}

	case "$TARGET" in
	openbsd) scan_dir openbsd "openbsd" ;;
	debian) scan_dir debian "debian" ;;
	secureblue)
		scan_dir secureblue "secureblue"
		scan_dir shell "shell"
		;;
	all)
		scan_dir openbsd "openbsd"
		scan_dir debian "debian"
		scan_dir secureblue "secureblue"
		scan_dir shell "shell"
		;;
	esac

	# Generic/portable checks, independent of the target.
	scan_dir generic "tests-format"
	scan_dir perl "perl"
	if [ -f Makefile ]; then
		VCFAMILY=generic VCPROBE=0 "$SELF" --scan-file Makefile
	fi

	report
}

case "${1:-}" in
--scan-file)
	shift
	scan_files "$@"
	exit 0
	;;
esac

main "$@"
