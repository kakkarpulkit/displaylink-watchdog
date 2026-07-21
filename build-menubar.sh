#!/bin/bash
# Build the menu bar front-end into a .app bundle using swiftc only.
#
# Deliberately no Xcode project: the CLI needs nothing but Command Line Tools,
# and the menu bar app should not raise that bar. This assembles the bundle by
# hand, which is about 30 lines and has no project file to drift.
set -euo pipefail

APP_NAME="DisplayLink Watchdog"
BUNDLE_ID="com.kakkarpulkit.displaylink-watchdog.menubar"
EXEC_NAME="DisplayLinkWatchdogMenuBar"
SRC="menubar/DisplayLinkWatchdogMenuBar.swift"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"
VERSION="$(grep -m1 'let buildVersion' displaylink-watchdog.swift | sed 's/.*"\(.*\)".*/\1/')"

echo "Building $APP_NAME $VERSION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build for the host architecture — the README claims Apple Silicon *and* Intel,
# so do not hardcode arm64.
ARCH="$(uname -m)"
# -parse-as-library: without it swiftc treats a lone file as a script and @main
# is rejected as "cannot be used in a module that contains top-level code".
swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos13.0" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/$EXEC_NAME" \
    "$SRC"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License.</string>
</dict>
</plist>
EOF

# Ad-hoc signature. Enough to run locally; note that Launch at Login via
# SMAppService is unreliable for unsigned builds — the toggle reports its real
# state rather than pretending.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || echo "warning: ad-hoc codesign failed; app may not launch"

echo "Built: $APP"
