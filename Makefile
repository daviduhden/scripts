# Simple installer for Debian, OpenBSD, SecureBlue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= ${PREFIX}/bin
DESTBIN = ${DESTDIR}${BINDIR}
SYSTEMD_USER_UNIT_DIR ?= ${PREFIX}/lib/systemd/user
DEST_SYSTEMD_USER = ${DESTDIR}${SYSTEMD_USER_UNIT_DIR}
TESTS_FORMAT_DIR ?= ${PREFIX}/libexec/scripts
DEST_TESTS_FORMAT = ${DESTDIR}${TESTS_FORMAT_DIR}
TESTS_FORMAT_LINKS ?= 0
INFO ?= ==>
SECUREBLUE_USER ?= david
BASH_CONF_DST_DIR ?= /var/home/${SECUREBLUE_USER}/.bashrc.d
BASH_CONF_FILES = shell/aliases.bash \
	shell/vi-mode.bash

DEBIAN_SCRIPTS = \
	debian/add-gh-cli-repo.bash \
	debian/add-i2pd-repo.bash \
	debian/add-lynis-repo.bash \
	debian/add-tor-repo.bash \
	debian/clean-logs.bash \
	debian/enable-tor-transport.bash \
	debian/install-hardened-malloc.bash \
	debian/sync-website.bash \
	debian/sysupgrade.bash \
	debian/update-argon-one-v3.bash \
	debian/update-btop.bash \
	debian/update-fastfetch.bash \
	debian/update-golang.bash \
	debian/update-lyrebird.bash \
	debian/update-monero.bash \
	debian/update-msedit.bash \
	debian/update-openrsync.bash \
	debian/update-signify.bash \
	debian/update-xd-torrent.bash \
	debian/ai-purge-history.bash \
	debian/rpi-update-safe.bash \
	debian/bootargs.pl \
	scripts/release-verify.pl

OPENBSD_SCRIPTS = \
	openbsd/clean-logs.ksh \
	openbsd/sudo-wrapper.ksh \
	openbsd/sync-website.ksh \
	openbsd/sysupgrade-current.ksh \
	openbsd/update-crush.ksh \
	openbsd/ai-purge-history.ksh \
	openbsd/rename-link.pl

SECUREBLUE_SCRIPTS = \
	secureblue/arti-config.py \
	secureblue/down-music.bash \
	secureblue/install-arti-service.bash \
	secureblue/install-openrsync.bash \
	secureblue/install-signify.bash \
	secureblue/postinstall.bash \
	secureblue/setup-clamav.bash \
	secureblue/sudo-wrapper.bash \
	secureblue/sync-gh-repos.bash \
	secureblue/sysupgrade.bash \
	secureblue/update-arti-oniux.bash \
	secureblue/update-krohnkite.bash \
	secureblue/update-lyrebird.bash \
	secureblue/update-perl-modules.bash \
	secureblue/update-xd-torrent.bash \
	secureblue/update-xerj.bash \
	secureblue/ai-purge-history.bash \
	secureblue/xerj-config.pl \
	scripts/release-verify.pl

TESTS_FORMAT_SCRIPTS = \
	tests-format/clang-format-all.sh \
	tests-format/clang-tidy-all.sh \
	tests-format/fourmolu-all.sh \
	tests-format/fix-permissions.sh \
	tests-format/install-knfmt-linux.sh \
	tests-format/validate-correctness.sh \
	scripts/validate-agent-knowledge.py \
	tests-format/validate-make.sh \
	tests-format/validate-manpages.sh \
	tests-format/validate-perl.sh \
	tests-format/validate-python.sh \
	tests-format/validate-shell.sh

# Public Perl programs are listed in perl/programs.txt.
PERL_PROGRAMS_MANIFEST = perl/programs.txt

.PHONY: all clean install-debian install-openbsd install-secureblue install-shell install-shell-bash install-shell-bash-unlock install-shell-bash-copy install-shell-openbsd install-perl install-tests-format uninstall-debian uninstall-openbsd uninstall-secureblue uninstall-shell uninstall-perl uninstall-tests-format test test-validate test-python check format test-tooling test-delivery test-manpages test-regression test-agent-knowledge fix-permissions check-permissions check-agent-knowledge help

# OS-specific sets install the same command names, so they cannot share a
# single BINDIR. 'all' installs only the OS-independent runtime helper; choose
# install-debian, install-openbsd or install-secureblue for the target host.
# Developer validators and formatters are an explicit install-tests-format.
all: install-perl

clean:
	@echo "${INFO} Nothing to clean"

