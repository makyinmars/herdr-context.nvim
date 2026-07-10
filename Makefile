.PHONY: test test-live lint

test:
	XDG_STATE_HOME=/tmp/herdr-context-nvim-state nvim --headless -u tests/minimal_init.lua -l tests/run.lua

test-live:
	HERDR_LIVE_TEST=1 XDG_STATE_HOME=/tmp/herdr-context-nvim-state nvim --headless -u tests/minimal_init.lua -l tests/live.lua

lint:
	stylua --check lua plugin tests
