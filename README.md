# displaylink-watchdog

A macOS daemon that automatically fixes DisplayLink monitors that fail to initialize after a power cycle.

## The Problem

If you use a DisplayLink USB adapter (e.g., Sonnet DisplayLink Dual 4K) with a dock on a smart outlet, power cycling the outlet causes a race condition: the DisplayLink driver finishes scanning before the adapter initializes on USB, leaving the monitor without a signal.

## How It Works

The daemon uses two event sources — zero polling during normal operation:

1. **IOKit USB watcher** — fires the instant your DisplayLink adapter appears on the USB bus
2. **CoreGraphics display callback** — fires the instant macOS recognizes a new display

When both conditions are met (adapter present + base monitors up + DisplayLink monitor missing), it restarts the DisplayLink driver. The fix typically completes in under 2 seconds.

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- DisplayLink Manager installed

## Install

```bash
# Build
make build

# Interactive install (prompts for your adapter's USB IDs)
make install
```

The installer will ask for:
- **USB Vendor ID** — find with: `system_profiler SPUSBDataType | grep -A5 DisplayLink`
- **USB Product ID** — same command
- **Expected displays** — total external monitors
- **Base displays** — non-DisplayLink monitors (must be up before fix is attempted)

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
| `DLW_LOG_PATH` | `~/scripts/logs/displaylink-watchdog.log` | Log file path |

## Finding Your USB IDs

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