install-debian:
	@echo "${INFO} Installing Debian helpers"
	@set -e; install -d "${DESTBIN}"
	@set -e; for f in ${DEBIAN_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; name=$${name%.pl}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${DESTBIN}/$$name"; install -m 0755 "$$f" "${DESTBIN}/$$name"; done
	@echo "${INFO} Debian helpers installed"

install-openbsd:
	@echo "${INFO} Installing OpenBSD helpers"
	@set -e; install -d "${DESTBIN}"
	@set -e; for f in ${OPENBSD_SCRIPTS}; do base=$${f##*/}; name=$${base%.ksh}; name=$${name%.pl}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${DESTBIN}/$$name"; install -m 0755 "$$f" "${DESTBIN}/$$name"; done
	@set -e; wrapper="${DESTBIN}/sudo-wrapper"; if [ -x "$$wrapper" ]; then for link in sudo visudo sudoedit; do if [ -e "${DESTBIN}/$$link" ] && [ ! -L "${DESTBIN}/$$link" ]; then printf '%s ERROR: %s exists and is not a wrapper symlink; refusing to overwrite\n' "${INFO}" "${DESTBIN}/$$link" >&2; exit 1; fi; printf '%s Symlinking %s -> %s\n' "${INFO}" "${DESTBIN}/$$link" "$$wrapper"; ln -sf "$$wrapper" "${DESTBIN}/$$link"; done; fi
	@echo "${INFO} OpenBSD helpers installed"

install-secureblue:
	@echo "${INFO} Installing SecureBlue helpers"
	@set -e; install -d "${DESTBIN}"
	@set -e; for f in ${SECUREBLUE_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; name=$${name%.pl}; name=$${name%.py}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${DESTBIN}/$$name"; install -m 0755 "$$f" "${DESTBIN}/$$name"; done
	@set -e; if [ -d secureblue/systemd ]; then install -d -m 0755 "${DEST_SYSTEMD_USER}" || exit 1; for f in secureblue/systemd/*.service; do [ -f "$$f" ] || continue; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${DEST_SYSTEMD_USER}/$${f##*/}"; install -m 0644 "$$f" "${DEST_SYSTEMD_USER}/$${f##*/}" || exit 1; done; fi
	@set -e; wrapper="${DESTBIN}/sudo-wrapper"; if [ -x "$$wrapper" ]; then for link in sudo visudo sudoedit; do if [ -e "${DESTBIN}/$$link" ] && [ ! -L "${DESTBIN}/$$link" ]; then printf '%s ERROR: %s exists and is not a wrapper symlink; refusing to overwrite\n' "${INFO}" "${DESTBIN}/$$link" >&2; exit 1; fi; printf '%s Symlinking %s -> %s\n' "${INFO}" "${DESTBIN}/$$link" "$$wrapper"; ln -sf "$$wrapper" "${DESTBIN}/$$link"; done; fi; echo "${INFO} SecureBlue helpers installed"

install-shell: install-shell-bash
	@echo "${INFO} Shell helpers installed"

install-shell-bash: install-shell-bash-copy
	@echo "${INFO} Installing shell aliases for SecureBlue user '${SECUREBLUE_USER}'"
	@echo "${INFO} SecureBlue shell aliases installed"

install-shell-bash-unlock:
	@set -e; if ! command -v chattr >/dev/null 2>&1; then echo "${INFO} ERROR: chattr not found"; exit 1; fi
	@set -e; if [ -e "${BASH_CONF_DST_DIR}" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${BASH_CONF_DST_DIR}"; chattr -i "${BASH_CONF_DST_DIR}" 2>/dev/null || true; fi
	@set -e; mkdir -p "${BASH_CONF_DST_DIR}"

install-shell-bash-copy: install-shell-bash-unlock
	@set -e; trap 'status=$$?; trap - 0; printf "%s Restoring immutable attribute on %s\n" "${INFO}" "${BASH_CONF_DST_DIR}"; chattr +i "${BASH_CONF_DST_DIR}" || status=1; exit "$$status"' 0; for f in ${BASH_CONF_FILES}; do printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BASH_CONF_DST_DIR}/$${f##*/}"; install -m 0644 "$$f" "${BASH_CONF_DST_DIR}/$${f##*/}"; done

install-shell-openbsd:
	@echo "${INFO} OpenBSD does not support chattr immutable flags like Linux."
	@echo "${INFO} Copy shell/aliases.bash manually to your preferred shell profile location."

install-perl:
	@echo "${INFO} Installing perl helpers"
	@set -e; install -d "${DESTBIN}"
	@set -e; programs=$$(grep -Ev '^[[:space:]]*(#|$$)' "${PERL_PROGRAMS_MANIFEST}") || exit 1; for name in $$programs; do src="perl/$$name"; base=$${src##*/}; out=$${base%.pl}; printf '%s Installing %s -> %s\n' "${INFO}" "$$src" "${DESTBIN}/$$out"; install -m 0755 "$$src" "${DESTBIN}/$$out"; install -m 0644 VERSION "${DESTBIN}/$$out.version"; done
	@echo "${INFO} Perl helpers installed"

install-tests-format:
	@set -e; echo "${INFO} Installing Tests/Format scripts" && install -d "${DEST_TESTS_FORMAT}"
	@set -e; for cfg in "tests-format/clang-format.yaml:clang-format-all" "tests-format/clang-tidy.yaml:clang-tidy-all" "tests-format/fourmolu-all.yaml:fourmolu-all"; do src=$${cfg%%:*}; dst=$${cfg##*:}; install -m 0644 "$$src" "${DEST_TESTS_FORMAT}/$$dst"; done
	@set -e; for f in ${TESTS_FORMAT_SCRIPTS}; do base=$${f##*/}; name=$${base%.sh}; name=$${name%.py}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${DEST_TESTS_FORMAT}/$$name"; install -m 0755 "$$f" "${DEST_TESTS_FORMAT}/$$name"; if [ "${TESTS_FORMAT_LINKS}" = "1" ]; then install -d "${DESTBIN}"; ln -sf "${DEST_TESTS_FORMAT}/$$name" "${DESTBIN}/$$name"; fi; done
	@echo "${INFO} Tests/Format helpers installed in ${DEST_TESTS_FORMAT}"

uninstall-debian:
	@set -e; for f in ${DEBIAN_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; name=$${name%.pl}; rm -f -- "${DESTBIN}/$$name"; done
	@echo "${INFO} Debian helpers removed from ${DESTBIN}"

uninstall-openbsd:
	@set -e; for f in ${OPENBSD_SCRIPTS}; do base=$${f##*/}; name=$${base%.ksh}; name=$${name%.pl}; rm -f -- "${DESTBIN}/$$name"; done
	@set -e; for link in sudo visudo sudoedit; do if [ -L "${DESTBIN}/$$link" ]; then rm -f -- "${DESTBIN}/$$link"; fi; done
	@echo "${INFO} OpenBSD helpers removed from ${DESTBIN}"

uninstall-secureblue:
	@set -e; for f in ${SECUREBLUE_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; name=$${name%.pl}; name=$${name%.py}; rm -f -- "${DESTBIN}/$$name"; done
	@set -e; for f in secureblue/systemd/*.service; do [ -f "$$f" ] || continue; rm -f -- "${DEST_SYSTEMD_USER}/$${f##*/}"; done
	@set -e; for link in sudo visudo sudoedit; do if [ -L "${DESTBIN}/$$link" ]; then rm -f -- "${DESTBIN}/$$link"; fi; done
	@echo "${INFO} SecureBlue helpers and units removed"

uninstall-perl:
	@set -e; programs=$$(grep -Ev '^[[:space:]]*(#|$$)' "${PERL_PROGRAMS_MANIFEST}") || exit 1; for name in $$programs; do base=$${name##*/}; out=$${base%.pl}; rm -f -- "${DESTBIN}/$$out" "${DESTBIN}/$$out.version"; done
	@echo "${INFO} Perl helpers removed from ${DESTBIN}"

uninstall-tests-format:
	@set -e; for f in ${TESTS_FORMAT_SCRIPTS}; do base=$${f##*/}; name=$${base%.sh}; name=$${name%.py}; rm -f -- "${DEST_TESTS_FORMAT}/$$name"; if [ "${TESTS_FORMAT_LINKS}" = "1" ]; then rm -f -- "${DESTBIN}/$$name"; fi; done
	@set -e; for cfg in clang-format-all clang-tidy-all fourmolu-all; do rm -f -- "${DEST_TESTS_FORMAT}/$$cfg"; done
	@echo "${INFO} Tests/Format helpers removed"

uninstall-shell:
	@set -e; if [ -e "${BASH_CONF_DST_DIR}" ]; then chattr -i "${BASH_CONF_DST_DIR}" 2>/dev/null || true; fi; for f in ${BASH_CONF_FILES}; do rm -f -- "${BASH_CONF_DST_DIR}/$${f##*/}"; done; if [ -d "${BASH_CONF_DST_DIR}" ]; then chattr +i "${BASH_CONF_DST_DIR}" 2>/dev/null || true; fi
	@echo "${INFO} Shell helpers removed"

test: test-validate
	@${MAKE} test-manpages
	@${MAKE} test-regression
	@echo "All configured tests completed; review skipped checks in logs."

check: test-validate test-manpages

format:
	@status=0; for validator in python shell perl make; do /bin/sh "tests-format/validate-$$validator.sh" --format . || status=1; done; exit "$$status"

test-validate: check-agent-knowledge test-agent-knowledge test-python
	@echo "Running shell script validation..." && /bin/sh tests-format/validate-shell.sh --check .
	@echo "Running perl script validation..." && /bin/sh tests-format/validate-perl.sh --check .
	@echo "Running make validation..." && /bin/sh tests-format/validate-make.sh --check .
	@echo "Checking file permissions (read-only)..." && /bin/sh tests-format/fix-permissions.sh --check .
	@echo "Running correctness audit..." && /bin/sh tests-format/validate-correctness.sh --target all .

test-python:
	@echo "Running python script validation..." && /bin/sh tests-format/validate-python.sh --check .

test-manpages:
	@echo "Running man page validation..." && /bin/sh tests-format/validate-manpages.sh .

test-regression: test-tooling test-delivery
	@echo "Running fix-permissions regression tests..." && /bin/sh tests-format/test-fix-permissions.sh
	@echo "Running correctness regression tests..." && /bin/sh tests-format/test-validate-correctness.sh
	@echo "Running ssh-menu regression test..." && perl tests-format/test-ssh-menu.pl
	@echo "Running normalize-files regression test..." && perl tests-format/test-normalize-files.pl
	@echo "Running website sync filter tests..." && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_sync_website_filters.py'

test-delivery:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_delivery_transactions.py' -v
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_release_updates.py' -v

test-tooling:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_tooling.py' -v

fix-permissions:
	@/bin/sh tests-format/fix-permissions.sh .

check-permissions:
	@/bin/sh tests-format/fix-permissions.sh --check .

check-agent-knowledge:
	@python3 scripts/validate-agent-knowledge.py --scope worktree

test-agent-knowledge:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/agent_knowledge_validator -v

help:
	@printf "Usage: make [target]\n\nTargets:\n  all                      Install the OS-independent runtime helper (Perl only)\n  install-debian           Install Debian helper scripts into ${DESTBIN}\n  install-openbsd          Install OpenBSD helper scripts into ${DESTBIN}\n  install-secureblue       Install SecureBlue helpers into ${DESTBIN} and units into ${DEST_SYSTEMD_USER}\n  install-shell            Install SecureBlue Bash shell helpers\n  install-shell-bash       Install shell aliases into ${BASH_CONF_DST_DIR} (with chattr -i/+i)\n  install-shell-openbsd    Guidance for installing shell helpers on OpenBSD\n  install-perl             Install perl helper scripts into ${DESTBIN}\n  install-tests-format     Install developer validators/formatters into ${DEST_TESTS_FORMAT}\n  uninstall-debian         Remove Debian helpers from ${DESTBIN}\n  uninstall-openbsd        Remove OpenBSD helpers and wrapper links\n  uninstall-secureblue     Remove SecureBlue helpers and user units\n  uninstall-perl           Remove Perl helpers\n  uninstall-tests-format   Remove developer validators/formatters\n  uninstall-shell          Remove installed shell helpers\n  check                    Run validation without formatting or caches\n  format                   Apply formatters (reports drift as failure)\n  test                     Run checks and isolated regression tests\n  test-validate            Run only read-only validators\n  test-manpages            Run mandoc lint when mandoc is installed\n  test-regression          Run only the regression tests\n  test-tooling             Run validator/installer temporary-tree regressions\n  test-delivery            Run delivery/release transaction regressions\n  test-agent-knowledge     Run the agent-knowledge validator contract tests\n  fix-permissions          Correct file modes from file(1) content\n  check-permissions        Report wrong file modes (read-only, rc != 0)\n  check-agent-knowledge    Enforce agent/skills synchronization for repository changes\n  clean                    No-op clean target\n  help                     Show this help\n\nVariables: PREFIX=${PREFIX} DESTDIR=${DESTDIR} BINDIR=${BINDIR} SYSTEMD_USER_UNIT_DIR=${SYSTEMD_USER_UNIT_DIR} TESTS_FORMAT_DIR=${TESTS_FORMAT_DIR} TESTS_FORMAT_LINKS=${TESTS_FORMAT_LINKS}\n"
