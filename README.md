# DisplayLink Watchdog

> A macOS menu bar app that automatically restarts the DisplayLink driver when your monitors go dark — so you never have to do it manually again.

---

## The Problem

If you use a DisplayLink USB adapter or dock, you've almost certainly hit this: you wake your Mac from sleep, switch inputs, reconnect your dock, or just come back to your desk — and one or more of your DisplayLink monitors is dark, blank, or showing "No Signal."

The fix everyone in the community already knows is: **quit and restart DisplayLink Manager**. It works almost every time. But it's tedious, and it shouldn't be something you have to do manually.

**This app does that restart for you, automatically, the moment it detects the problem.**

### When does this happen?

This is a well-known, widely-reported issue across the DisplayLink community ([DisplayLink forums](https://www.displaylink.org/forum/), [r/macsetups](https://reddit.com/r/macsetups), [Apple Discussions](https://discussions.apple.com)):

| Trigger | What happens |
|---------|-------------|
| **Mac wakes from sleep** | One or more DisplayLink monitors don't come back. You have to restart DisplayLink Manager manually. |
| **Dock or adapter unplugged and replugged** | macOS re-enumerates USB devices, but the DisplayLink driver doesn't re-initialize the display. |
| **Powered dock on a smart outlet or UPS** | Power cycling the outlet causes a race condition: the driver finishes scanning before the adapter appears on USB. |
| **MacBook lid open or closed** | Opening or closing the lid can cause DisplayLink monitors to drop. |
| **After a macOS update** | Permissions or driver state can get reset, leaving monitors blank until the driver is restarted. |

In every case, the root cause is the same: the DisplayLink driver initializes before the adapter is fully ready, and doesn't recover on its own. The fix is always the same: restart the driver. DisplayLink Watchdog automates that.

---

## Install

**Requirements:** macOS 13 Ventura or later · [DisplayLink Manager](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) installed

1. Download **DisplayLink Watchdog.app** from [Releases](../../releases/latest)
2. Drag it to your `/Applications` folder
3. Launch it — a small icon appears in your menu bar
4. Click the menu bar icon → **Settings…**
   - Click **Auto-Detect** to automatically find your DisplayLink adapter
   - Set **Expected displays** — the total number of external monitors you normally have connected
   - Set **Base displays** — how many non-DisplayLink monitors you have (the fix waits until these are online first)
5. Enable **Launch at Login** so it starts automatically every time you log in

That's it. The app runs silently in the background. When a monitor fails to appear, it restarts the DisplayLink driver within a few seconds — no Terminal, no manual restart, no fuss.

---

## Menu Bar Icon

| Icon | Meaning |
|------|---------|
| 🖥🖥 | All expected displays are connected — everything is working |
| ⚠️ | Something is off — check the dropdown for details |

Click the icon at any time to see the current display count, when the last automatic fix was applied, and quick access to Settings and the log viewer.

---

## How It Works

The watchdog reacts to events in real time — it doesn't sit in a polling loop burning CPU.

**Event sources:**

1. **IOKit USB watcher** — fires the instant your DisplayLink adapter appears on the USB bus (dock reconnect, power restore, etc.)
2. **CoreGraphics display callback** — fires when macOS recognizes a new display (sleep/wake, lid open)
3. **Fallback poll** — a configurable safety net (default: every 5 minutes) for anything the event watchers might miss

**Decision logic:**

```
Event fires (USB attach / display added / poll timer)
  → Within cooldown window?           → skip  (prevents rapid-fire restarts)
  → Adapter present on USB bus?       → no: skip  (dock is off or unplugged)
  → All expected displays already up? → yes: skip  (nothing to fix)
  → Base displays online?             → no: skip  (dock still booting; wait)
  → RESTART DisplayLink driver        → poll for recovery up to 8 s
```

The logic is intentionally conservative: it only restarts when all the conditions are met, and it won't hammer the driver during a cooldown window.

---

## Settings Reference

Open **Settings…** from the menu bar icon to configure the app.

| Setting | Default | What it controls |
|---------|---------|-----------------|
| Vendor ID | `0x17e9` | USB Vendor ID of your DisplayLink adapter (auto-detected) |
| Product ID | auto | USB Product ID of your DisplayLink adapter (auto-detected) |
| Expected displays | `3` | Total external monitors when everything is working correctly |
| Base displays | `2` | Non-DisplayLink monitors; fix waits until these are online first |
| Cooldown | `30 s` | Minimum time between fix attempts |
| Poll interval | `300 s` | How often to run a background safety-net check |

**Auto-Detect** scans your USB bus and lists any DisplayLink adapters found. If you have only one, it is selected automatically.

Settings are stored in `~/Library/Preferences/com.kakkarpulkit.displaylink-watchdog.plist` and persist across app updates and reboots.

---

## Troubleshooting

**My monitors still go dark and the app doesn't fix them.**
Open the log (menu bar icon → **View Log**) and check what the watchdog is reporting. Common reasons it skips a fix:
- **Expected displays is wrong.** If set too high, the watchdog will always see a deficit and keep retrying through the cooldown; if too low, it may skip when a fix is actually needed.
- **Base displays is wrong.** If base is set to 2 but only 1 non-DisplayLink monitor is online when you wake, the watchdog waits for the dock to finish booting — this is intentional. Adjust base to match your setup.
- **Adapter not detected.** The ⚠️ icon with "No DisplayLink adapter detected" means the watchdog can't see your adapter on USB. Make sure it's physically connected.

**The app shows "DisplayLink Manager not installed."**
Download and install [DisplayLink Manager](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) from Synaptics, then relaunch DisplayLink Watchdog.

**My adapter wasn't auto-detected.**
Make sure the dock or adapter is physically connected when you open Settings and click **Auto-Detect**. If it still isn't found, enter the Vendor ID and Product ID manually — find them by running this in Terminal: `system_profiler SPUSBDataType | grep -A5 DisplayLink`

**The driver restarts but the monitor still doesn't come back.**
A small number of adapter/monitor combinations take longer than 8 seconds to recover. The watchdog will retry on the next event. You can also reduce the cooldown to allow faster retries.

---

## Privacy & Security

DisplayLink Watchdog:
- **Collects no data.** No analytics, no telemetry, no network requests of any kind.
- **Does not read your screen.** It only counts how many displays are connected — never what is on them.
- **Does not require administrator access.** It runs entirely as your normal logged-in user.
- **Terminates only two processes:** `DisplayLinkUserAgent` and `DisplayLinkXpcService` — both owned by Synaptics, not system processes or your data.

See [Sandbox status](#sandbox-status) in the developer section for more detail.

---

---

## Developer Guide

### Building from source

Requirements: **Xcode 15+**, macOS 13 SDK or later.

```bash
# Open in Xcode (recommended)
open DisplayLinkWatchdog.xcodeproj

# Command-line debug build (no signing required)
make app

# Release build (requires a signing identity)
make app-release
```

### Running tests

```bash
make test           # all tests
make test-logic     # pure decision-logic unit tests — no hardware required
make test-behavior  # CLI daemon integration tests
```

`tests/test-logic.swift` tests the fix-decision algorithm, cooldown boundary behavior, hex parsing and validation, display name formatting, and real-world event sequences — all as pure functions with no DisplayLink hardware required.

### CLI daemon (original, headless)

The original single-file daemon is still buildable for headless or server environments:

```bash
make build          # compile displaylink-watchdog binary
make install        # interactive install as a LaunchAgent
make uninstall
```

### Project structure

```
DisplayLinkWatchdog/
├── App/
│   └── DisplayLinkWatchdogApp.swift    — @main SwiftUI App; MenuBarExtra, Settings, Log window
├── Core/
│   ├── WatchdogEngine.swift            — central ObservableObject; owns all watchers and fix logic
│   ├── WatchdogConfig.swift            — all settings, backed by UserDefaults (DLW_ key prefix)
│   ├── USBWatcher.swift                — IOKit USB matching notification (C trampoline, main run loop)
│   ├── DisplayWatcher.swift            — CoreGraphics display reconfiguration callback
│   ├── DisplayLinkRestarter.swift      — restart logic behind a protocol (swappable for XPC later)
│   └── USBDeviceScanner.swift          — IOKit USB bus scan for adapter auto-detect in Settings
├── Views/
│   ├── MenuBarStatusView.swift         — menu bar dropdown (status, log, settings, launch-at-login, quit)
│   ├── SettingsView.swift              — preferences window
│   └── LogView.swift                   — scrollable in-app log viewer (last 100 entries)
├── Utilities/
│   └── LogStore.swift                  — os.Logger wrapper + 100-entry in-memory ring buffer
└── Resources/
    ├── Assets.xcassets                 — app icon and accent colour stubs
    └── Info.plist                      — LSUIElement=true, bundle ID, deployment target 13.0
DisplayLinkWatchdog.entitlements        — USB entitlement, hardened runtime; sandbox intentionally off
DisplayLinkWatchdog.xcodeproj/          — Xcode project (primary build mechanism)
tests/
├── test-logic.swift                    — standalone unit tests (compiled with swiftc, no Xcode needed)
└── test-behavior.sh                    — CLI daemon integration tests
```

### Architecture notes

**Threading model:**
- All IOKit and CoreGraphics callbacks arrive on the **main thread** — the IOKit notification port's run loop source is explicitly added to the main run loop, and Apple's documentation states CG reconfiguration callbacks fire on main.
- A `ConfigSnapshot` is captured on main before every background dispatch, eliminating data races between the fix logic on `workQueue` and concurrent UserDefaults writes from the Settings UI.
- `workQueue` (serial, `.utility` QoS) handles all blocking work: IOKit device-presence queries, `Thread.sleep` polling, and spawning processes.
- All `@Published` mutations are dispatched via `DispatchQueue.main.async`.

**Config change propagation:**
- `WatchdogEngine` subscribes via Combine to `config.$vendorID`, `config.$productID`, and `config.$pollInterval`. Changes are debounced (500 ms) and automatically restart the affected watcher or timer, so settings take effect immediately without restarting the app.

**Restart isolation:**
- `DisplayLinkRestarter` is a protocol. The live implementation uses a subprocess and `NSWorkspace.openApplication`. Swapping it for an XPC privileged helper (for future App Sandbox compliance) requires changing only this one class.

### Sandbox status

The app intentionally does **not** enable App Sandbox. The restart mechanism terminates DisplayLink processes via a subprocess, which is incompatible with the App Sandbox. The `DisplayLinkRestarter` protocol isolates this so an XPC privileged helper can be added later without touching the watchdog logic.

For **direct (notarized) distribution** outside the App Store, no sandbox is required. For **Mac App Store submission**, replace `LiveDisplayLinkRestarter` with an XPC privileged helper and enable the sandbox.

### Distribution

**Direct download (notarized):**
1. Archive in Xcode (Product → Archive)
2. Notarize with your Developer ID certificate
3. Export as a signed `.dmg` or `.zip`

**Mac App Store:**
Replace `LiveDisplayLinkRestarter` with an XPC privileged helper, enable App Sandbox, submit through App Store Connect.

---

## License

MIT — see [LICENSE](LICENSE).
