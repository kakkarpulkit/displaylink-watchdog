#!/bin/bash
set -euo pipefail

BINARY_NAME="displaylink-watchdog"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/$BINARY_NAME"
INSTALL_DIR="$HOME/scripts"
PLIST_LABEL="com.displaylink-watchdog"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"

if [ "${1:-}" = "--uninstall" ]; then
    echo "Uninstalling $BINARY_NAME..."
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    echo "Done. Log files in ~/scripts/logs/ were left in place."
    exit 0
fi

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found. Run 'make build' first."
    exit 1
fi

# Prompt for config
echo "=== DisplayLink Watchdog Setup ==="
echo ""
echo "You'll need the USB Vendor ID and Product ID of your DisplayLink adapter."
echo "Run: system_profiler SPUSBDataType | grep -A5 'DisplayLink'"
echo ""

read -p "USB Vendor ID  (hex, e.g. 0x17e9): " VENDOR_ID
read -p "USB Product ID (hex, e.g. 0x6000): " PRODUCT_ID
read -p "Total external displays expected [3]: " EXPECTED
read -p "Non-DisplayLink displays (base) [2]: " BASE

EXPECTED="${EXPECTED:-3}"
BASE="${BASE:-2}"

# Install binary
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Stop existing agent
launchctl unload "$PLIST" 2>/dev/null || true

# Generate plist
mkdir -p "$PLIST_DIR"
cat > "$PLIST" << EOF
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

# Start agent
launchctl load "$PLIST"
sleep 2

if pgrep -q "$BINARY_NAME"; then
    echo ""
    echo "Installed and running."
    echo "  Binary:  $INSTALL_DIR/$BINARY_NAME"
    echo "  Plist:   $PLIST"
    echo "  Log:     ~/scripts/logs/displaylink-watchdog.log"
    echo ""
    echo "To uninstall: make uninstall"
else
    echo ""
    echo "Warning: daemon started but may have exited. Check:"
    echo "  tail -f ~/scripts/logs/displaylink-watchdog.log"
fi
