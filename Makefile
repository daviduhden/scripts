# Simple installer for Debian, OpenBSD, secureblue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr/local
BINDIR ?= ${PREFIX}/bin
INFO ?= ==>

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
	debian/update-lyrebird.bash \
	debian/update-golang.bash \
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
	secureblue/install-arti-service.bash \
	secureblue/luks-ext4-to-btrfs.bash \
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
	tests-format/validate-manpages.sh \
	tests-format/validate-make.sh \
	tests-format/validate-perl.sh \
	tests-format/validate-shell.sh

SHELL_SCRIPTS = \
	shell/global-vi-mode.sh

PERL_SCRIPTS = \
	perl/ssh-menu.pl

.PHONY: install-debian install-openbsd install-secureblue install-shell install-shell-openbsd install-perl install-tests-format test help

install-debian:
	@echo "${INFO} Installing Debian helpers"
	@install -d ${BINDIR}
	@for f in ${DEBIAN_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.bash}; \
		printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@echo "${INFO} Debian helpers installed"

install-openbsd:
	@echo "${INFO} Installing OpenBSD helpers"
	@install -d ${BINDIR}
	@for f in ${OPENBSD_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.ksh}; \
		printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@wrapper="${BINDIR}/sudo-wrapper"; \
	if [ -x "$$wrapper" ]; then \
		ln -sf "$$wrapper" "${BINDIR}/sudo"; \
		for link in sudo visudo sudoedit; do \
			printf '%s Symlinking %s -> %s\n' "${INFO}" "${BINDIR}/$$link" "$$wrapper"; \
			ln -sf "$$wrapper" "${BINDIR}/$$link"; \
		done; \
	fi
	@printf '%s Installing openbsd/sysclean -> %s\n' "${INFO}" "${BINDIR}/sysclean"; \
	rm -rf "${BINDIR}/sysclean"; \
	cp -R openbsd/sysclean "${BINDIR}/sysclean"; \
	chmod -R a+rX "${BINDIR}/sysclean"
	@echo "${INFO} OpenBSD helpers installed"

install-secureblue:
	@echo "${INFO} Installing SecureBlue helpers"
	@install -d ${BINDIR}
	@for f in ${SECUREBLUE_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.bash}; \
		printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@# Copy systemd unit templates for secureblue helpers alongside the installed scripts
	@if [ -d secureblue/systemd ]; then \
		printf '%s Installing %s -> %s\n' "${INFO}" "secureblue/systemd" "${BINDIR}/systemd"; \
		rm -rf "${BINDIR}/systemd"; \
		cp -R secureblue/systemd "${BINDIR}/systemd"; \
		chmod -R a+rX "${BINDIR}/systemd"; \
	fi
	@wrapper="${BINDIR}/sudo-wrapper"; \
	if [ -x "$$wrapper" ]; then \
		ln -sf "$$wrapper" "${BINDIR}/sudo"; \
		for link in sudo visudo sudoedit; do \
			printf '%s Symlinking %s -> %s\n' "${INFO}" "${BINDIR}/$$link" "$$wrapper"; \
			ln -sf "$$wrapper" "${BINDIR}/$$link"; \
		done; \
	fi
	@echo "${INFO} SecureBlue helpers installed"

install-shell:
	@echo "${INFO} Installing shell helpers"
	@# Install global-vi-mode into /etc/profile.d
	@printf '%s Installing %s -> %s\n' "${INFO}" "shell/global-vi-mode.sh" "/etc/profile.d/global-vi-mode.sh"
	@install -d /etc/profile.d
	@install -m 0644 shell/global-vi-mode.sh /etc/profile.d/global-vi-mode.sh
	@echo "${INFO} Shell helpers installed"

# OpenBSD does not ship /etc/profile.d; provide guidance instead of editing /etc/profile automatically.
install-shell-openbsd:
	@echo "OpenBSD does not provide /etc/profile.d; to install global-vi-mode.sh do:" ; \
	 echo "  install -d /etc/shinit.d" ; \
	 echo "  install -m 0644 shell/global-vi-mode.sh /etc/shinit.d/global-vi-mode.sh" ; \
	 echo "Then source it from /etc/shinit (and optionally /etc/profile) with:" ; \
	 echo "  . /etc/shinit.d/global-vi-mode.sh"

install-perl:
	@echo "${INFO} Installing perl helpers"
	@install -d ${BINDIR}
	@for f in ${PERL_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.pl}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@echo "${INFO} Perl helpers installed"

install-tests-format:
	@echo "${INFO} Installing Tests/Format scripts"
	@for f in ${TESTS_FORMAT_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.sh}; \
		printf '%s Installing %s -> %s\n' "${INFO}" "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@echo "${INFO} Tests/Format helpers installed"

test:
	@echo "Running shell script validation..."
	@/bin/bash tests-format/validate-shell.sh .
	@echo "Running perl script validation..."
	@/bin/bash tests-format/validate-perl.sh .
	@echo "Running make validation..."
	@/bin/bash tests-format/validate-make.sh .
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install-debian        Install Debian helper scripts into $(BINDIR)"
	@echo "  install-openbsd       Install OpenBSD helper scripts into $(BINDIR)"
	@echo "  install-secureblue    Install secureblue helper scripts into $(BINDIR)"
	@echo "  install-shell         Install shell helpers (global-vi-mode)"
	@echo "  install-shell-openbsd Guidance for installing shell helpers on OpenBSD"
	@echo "  install-perl          Install perl helper scripts into $(BINDIR)"
	@echo "  test                  Run script and make validation tests"
	@echo "  install-tests-format  Install tests-format helper scripts into $(BINDIR)/tests-format"
	@echo "  help                  Show this help"