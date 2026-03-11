# DisplayLink Watchdog

A macOS menu bar app that automatically fixes DisplayLink monitors that fail to initialise after a power cycle — no Terminal needed.

## The Problem

If you use a DisplayLink USB adapter (e.g. Sonnet DisplayLink Dual 4K) with a dock on a smart outlet, power cycling the outlet causes a race condition: the DisplayLink driver finishes scanning before the adapter initialises on USB, leaving the monitor dark. This app detects that condition in real time and restarts the DisplayLink driver automatically — typically within 2 seconds.

## Install

1. Download **DisplayLink Watchdog.app** from [Releases](../../releases/latest)
2. Drag it to `/Applications`
3. Launch it — the icon appears in your menu bar
4. Open **Settings…** (click the menu bar icon → Settings…)
   - Click **Auto-Detect** to find your DisplayLink adapter automatically
   - Set **Expected displays** (total external monitors when everything is working)
   - Set **Base displays** (non-DisplayLink monitors; the fix waits until these are up first)
5. Enable **Launch at Login** so it starts automatically

That's it. The app runs silently in the menu bar and fixes your displays whenever they fail to wake.

## Menu Bar Icon

| Icon | Meaning |
|------|---------|
| `display.2` | All displays connected |
| `display.trianglebadge.exclamationmark` | Adapter present but display count is low — watching |
| `display.trianglebadge.exclamationmark` | No adapter detected / DisplayLink Manager not installed |

## Requirements

- macOS 13 Ventura or later
- [DisplayLink Manager](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) installed
- A DisplayLink USB adapter

## How It Works

The watchdog uses two event sources — no polling during normal operation:

1. **IOKit USB watcher** — fires the instant your DisplayLink adapter appears on the USB bus
2. **CoreGraphics display callback** — fires when macOS recognises a new display

Decision logic (unchanged from the original daemon):
```
Event fires (USB attach / display added / poll)
  → Within cooldown?              → skip
  → Adapter on USB bus?           → no: skip
  → All expected displays up?     → yes: skip
  → Base displays up?             → no: skip (dock still booting)
  → RESTART DisplayLink           → poll for success up to 8 s
```

## Settings Reference

| Setting | Default | Description |
|---------|---------|-------------|
| Vendor ID | `0x17e9` | USB Vendor ID of DisplayLink adapter |
| Product ID | `0x6000` | USB Product ID of DisplayLink adapter |
| Expected displays | `3` | Total external monitors when everything is working |
| Base displays | `2` | Non-DisplayLink monitors that must be up before fix is attempted |
| Cooldown | `30 s` | Minimum time between fix attempts |
| Poll interval | `300 s` | Fallback safety-net poll (in addition to real-time events) |

Settings are stored in `UserDefaults` under the `DLW_` key prefix and persist across launches.

## Viewing Logs

Click the menu bar icon → **View Log** to see recent watchdog activity (last 100 entries). Messages are also written to the macOS unified log via `os.Logger` — viewable in **Console.app** by filtering for subsystem `com.kakkarpulkit.displaylink-watchdog`.

---

## Developer Guide

### Building from source

Requirements: Xcode 15+, macOS 13+ SDK

```bash
# Open in Xcode
open DisplayLinkWatchdog.xcodeproj

# Or build from the command line (debug)
make app

# Release build
make app-release
```

### CLI daemon (original, headless)

The original single-file daemon is still buildable for headless/server use:

```bash
make build          # compile displaylink-watchdog binary
make install        # interactive install as a LaunchAgent
make uninstall
```

### Running tests

```bash
make test           # all tests
make test-logic     # pure decision-logic unit tests (no hardware needed)
make test-behavior  # daemon lifecycle integration tests (requires the CLI binary)
```

The `tests/test-logic.swift` file tests the fix-decision algorithm as a pure function — no hardware required. These tests cover cooldown behaviour, adapter-absent guard, display-count guards, and real-world event sequences.

### Project structure

```
DisplayLinkWatchdog/
├── App/
│   └── DisplayLinkWatchdogApp.swift    — @main SwiftUI App + scene declarations
├── Core/
│   ├── WatchdogEngine.swift            — orchestrates all logic; owns all sub-components
│   ├── WatchdogConfig.swift            — UserDefaults-backed configuration
│   ├── USBWatcher.swift                — IOKit USB matching notification
│   ├── DisplayWatcher.swift            — CoreGraphics display reconfiguration callback
│   ├── DisplayLinkRestarter.swift      — restart logic behind a protocol (swappable)
│   └── USBDeviceScanner.swift          — IOKit USB bus scan for adapter auto-detect
├── Views/
│   ├── MenuBarStatusView.swift         — menu bar dropdown content
│   ├── SettingsView.swift              — preferences window
│   └── LogView.swift                   — in-app log viewer
├── Utilities/
│   └── LogStore.swift                  — os.Logger wrapper + 100-entry ring buffer
└── Resources/
    ├── Assets.xcassets                 — app icon + accent colour
    └── Info.plist                      — LSUIElement, bundle ID, deployment target
DisplayLinkWatchdog.entitlements        — USB entitlement, hardened runtime, no sandbox
DisplayLinkWatchdog.xcodeproj/          — Xcode project (primary build mechanism)
```

### Sandbox status

The app intentionally does **not** enable App Sandbox. The core restart mechanism sends `SIGTERM` to DisplayLink processes via `/usr/bin/killall`, which is incompatible with the sandbox. The `DisplayLinkRestarter` protocol is there so this can be replaced with an XPC privileged helper in the future — without changing any other code.

### Distribution

For direct (non-App Store) distribution:
1. Archive in Xcode (Product → Archive)
2. Notarize with your Developer ID certificate
3. Export as a signed `.dmg` or `.zip`

For Mac App Store submission, the process-termination approach must be replaced with an XPC helper before the sandbox can be enabled.

## License

MIT
