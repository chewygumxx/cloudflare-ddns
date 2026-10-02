# vim:set noexpandtab tabstop=4 shiftwidth=4 filetype=make:
# SPDX-License-Identifier: GPL-3.0-only

#
#
# ~chewygumxx/cloudflare-ddns.git
# ::: :/Makefile
#
#

#
# Installs cloudflare-ddns into the current user's own
# XDG directories.
#
# The service and timer are systemd templates, so enabling
# or disabling one requires the instance name used for its
# credential file, e.g.:
#
#     make enable  NAME=home
#     make disable NAME=home
#

SCRIPT    := cloudflare-ddns
SERVICE   := $(SCRIPT)@.service
TIMER     := $(SCRIPT)@.timer

BINDIR    := $(HOME)/.local/bin
CONFIGDIR := $(or $(XDG_CONFIG_HOME),$(HOME)/.config)
UNITDIR   := $(CONFIGDIR)/systemd/user

NAME      ?=

.PHONY: all install uninstall enable disable require-name

all: install

install:
	install -Dm755 $(SCRIPT)  "$(BINDIR)/$(SCRIPT)"
	install -Dm644 $(SERVICE) "$(UNITDIR)/$(SERVICE)"
	install -Dm644 $(TIMER)   "$(UNITDIR)/$(TIMER)"
	systemctl --user daemon-reload

require-name:
	@if [ -z "$(NAME)" ]; then \
		printf '%s\n' "NAME is required, e.g. make enable NAME=home" >&2; \
		exit 1; \
	fi

enable: require-name install
	systemctl --user enable --now "$(SCRIPT)@$(NAME).timer"

disable: require-name
	-systemctl --user disable --now "$(SCRIPT)@$(NAME).timer"

uninstall:
	rm -f "$(BINDIR)/$(SCRIPT)" "$(UNITDIR)/$(SERVICE)" "$(UNITDIR)/$(TIMER)"
	systemctl --user daemon-reload
