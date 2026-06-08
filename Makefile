# Simple installer for Debian, OpenBSD, secureblue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr/local
BINDIR ?= ${PREFIX}/bin
INFO ?= ==>
SECUREBLUE_USER ?= david
SECUREBLUE_BASHRCD_DIR ?= /var/home/${SECUREBLUE_USER}/.bashrc.d
SECUREBLUE_ALIASES_SRC = shell/aliases.bash
SECUREBLUE_ALIASES_DST = ${SECUREBLUE_BASHRCD_DIR}/aliases.bash

DEBIAN_SCRIPTS = \
	debian/add-gh-cli-repo.bash \
	debian/add-i2pd-repo.bash \
	debian/add-lynis-repo.bash \
	debian/add-tor-repo.bash \
	debian/clean-logs.bash \
	debian/enable-tor-transport.bash \
	debian/sync-website.bash \
	debian/sysupgrade.bash \
	debian/update-argon-one-v3.bash \
	debian/update-btop.bash \
	debian/update-fastfetch.bash \
	debian/update-golang.bash \
	debian/update-lyrebird.bash \
	debian/update-monero.bash \
	debian/update-msedit.bash \
	debian/update-xd-torrent.bash

OPENBSD_SCRIPTS = \
	openbsd/apply-sysclean.ksh \
	openbsd/clean-logs.ksh \
	openbsd/sudo-wrapper.ksh \
	openbsd/sync-website.ksh \
	openbsd/sysupgrade-current.ksh

SECUREBLUE_SCRIPTS = \
	secureblue/down-music.bash \
	secureblue/install-arti-service.bash \
	secureblue/postinstall.bash \
	secureblue/setup-clamav.bash \
	secureblue/sudo-wrapper.bash \
	secureblue/sync-gh-repos.bash \
	secureblue/sysupgrade.bash \
	secureblue/update-arti-oniux.bash \
	secureblue/update-krohnkite.bash \
	secureblue/update-lyrebird.bash \
	secureblue/update-xd-torrent.bash

TESTS_FORMAT_SCRIPTS = \
	tests-format/clang-format-all.sh \
	tests-format/clang-tidy-all.sh \
	tests-format/install-knfmt-linux.sh \
	tests-format/validate-make.sh \
	tests-format/validate-manpages.sh \
	tests-format/validate-perl.sh \
	tests-format/validate-shell.sh

PERL_SCRIPTS = \
	perl/ssh-menu.pl

.PHONY: all clean install-debian install-openbsd install-secureblue install-shell install-shell-secureblue install-shell-secureblue-unlock install-shell-secureblue-copy install-shell-secureblue-lock install-shell-openbsd install-perl install-tests-format test help

all: install-debian install-openbsd install-secureblue install-perl install-tests-format

clean:
	@echo "${INFO} Nothing to clean"

