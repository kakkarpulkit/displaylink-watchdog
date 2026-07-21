# displaylink-watchdog

A macOS daemon that automatically fixes DisplayLink monitors that fail to initialize after a power cycle.

## The Problem

If you use a DisplayLink USB adapter (e.g., Sonnet DisplayLink Dual 4K) with a dock on a smart outlet, power cycling the outlet causes a race condition: the DisplayLink driver finishes scanning before the adapter initializes on USB, leaving the monitor without a signal.

## How It Works

The daemon uses two event sources — zero polling during normal operation:

1. **IOKit USB watcher** — fires the instant your DisplayLink adapter appears on the USB bus
2. **CoreGraphics display callback** — fires the instant macOS recognizes a new display

When both conditions are met (adapter present + base monitors up + DisplayLink monitor missing), it restarts the DisplayLink driver. The fix typically completes in under 2 seconds.

## Menu Bar App (optional)

`make status` answers "is it working" only if you remember to ask. The menu bar
app answers it without being asked.

```bash
make menubar          # build build/DisplayLink Watchdog.app
make install-menubar  # build, copy to /Applications, launch
```

Then enable **Launch at Login** from the icon.

| Icon | Meaning |
|------|---------|
| `display` | Healthy — agent loaded, running, config matches hardware |
| `exclamationmark.triangle.fill` | Not running, or running but would never act |
| `display.trianglebadge.exclamationmark` | Cannot reach the CLI binary |

The menu shows the live self-test result and offers **Restart DisplayLink Now**,
**Re-check Now**, and **Open Log**.

**The app contains no watchdog logic.** It shells out to `displaylink-watchdog
--selftest` and `--restart` and reads the daemon's log file. The decision logic
lives in exactly one place — the CLI — so there is one implementation to test and
one durable log to read after something goes wrong. The app is a front-end; the
daemon is still what fixes your displays, and it works with or without the app
installed.

It builds with `swiftc` alone — no Xcode project, no signing setup. Note that
`SMAppService` launch-at-login is unreliable for unsigned builds; the toggle
reports its true state rather than pretending it worked.

## Limitations

**This tool detects a missing display, not a broken one.**

Detection is a count: it compares the number of online external displays against
`DLW_EXPECTED`. That is exactly right for the power-cycle race above, where the
adapter genuinely drops off the USB bus and the display genuinely leaves the
display list.

It will **not** catch a DisplayLink display that stays enumerated while going
dark — where macOS still reports the display as `active`, `online`, and awake,
but no frames reach the panel. In that state the count reads healthy, and the
daemon correctly does nothing. Symptoms:

- The monitor is black, but it still appears in System Settings → Displays
- Windows can still be moved onto it
- `make status` reports healthy

If that is your failure, restarting DisplayLink by hand usually clears it:

```bash
killall DisplayLinkUserAgent DisplayLinkXpcService && open -a "DisplayLink Manager"
```

Detecting that state automatically is unsolved here — the obvious signals
(`CGDisplayIsActive`, `CGDisplayIsAsleep`, framebuffer capture, USB presence) all
report healthy while the panel is dark.

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- DisplayLink Manager installed

## Install

```bash
make build
make install
```

The installer auto-detects your adapter's USB IDs, prompts you to confirm the
display counts, then **verifies the result** — that the agent registered with
launchd, that the daemon is running, and that a self-test passes against your
live hardware. If any of those fail it says so and exits non-zero.

For scripted or dotfile installs:

```bash
./install.sh --yes                        # accept everything detected
./install.sh --yes --expected 3 --base 2  # override display counts
./install.sh --vendor-id 0x17e9 --product-id 0x6000 --yes
```

| Flag | Meaning |
|------|---------|
| `--vendor-id HEX` / `--product-id HEX` | Override USB ID auto-detection |
| `--expected N` / `--base N` | Display counts |
| `--yes` | Non-interactive |
| `--uninstall` | Remove agent and binary |

## Is It Actually Working?

The failure mode of a watchdog is **silence** — and a daemon that died months ago
looks exactly like one that is healthy and simply hasn't needed to fire. Two
things address that:

```bash
make status     # is it loaded, running, and matched to your hardware?
make selftest   # would a fix trigger if the display dropped right now?
```

`make status` checks the binary, the plist, launchd registration, the live
config, a hardware self-test, and log freshness — and exits non-zero if anything
is wrong.

```
  ok   binary installed: ~/scripts/displaylink-watchdog (displaylink-watchdog 1.1.0)
  ok   plist present: ~/Library/LaunchAgents/com.displaylink-watchdog.plist
  ok   daemon running (pid 59069)
  ok   config: VID=0x17e9 PID=0x6000 expected=3 base=2
    ok   usb adapter: found at VID 0x17e9/PID 0x6000
    ok   display count: 3 external display(s) online, base=2, expected=3
  ok   log active (0h ago)

Healthy. The watchdog is loaded, running, and matches your hardware.
```

The daemon also writes a heartbeat every `DLW_HEARTBEAT_HOURS` (default 6), so a
stale log is a real signal rather than an ambiguous one.

## Uninstall

```bash
make uninstall
```

## Configuration

All config is via environment variables in the LaunchAgent plist (set during install):

| Variable | Default | Description |
|----------|---------|-------------|
| `DLW_VENDOR_ID` | `0x17e9` | USB Vendor ID of DisplayLink adapter |
| `DLW_PRODUCT_ID` | `0x6000` | USB Product ID of DisplayLink adapter |
| `DLW_EXPECTED` | `3` | Total external displays expected |
| `DLW_BASE` | `2` | Non-DisplayLink displays that must be up first |
| `DLW_COOLDOWN` | `30` | Seconds between fix attempts |
| `DLW_POLL_INTERVAL` | `300` | Fallback poll interval (safety net) |
| `DLW_HEARTBEAT_HOURS` | `6` | Liveness line in the log; `0` disables |
| `DLW_LOG_PATH` | `~/scripts/logs/displaylink-watchdog.log` | Log file path |

## Finding Your USB IDs

The installer detects these automatically. Use this only if detection fails or
you have multiple DisplayLink devices and need to pick a specific one:

```bash
system_profiler SPUSBDataType -json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for bus in data.get('SPUSBDataType', []):
    for dev in bus.get('_items', []):
        if 'displaylink' in dev.get('_name', '').lower() or 'displaylink' in dev.get('manufacturer', '').lower():
            print(f\"  Name:       {dev.get('_name')}\")
            print(f\"  Vendor ID:  0x{int(dev.get('vendor_id', '0x0'), 16):04x}\")
            print(f\"  Product ID: 0x{int(dev.get('product_id', '0x0'), 16):04x}\")
"
```

## Tests

```bash
make test          # run all tests
make test-logic    # decision logic unit tests
make test-behavior # daemon lifecycle tests
```

## How It Decides

```
Event fires (USB attach / display added / poll)
  → Cooldown active?           → skip
  → Adapter on USB bus?         → no: skip
  → All displays up?            → yes: skip
  → Base (TB) monitors up?      → no: skip (still booting)
  → RESTART DisplayLink         → poll for success up to 8s
```

## Log Output

```
2026-03-01T02:28:38Z: === Started (PID 14512) ===
2026-03-01T02:28:38Z: Config: VID=0x17e9 PID=0x6000 expected=3 base=2
2026-03-01T08:15:22Z: DisplayLink adapter appeared on USB bus.
2026-03-01T08:15:22Z: 2/3 displays (usb-attach). Restarting DisplayLink...
2026-03-01T08:15:24Z: Fixed: 3 displays up (1.5s).
```

## License

MIT
