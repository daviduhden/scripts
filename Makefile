# Simple installer for Debian, OpenBSD, secureblue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX?=/usr/local
BINDIR?=${PREFIX}/bin

DEBIAN_SCRIPTS=\
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
	debian/update-monero.bash

OPENBSD_SCRIPTS=\
	openbsd/apply-sysclean.ksh \
	openbsd/clean-logs.ksh \
	openbsd/sudo-wrapper.ksh \
	openbsd/sync-website.ksh \
	openbsd/sysupgrade-current.ksh

SECUREBLUE_SCRIPTS=\
	secureblue/install-arti-service.bash \
	secureblue/luks-ext4-to-btrfs.bash \
	secureblue/postinstall.bash \
	secureblue/setup-clamav.bash \
	secureblue/sudo-wrapper.bash \
	secureblue/sync-gh-repos.bash \
	secureblue/sysupgrade.bash \
	secureblue/update-arti-oniux.bash

SHELL_SCRIPTS=\
	shell/global-vi-mode.sh

PERL_SCRIPTS=\
	perl/ssh-menu.pl

.PHONY: install-debian install-openbsd install-secureblue install-shell install-shell-openbsd install-perl

install-debian:
	@install -d ${BINDIR}
	@for f in ${DEBIAN_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.bash}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done

install-openbsd:
	@install -d ${BINDIR}
	@for f in ${OPENBSD_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.ksh}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@wrapper="${BINDIR}/sudo-wrapper"; \
	if [ -x "$$wrapper" ]; then \
		ln -sf "$$wrapper" "${BINDIR}/sudo"; \
		for link in sudo visudo sudoedit; do \
			printf 'Symlinking %s -> %s\n' "${BINDIR}/$$link" "$$wrapper"; \
			ln -sf "$$wrapper" "${BINDIR}/$$link"; \
		done; \
	fi
	@printf 'Installing openbsd/sysclean -> %s\n' "${BINDIR}/sysclean"; \
	rm -rf "${BINDIR}/sysclean"; \
	cp -R openbsd/sysclean "${BINDIR}/sysclean"; \
	chmod -R a+rX "${BINDIR}/sysclean"

install-secureblue:
	@install -d ${BINDIR}
	@for f in ${SECUREBLUE_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.bash}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
	@wrapper="${BINDIR}/sudo-wrapper"; \
	if [ -x "$$wrapper" ]; then \
		ln -sf "$$wrapper" "${BINDIR}/sudo"; \
		for link in sudo visudo sudoedit; do \
			printf 'Symlinking %s -> %s\n' "${BINDIR}/$$link" "$$wrapper"; \
			ln -sf "$$wrapper" "${BINDIR}/$$link"; \
		done; \
	fi

install-shell:
	@# Install global-vi-mode into /etc/profile.d
	@run0 install -d /etc/profile.d
	@run0 install -m 0644 shell/global-vi-mode.sh /etc/profile.d/global-vi-mode.sh

# OpenBSD does not ship /etc/profile.d; provide guidance instead of editing /etc/profile automatically.
install-shell-openbsd:
	@echo "OpenBSD does not provide /etc/profile.d; to install global-vi-mode.sh do:" ; \
	 echo "  install -d /etc/shinit.d" ; \
	 echo "  install -m 0644 shell/global-vi-mode.sh /etc/shinit.d/global-vi-mode.sh" ; \
	 echo "Then source it from /etc/shinit (and optionally /etc/profile) with:" ; \
	 echo "  . /etc/shinit.d/global-vi-mode.sh"

install-perl:
	@install -d ${BINDIR}
	@for f in ${PERL_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.pl}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