install-debian:
	@echo "${INFO} Installing Debian helpers"
	@install -d ${BINDIR}
	@for f in ${DEBIAN_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; install -m 0755 "$$f" "${BINDIR}/$$name"; done
	@echo "${INFO} Debian helpers installed"

install-openbsd:
	@echo "${INFO} Installing OpenBSD helpers"
	@install -d ${BINDIR}
	@for f in ${OPENBSD_SCRIPTS}; do base=$${f##*/}; name=$${base%.ksh}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; install -m 0755 "$$f" "${BINDIR}/$$name"; done
	@wrapper="${BINDIR}/sudo-wrapper"; if [ -x "$$wrapper" ]; then ln -sf "$$wrapper" "${BINDIR}/sudo"; for link in sudo visudo sudoedit; do printf '%s Symlinking %s -> %s\n' "${INFO}" "${BINDIR}/$$link" "$$wrapper"; ln -sf "$$wrapper" "${BINDIR}/$$link"; done; fi
	@printf '%s Installing openbsd/sysclean -> %s\n' "${INFO}" "${BINDIR}/sysclean"; rm -rf "${BINDIR}/sysclean"; cp -R openbsd/sysclean "${BINDIR}/sysclean"; chmod -R a+rX "${BINDIR}/sysclean"; echo "${INFO} OpenBSD helpers installed"

install-secureblue:
	@echo "${INFO} Installing SecureBlue helpers"
	@install -d ${BINDIR}
	@for f in ${SECUREBLUE_SCRIPTS}; do base=$${f##*/}; name=$${base%.bash}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; install -m 0755 "$$f" "${BINDIR}/$$name"; done
	@if [ -d secureblue/systemd ]; then printf '%s Installing %s -> %s\n' "${INFO}" "secureblue/systemd" "${BINDIR}/systemd"; rm -rf "${BINDIR}/systemd"; cp -R secureblue/systemd "${BINDIR}/systemd"; chmod -R a+rX "${BINDIR}/systemd"; fi
	@wrapper="${BINDIR}/sudo-wrapper"; if [ -x "$$wrapper" ]; then ln -sf "$$wrapper" "${BINDIR}/sudo"; for link in sudo visudo sudoedit; do printf '%s Symlinking %s -> %s\n' "${INFO}" "${BINDIR}/$$link" "$$wrapper"; ln -sf "$$wrapper" "${BINDIR}/$$link"; done; fi; echo "${INFO} SecureBlue helpers installed"

install-shell: install-shell-secureblue

install-shell-secureblue: install-shell-secureblue-unlock install-shell-secureblue-copy install-shell-secureblue-lock
	@echo "${INFO} Installing shell aliases for SecureBlue user '${SECUREBLUE_USER}'"
	@echo "${INFO} SecureBlue shell aliases installed"

install-shell-secureblue-unlock:
	@if ! command -v chattr >/dev/null 2>&1; then echo "${INFO} ERROR: chattr not found"; exit 1; fi
	@if [ -e "${SECUREBLUE_BASHRCD_DIR}" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${SECUREBLUE_BASHRCD_DIR}"; chattr -i "${SECUREBLUE_BASHRCD_DIR}" 2>/dev/null || true; fi
	@if [ -e "${SECUREBLUE_ALIASES_DST}" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${SECUREBLUE_ALIASES_DST}"; chattr -i "${SECUREBLUE_ALIASES_DST}" 2>/dev/null || true; fi
	@mkdir -p "${SECUREBLUE_BASHRCD_DIR}"

install-shell-secureblue-copy:
	@printf '%s Installing %s -> %s\n' "${INFO}" "${SECUREBLUE_ALIASES_SRC}" "${SECUREBLUE_ALIASES_DST}"; install -m 0644 "${SECUREBLUE_ALIASES_SRC}" "${SECUREBLUE_ALIASES_DST}"

install-shell-secureblue-lock:
	@printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${SECUREBLUE_ALIASES_DST}"; chattr +i "${SECUREBLUE_ALIASES_DST}"
	@printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${SECUREBLUE_BASHRCD_DIR}"; chattr +i "${SECUREBLUE_BASHRCD_DIR}"

install-shell-openbsd:
	@echo "${INFO} OpenBSD does not support chattr immutable flags like Linux."
	@echo "${INFO} Copy shell/aliases.bash manually to your preferred shell profile location."

install-perl:
	@echo "${INFO} Installing perl helpers"
	@install -d ${BINDIR}
	@for f in ${PERL_SCRIPTS}; do base=$${f##*/}; name=$${base%.pl}; printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; install -m 0755 "$$f" "${BINDIR}/$$name"; done
	@echo "${INFO} Perl helpers installed"

install-tests-format:
	@echo "${INFO} Installing Tests/Format scripts"
	@for f in ${TESTS_FORMAT_SCRIPTS}; do base=$${f##*/}; name=$${base%.sh}; printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; install -m 0755 "$$f" "${BINDIR}/$$name"; done
	@echo "${INFO} Tests/Format helpers installed"

test:
	@echo "Running shell script validation..." && /bin/bash tests-format/validate-shell.sh .
	@echo "Running perl script validation..." && /bin/bash tests-format/validate-perl.sh .
	@echo "Running make validation..." && /bin/bash tests-format/validate-make.sh .
	@echo "Running C/C++ formatter pass (knfmt/clang-format)..." && /bin/sh tests-format/clang-format-all.sh .
	@echo "Running clang-tidy pass (if available)..." && /bin/sh tests-format/clang-tidy-all.sh .

help:
	@printf "Usage: make [target]\n\nTargets:\n  all                      Install all helper sets\n  install-debian           Install Debian helper scripts into ${BINDIR}\n  install-openbsd          Install OpenBSD helper scripts into ${BINDIR}\n  install-secureblue       Install secureblue helper scripts into ${BINDIR}\n  install-shell            Alias of install-shell-secureblue\n  install-shell-secureblue Install shell aliases into ${SECUREBLUE_BASHRCD_DIR} (with chattr -i/+i)\n  install-shell-openbsd    Guidance for installing shell helpers on OpenBSD\n  install-perl             Install perl helper scripts into ${BINDIR}\n  install-tests-format     Install tests-format helper scripts into ${BINDIR}/tests-format\n  test                     Run script and make validation tests\n  clean                    No-op clean target\n  help                     Show this help\n"