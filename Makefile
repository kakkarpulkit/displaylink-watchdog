PREFIX ?= /usr/local
BINARY = displaylink-watchdog
SRC    = displaylink-watchdog.swift

.PHONY: build install uninstall status selftest restart menubar install-menubar test test-logic test-behavior clean

APP = build/DisplayLink Watchdog.app

build: $(BINARY)

$(BINARY): $(SRC)
	swiftc -O -o $@ $< -framework IOKit -framework Foundation -framework CoreGraphics

install: $(BINARY)
	@./install.sh

uninstall:
	@./install.sh --uninstall

status:
	@./status.sh

selftest: $(BINARY)
	@./$(BINARY) --selftest

restart: $(BINARY)
	@./$(BINARY) --restart

# Optional menu bar front-end. Contains no watchdog logic — it shells out to the
# CLI and tails its log, so there is one implementation to keep correct.
menubar:
	@./build-menubar.sh

install-menubar: menubar
	@pkill -f "DisplayLinkWatchdogMenuBar" 2>/dev/null || true
	@rm -rf "/Applications/DisplayLink Watchdog.app"
	@cp -R "$(APP)" /Applications/
	@open "/Applications/DisplayLink Watchdog.app"
	@echo "Installed to /Applications and launched."
	@echo "Enable 'Launch at Login' from the menu bar icon."

test: test-logic test-behavior

test-logic: tests/test-logic
	tests/test-logic

tests/test-logic: tests/test-logic.swift
	swiftc -O -o $@ $<

test-behavior: $(BINARY)
	/bin/bash tests/test-behavior.sh

clean:
	rm -f $(BINARY) tests/test-logic
	rm -rf build
