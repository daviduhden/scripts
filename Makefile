# Simple installer for Debian, OpenBSD, secureblue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr/local
BINDIR ?= ${PREFIX}/bin
INFO ?= ==>
SECUREBLUE_USER ?= david
BASH_CONF_DST_DIR ?= /var/home/${SECUREBLUE_USER}/.bashrc.d
BASH_CONF_FILES = shell/aliases.bash \
	shell/vi-mode.bash
FISH_CONF_SRC_DIR = shell/fish/conf.d
FISH_CONF_DST_DIR ?= /var/home/${SECUREBLUE_USER}/.config/fish/conf.d
FISH_CONF_FILES = \
	00-modern-cli.fish \
	00-path.fish \
	03-prompt.fish \
	05-colors.fish \
	10-env.fish \
	15-vi-mode.fish \
	20-abbr.fish \
	25-verbose.fish \
	30-functions.fish

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
	debian/update-signify.bash \
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
	secureblue/install-signify.bash \
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

.PHONY: all clean install-debian install-openbsd install-secureblue install-shell install-shell-bash install-shell-bash-unlock install-shell-bash-copy install-shell-bash-lock install-shell-openbsd install-perl install-tests-format test help

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

install-shell: install-shell-bash install-shell-fish
	@echo "${INFO} Shell helpers installed"

install-shell-bash: install-shell-bash-unlock install-shell-bash-copy install-shell-bash-lock
	@echo "${INFO} Installing shell aliases for SecureBlue user '${SECUREBLUE_USER}'"
	@echo "${INFO} SecureBlue shell aliases installed"

install-shell-bash-unlock:
	@if ! command -v chattr >/dev/null 2>&1; then echo "${INFO} ERROR: chattr not found"; exit 1; fi
	@if [ -e "${BASH_CONF_DST_DIR}" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${BASH_CONF_DST_DIR}"; chattr -i "${BASH_CONF_DST_DIR}" 2>/dev/null || true; fi
	@mkdir -p "${BASH_CONF_DST_DIR}"

install-shell-bash-copy:
	@for f in ${BASH_CONF_FILES}; do printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BASH_CONF_DST_DIR}/$${f##*/}"; install -m 0644 "$$f" "${BASH_CONF_DST_DIR}/$${f##*/}"; done

install-shell-bash-lock:
	@printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${BASH_CONF_DST_DIR}"; chattr +i "${BASH_CONF_DST_DIR}"
	@printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${BASH_CONF_DST_DIR}"; chattr +i "${BASH_CONF_DST_DIR}"

install-shell-fish: install-shell-fish-unlock install-shell-fish-copy install-shell-fish-lock
	@echo "${INFO} Installing fish config"
	@echo "${INFO} Fish shell config installed"

install-shell-fish-unlock:
	@if ! command -v chattr >/dev/null 2>&1; then echo "${INFO} ERROR: chattr not found"; exit 1; fi
	@if [ -e "${FISH_CONF_DST_DIR}" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${FISH_CONF_DST_DIR}"; chattr -i "${FISH_CONF_DST_DIR}" 2>/dev/null || true; fi
	@for f in ${FISH_CONF_FILES}; do if [ -e "${FISH_CONF_DST_DIR}/$$f" ]; then printf '%s Removing immutable attribute from %s\n' "${INFO}" "${FISH_CONF_DST_DIR}/$$f"; chattr -i "${FISH_CONF_DST_DIR}/$$f" 2>/dev/null || true; fi; done
	@install -d "${FISH_CONF_DST_DIR}"

install-shell-fish-copy:
	@install -d "${FISH_CONF_DST_DIR}"
	@for f in ${FISH_CONF_FILES}; do printf '%s Installing %s -> %s\n' "${INFO}" "${FISH_CONF_SRC_DIR}/$$f" "${FISH_CONF_DST_DIR}/$$f"; install -m 0644 "${FISH_CONF_SRC_DIR}/$$f" "${FISH_CONF_DST_DIR}/$$f"; done

install-shell-fish-lock:
	@for f in ${FISH_CONF_FILES}; do if [ -e "${FISH_CONF_DST_DIR}/$$f" ]; then printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${FISH_CONF_DST_DIR}/$$f"; chattr +i "${FISH_CONF_DST_DIR}/$$f"; fi; done
	@printf '%s Restoring immutable attribute on %s\n' "${INFO}" "${FISH_CONF_DST_DIR}"; chattr +i "${FISH_CONF_DST_DIR}"

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
	@echo "Running shell script validation..." && /bin/sh tests-format/validate-shell.sh .
	@echo "Running perl script validation..." && /bin/sh tests-format/validate-perl.sh .
	@echo "Running make validation..." && /bin/sh tests-format/validate-make.sh .

help:
	@printf "Usage: make [target]\n\nTargets:\n  all                      Install all helper sets\n  install-debian           Install Debian helper scripts into ${BINDIR}\n  install-openbsd          Install OpenBSD helper scripts into ${BINDIR}\n  install-secureblue       Install secureblue helper scripts into ${BINDIR}\n  install-shell            Alias of install-shell-secureblue\n  install-shell-fish       Install fish shell config into ${FISH_CONF_DST_DIR}\n  install-shell-secureblue Install shell aliases into ${SECUREBLUE_BASHRCD_DIR} (with chattr -i/+i)\n  install-shell-openbsd    Guidance for installing shell helpers on OpenBSD\n  install-perl             Install perl helper scripts into ${BINDIR}\n  install-tests-format     Install tests-format helper scripts into ${BINDIR}/tests-format\n  test                     Run script and make validation tests\n  clean                    No-op clean target\n  help                     Show this help\n"