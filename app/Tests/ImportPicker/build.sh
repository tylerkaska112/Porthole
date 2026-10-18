#!/bin/bash
# Builds Harness.swift with the real FolderPickerSheet into a small simulator app, installs and launches it on the booted simulator.   usage: build.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; S="$HERE/../../Sources"
BUILD="${BUILD:-/tmp/claude-501/import-picker-build}"; APP="$BUILD/ImportHarness.app"; SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
rm -rf "$BUILD"; mkdir -p "$APP"
swiftc -swift-version 5 -parse-as-library -Onone -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-name ImportHarness -o "$APP/ImportHarness" "$S/UI/FilePickerSheet.swift" "$HERE/Harness.swift"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ImportHarness</string><key>CFBundleIdentifier</key><string>site.portholehq.importharness</string><key>CFBundleName</key><string>ImportHarness</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1</string><key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>18.0</string>
<key>UILaunchScreen</key><dict/><key>UIRequiresFullScreen</key><true/><key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array></dict></plist>
PLIST
UDID="$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
[ -n "$UDID" ] || { echo "no booted simulator"; exit 1; }
xcrun simctl install "$UDID" "$APP"; xcrun simctl terminate "$UDID" site.portholehq.importharness 2>/dev/null || true
xcrun simctl launch "$UDID" site.portholehq.importharness
