# Media Alarm — convenience targets.
#
# Inspect an alarm installed under a non-default label by overriding LABEL:
#   make status LABEL=local.my-alarm

LABEL ?= local.media-alarm
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist

.PHONY: status check
check: status ## Alias for `status`.
status: ## Show the installed alarm's schedule, flags, and loaded state.
	@if [ ! -f "$(PLIST)" ]; then \
		echo "No alarm installed under label '$(LABEL)'."; \
		echo "($(PLIST) not found — run install.sh, or pass LABEL=<your-label>.)"; \
		exit 1; \
	fi
	@echo "== Config: $(PLIST) =="
	@plutil -p "$(PLIST)"
	@echo
	@echo "== launchd state =="
	@launchctl print "gui/$$(id -u)/$(LABEL)" 2>/dev/null | grep -iE 'state =|program =' \
		|| echo "Not loaded (plist exists but agent is not bootstrapped — run install.sh)."
