# Simple installer for Debian, OpenBSD, secureblue, shell helpers, and Perl scripts
# Uses only POSIX sh in recipes; compatible with BSD make.

PREFIX?=/usr/local
BINDIR?=${PREFIX}/bin

DEBIAN_SCRIPTS=\
	debian/add-i2pd-repo.bash \
	debian/add-tor-repo.bash \
	debian/apt-full-upgrade.bash \
	debian/clean-logs.bash \
	debian/sync-website.bash \
	debian/update-argon-one-v3.bash \
	debian/update-fastfetch.bash \
	debian/update-golang.bash \
	debian/update-monero.bash

OPENBSD_SCRIPTS=\
	openbsd/apply-sysclean.ksh \
	openbsd/clean-logs.ksh \
	openbsd/sudo-wrapper.ksh \
	openbsd/sync-website.ksh

SECUREBLUE_SCRIPTS=\
	secureblue/luks-ext4-to-btrfs.bash \
	secureblue/sudo-wrapper.bash \
	secureblue/sysupgrade.bash

SHELL_SCRIPTS=\
	shell/global-vi-mode.sh

PERL_SCRIPTS=\
	perl/ssh-menu.pl

.PHONY: install-debian install-openbsd install-secureblue install-shell install-perl

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

install-secureblue:
	@install -d ${BINDIR}
	@for f in ${SECUREBLUE_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.bash}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done

install-shell:
	@# Install global-vi-mode into /etc/profile.d
	@run0 install -d /etc/profile.d
	@run0 install -m 0644 shell/global-vi-mode.sh /etc/profile.d/global-vi-mode.sh

install-perl:
	@install -d ${BINDIR}
	@for f in ${PERL_SCRIPTS}; do \
		base=$${f##*/}; name=$${base%.pl}; \
		printf 'Installing %s -> %s\n' "$$f" "${BINDIR}/$$name"; \
		install -m 0755 "$$f" "${BINDIR}/$$name"; \
	done
