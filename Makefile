PREFIX ?= /usr/local
BINARY = displaylink-watchdog
SRC    = displaylink-watchdog.swift

.PHONY: build install uninstall status selftest test test-logic test-behavior clean

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

test: test-logic test-behavior

test-logic: tests/test-logic
	tests/test-logic

tests/test-logic: tests/test-logic.swift
	swiftc -O -o $@ $<

test-behavior: $(BINARY)
	/bin/bash tests/test-behavior.sh

clean:
	rm -f $(BINARY) tests/test-logic
