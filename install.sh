#!/bin/bash
set -euo pipefail

BINARY_NAME="displaylink-watchdog"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/$BINARY_NAME"
INSTALL_DIR="${DLW_INSTALL_DIR:-$HOME/scripts}"
PLIST_LABEL="com.displaylink-watchdog"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"
DOMAIN="gui/$(id -u)"

VENDOR_ID=""; PRODUCT_ID=""; EXPECTED=""; BASE=""; ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

  --vendor-id HEX     USB vendor ID  (default: auto-detected)
  --product-id HEX    USB product ID (default: auto-detected)
  --expected N        Total external displays expected
  --base N            Non-DisplayLink displays that must be up first
  --yes               Non-interactive; accept detected/default values
  --uninstall         Remove agent and binary
  --help              This message

With no options the installer auto-detects your adapter and prompts to confirm.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vendor-id)  VENDOR_ID="$2"; shift 2 ;;
        --product-id) PRODUCT_ID="$2"; shift 2 ;;
        --expected)   EXPECTED="$2"; shift 2 ;;
        --base)       BASE="$2"; shift 2 ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        --uninstall)
            echo "Uninstalling $BINARY_NAME..."
            launchctl bootout "$DOMAIN/$PLIST_LABEL" 2>/dev/null \
                || launchctl unload "$PLIST" 2>/dev/null || true
            rm -f "$PLIST" "$INSTALL_DIR/$BINARY_NAME"
            echo "Done. Logs in ~/scripts/logs/ were left in place."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -f "$BINARY" ] || { echo "Error: binary not found. Run 'make build' first." >&2; exit 1; }

# --- Auto-detect the adapter ------------------------------------------------
# Hand-copying hex IDs is the single most common way to end up with a daemon
# that runs forever and never fires, so detect them and verify before writing.
detect_usb() {
    system_profiler SPUSBDataType -json 2>/dev/null | python3 -c '
import json, sys
def walk(items):
    for d in items:
        name = (d.get("_name") or "") + " " + (d.get("manufacturer") or "")
        if "displaylink" in name.lower():
            v, p = d.get("vendor_id", ""), d.get("product_id", "")
            if v and p:
                print("%s %s %s" % (v.split()[0], p.split()[0], d.get("_name","adapter")))
                return True
        if walk(d.get("_items", [])): return True
    return False
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
walk(data.get("SPUSBDataType", []))
' 2>/dev/null
}

DETECTED_NAME=""
if [ -z "$VENDOR_ID" ] || [ -z "$PRODUCT_ID" ]; then
    read -r dv dp dname <<< "$(detect_usb || true)"
    if [ -n "${dv:-}" ]; then
        [ -z "$VENDOR_ID" ]  && VENDOR_ID="$dv"
        [ -z "$PRODUCT_ID" ] && PRODUCT_ID="$dp"
        DETECTED_NAME="$dname"
        echo "Detected DisplayLink adapter: $dname  (VID $VENDOR_ID / PID $PRODUCT_ID)"
    else
        echo "No DisplayLink adapter detected on USB."
        echo "Plug it in and re-run, or pass --vendor-id/--product-id explicitly."
        [ "$ASSUME_YES" = "1" ] && exit 1
    fi
fi

# --- Display counts ---------------------------------------------------------
CURRENT_EXT=$(system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -cE "^ {8}[A-Za-z].*:$" || true)
[ -z "$EXPECTED" ] && EXPECTED="${CURRENT_EXT:-3}"
[ -z "$BASE" ] && BASE=$(( EXPECTED > 1 ? EXPECTED - 1 : 1 ))

if [ "$ASSUME_YES" != "1" ]; then
    echo ""
    echo "=== DisplayLink Watchdog Setup ==="
    echo "Press enter to accept the value in brackets."
    echo ""
    read -r -p "USB Vendor ID  [$VENDOR_ID]: " x; VENDOR_ID="${x:-$VENDOR_ID}"
    read -r -p "USB Product ID [$PRODUCT_ID]: " x; PRODUCT_ID="${x:-$PRODUCT_ID}"
    echo "Currently $CURRENT_EXT external display(s) connected."
    read -r -p "Total external displays expected [$EXPECTED]: " x; EXPECTED="${x:-$EXPECTED}"
    read -r -p "Non-DisplayLink displays (base)  [$BASE]: " x; BASE="${x:-$BASE}"
fi

if [ "$EXPECTED" -le "$BASE" ]; then
    echo "Error: expected ($EXPECTED) must be greater than base ($BASE)," >&2
    echo "otherwise a fix can never trigger." >&2
    exit 1
fi

# --- Install ----------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$PLIST_DIR"
cp "$BINARY" "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

launchctl bootout "$DOMAIN/$PLIST_LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$BINARY_NAME</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DLW_VENDOR_ID</key>
        <string>$VENDOR_ID</string>
        <key>DLW_PRODUCT_ID</key>
        <string>$PRODUCT_ID</string>
        <key>DLW_EXPECTED</key>
        <string>$EXPECTED</string>
        <key>DLW_BASE</key>
        <string>$BASE</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null || true
sleep 2

# --- Verify -----------------------------------------------------------------
# An installer that reports success without proving it is how a watchdog ends up
# dead for months without anyone noticing.
echo ""
echo "--- Verifying ---"
FAILED=0

if launchctl print "$DOMAIN/$PLIST_LABEL" >/dev/null 2>&1; then
    echo "  ok   agent registered with launchd"
else
    echo " FAIL  agent not registered"; FAILED=1
fi

if pgrep -qf "$INSTALL_DIR/$BINARY_NAME"; then
    echo "  ok   daemon running"
else
    echo " FAIL  daemon not running"; FAILED=1
fi

if DLW_VENDOR_ID="$VENDOR_ID" DLW_PRODUCT_ID="$PRODUCT_ID" \
   DLW_EXPECTED="$EXPECTED" DLW_BASE="$BASE" \
   "$INSTALL_DIR/$BINARY_NAME" --selftest >/tmp/dlw-selftest.$$ 2>&1; then
    echo "  ok   self-test passed against live hardware"
else
    echo " FAIL  self-test failed:"; sed 's/^/         /' /tmp/dlw-selftest.$$
    FAILED=1
fi
rm -f /tmp/dlw-selftest.$$

echo ""
if [ "$FAILED" = "0" ]; then
    cat <<EOF
Installed and verified.
  Binary:  $INSTALL_DIR/$BINARY_NAME
  Plist:   $PLIST
  Log:     ~/scripts/logs/displaylink-watchdog.log
  Config:  VID=$VENDOR_ID PID=$PRODUCT_ID expected=$EXPECTED base=$BASE

Check on it any time with:  make status
EOF
else
    echo "Installation completed with failures — see above. The daemon may not act."
    exit 1
fi
