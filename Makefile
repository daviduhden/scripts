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
MANAGE = /bin/sh scripts/manage-install.sh
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
	secureblue/arti-config.pl \
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
	scripts/validate-agent-knowledge.pl \
	tests-format/validate-make.sh \
	tests-format/validate-manpages.sh \
	tests-format/validate-perl.sh \
	tests-format/validate-shell.sh

# Public Perl programs are listed in perl/programs.txt.
PERL_PROGRAMS_MANIFEST = perl/programs.txt

.PHONY: all clean install-debian install-openbsd install-secureblue install-shell install-shell-bash install-shell-bash-unlock install-shell-bash-copy install-shell-openbsd install-perl install-tests-format uninstall-debian uninstall-openbsd uninstall-secureblue uninstall-shell uninstall-perl uninstall-tests-format test test-validate check format test-tooling test-delivery test-manpages test-regression test-agent-knowledge fix-permissions check-permissions check-agent-knowledge help

# OS-specific sets install the same command names, so they cannot share a
# single BINDIR. 'all' installs only the OS-independent runtime helper; choose
# install-debian, install-openbsd or install-secureblue for the target host.
# Developer validators and formatters are an explicit install-tests-format.
all: install-perl

clean:
	@echo "${INFO} Nothing to clean"

install-debian:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' DEBIAN_SCRIPTS='${DEBIAN_SCRIPTS}' \
		$(MANAGE) install-debian

install-openbsd:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' OPENBSD_SCRIPTS='${OPENBSD_SCRIPTS}' \
		$(MANAGE) install-openbsd

install-secureblue:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' SECUREBLUE_SCRIPTS='${SECUREBLUE_SCRIPTS}' \
		DEST_SYSTEMD_USER='${DEST_SYSTEMD_USER}' \
		$(MANAGE) install-secureblue

install-shell: install-shell-bash
	@INFO='${INFO}' $(MANAGE) install-shell

install-shell-bash: install-shell-bash-copy
	@INFO='${INFO}' SECUREBLUE_USER='${SECUREBLUE_USER}' \
		$(MANAGE) install-shell-bash

install-shell-bash-unlock:
	@INFO='${INFO}' BASH_CONF_DST_DIR='${BASH_CONF_DST_DIR}' \
		$(MANAGE) install-shell-bash-unlock

install-shell-bash-copy: install-shell-bash-unlock
	@INFO='${INFO}' BASH_CONF_DST_DIR='${BASH_CONF_DST_DIR}' \
		BASH_CONF_FILES='${BASH_CONF_FILES}' \
		$(MANAGE) install-shell-bash-copy

install-shell-openbsd:
	@INFO='${INFO}' $(MANAGE) install-shell-openbsd

install-perl:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' \
		PERL_PROGRAMS_MANIFEST='${PERL_PROGRAMS_MANIFEST}' \
		$(MANAGE) install-perl

install-tests-format:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' \
		DEST_TESTS_FORMAT='${DEST_TESTS_FORMAT}' \
		TESTS_FORMAT_LINKS='${TESTS_FORMAT_LINKS}' \
		TESTS_FORMAT_SCRIPTS='${TESTS_FORMAT_SCRIPTS}' \
		$(MANAGE) install-tests-format

uninstall-debian:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' DEBIAN_SCRIPTS='${DEBIAN_SCRIPTS}' \
		$(MANAGE) uninstall-debian

uninstall-openbsd:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' OPENBSD_SCRIPTS='${OPENBSD_SCRIPTS}' \
		$(MANAGE) uninstall-openbsd

uninstall-secureblue:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' SECUREBLUE_SCRIPTS='${SECUREBLUE_SCRIPTS}' \
		DEST_SYSTEMD_USER='${DEST_SYSTEMD_USER}' \
		$(MANAGE) uninstall-secureblue

uninstall-perl:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' \
		PERL_PROGRAMS_MANIFEST='${PERL_PROGRAMS_MANIFEST}' \
		$(MANAGE) uninstall-perl

uninstall-tests-format:
	@INFO='${INFO}' DESTBIN='${DESTBIN}' \
		DEST_TESTS_FORMAT='${DEST_TESTS_FORMAT}' \
		TESTS_FORMAT_LINKS='${TESTS_FORMAT_LINKS}' \
		TESTS_FORMAT_SCRIPTS='${TESTS_FORMAT_SCRIPTS}' \
		$(MANAGE) uninstall-tests-format

uninstall-shell:
	@INFO='${INFO}' BASH_CONF_DST_DIR='${BASH_CONF_DST_DIR}' \
		BASH_CONF_FILES='${BASH_CONF_FILES}' \
		$(MANAGE) uninstall-shell

test: test-validate
	@${MAKE} test-manpages
	@${MAKE} test-regression
	@echo "All configured tests completed; review skipped checks in logs."

check: test-validate test-manpages

format:
	@$(MANAGE) format

test-validate: check-agent-knowledge test-agent-knowledge
	@echo "Running shell script validation..." && /bin/sh tests-format/validate-shell.sh --check .
	@echo "Running perl script validation..." && /bin/sh tests-format/validate-perl.sh --check .
	@echo "Running make validation..." && /bin/sh tests-format/validate-make.sh --check .
	@echo "Checking file permissions (read-only)..." && /bin/sh tests-format/fix-permissions.sh --check .
	@echo "Running correctness audit..." && /bin/sh tests-format/validate-correctness.sh --target all .

test-manpages:
	@echo "Running man page validation..." && /bin/sh tests-format/validate-manpages.sh .

test-regression: test-tooling test-delivery
	@echo "Running fix-permissions regression tests..." && /bin/sh tests-format/test-fix-permissions.sh
	@echo "Running correctness regression tests..." && /bin/sh tests-format/test-validate-correctness.sh
	@echo "Running ssh-menu regression test..." && perl tests-format/test-ssh-menu.pl
	@echo "Running normalize-files regression test..." && perl tests-format/test-normalize-files.pl
	@echo "Running website sync filter tests..." && prove -Itests tests/test_sync_website_filters.pl

test-delivery:
	@prove -Itests tests/test_delivery_transactions.pl tests/test_release_updates.pl

test-tooling:
	@prove -Itests tests/test_tooling.pl tests/test_bootargs.pl

fix-permissions:
	@/bin/sh tests-format/fix-permissions.sh .

check-permissions:
	@/bin/sh tests-format/fix-permissions.sh --check .

check-agent-knowledge:
	@perl scripts/validate-agent-knowledge.pl --scope worktree

test-agent-knowledge:
	@prove tests/agent_knowledge_validator/test_validator.pl

HELP_ENV = INFO='${INFO}' PREFIX='${PREFIX}' DESTDIR='${DESTDIR}' \
	BINDIR='${BINDIR}' DESTBIN='${DESTBIN}' \
	SYSTEMD_USER_UNIT_DIR='${SYSTEMD_USER_UNIT_DIR}' \
	DEST_SYSTEMD_USER='${DEST_SYSTEMD_USER}' \
	TESTS_FORMAT_DIR='${TESTS_FORMAT_DIR}' \
	DEST_TESTS_FORMAT='${DEST_TESTS_FORMAT}' \
	TESTS_FORMAT_LINKS='${TESTS_FORMAT_LINKS}' \
	BASH_CONF_DST_DIR='${BASH_CONF_DST_DIR}'

help:
	@${HELP_ENV} $(MANAGE) help
