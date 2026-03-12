PREFIX     ?= /usr/local
BINARY      = displaylink-watchdog
SRC         = displaylink-watchdog.swift
XCPROJECT   = DisplayLinkWatchdog.xcodeproj
SCHEME      = DisplayLinkWatchdog
BUILD_DIR   = build

.PHONY: build install uninstall test test-logic test-behavior app app-release clean

# ── CLI daemon (developer / headless use) ──────────────────────────────────

build: $(BINARY)

$(BINARY): $(SRC)
	swiftc -O -o $@ $< -framework IOKit -framework Foundation -framework CoreGraphics

install: $(BINARY)
	@./install.sh

uninstall:
	@./install.sh --uninstall

# ── macOS app (primary distribution) ──────────────────────────────────────

## Debug build — output in build/Build/Products/Debug/
app:
	xcodebuild -project $(XCPROJECT) -scheme $(SCHEME) \
	           -configuration Debug \
	           -derivedDataPath $(BUILD_DIR) \
	           CODE_SIGNING_ALLOWED=NO \
	           build

## Release build — output in build/Build/Products/Release/
app-release:
	xcodebuild -project $(XCPROJECT) -scheme $(SCHEME) \
	           -configuration Release \
	           -derivedDataPath $(BUILD_DIR) \
	           build

# ── Tests ──────────────────────────────────────────────────────────────────

test: test-logic test-behavior

test-logic: tests/test-logic
	tests/test-logic

tests/test-logic: tests/test-logic.swift
	swiftc -O -o $@ $<

test-behavior: $(BINARY)
	/bin/bash tests/test-behavior.sh

# ── Housekeeping ───────────────────────────────────────────────────────────

clean:
	rm -f $(BINARY) tests/test-logic
	rm -rf $(BUILD_DIR)
