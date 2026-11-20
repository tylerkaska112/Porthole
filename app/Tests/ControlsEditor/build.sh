#!/bin/bash
# Builds the real on-screen controls and editor (UI/ControlsKit.swift, CustomControls.swift, ControlsEditor.swift, Core/BindSets.swift, PadActions.swift) with Harness.swift into a small
# app for the iOS simulator, installs it on the booted simulator and launches it with the given launch arguments.   usage: build.sh [launch args...]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; S="$HERE/../../Sources"
BUILD="${BUILD:-/tmp/claude-501/controls-editor-build}"; APP="$BUILD/ControlsHarness.app"; SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
if [ "${NOBUILD:-0}" != "1" ]; then
  rm -rf "$BUILD"; mkdir -p "$APP"
  swiftc -swift-version 5 -parse-as-library -Onone -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-name ControlsHarness -o "$APP/ControlsHarness" \
    "$S/UI/ControlsKit.swift" "$S/UI/CustomControls.swift" "$S/UI/ControlsEditor.swift" "$S/Core/BindSets.swift" "$S/Core/PadActions.swift" "$S/Core/ControlArrange.swift" "$S/Core/TouchButtonSize.swift" "$S/Core/LayoutCheck.swift" "$S/Core/ShippedLayouts.swift" "$S/UI/SlideAcross.swift" "$S/UI/CustomPadControls.swift" "$S/Core/TouchPadControls.swift" "$S/Core/PictureBand.swift" "$S/Core/FloatingStick.swift" "$S/Core/VirtualPadModel.swift" "$S/Core/ControllerKind.swift" "$HERE/Harness.swift"
  cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ControlsHarness</string><key>CFBundleIdentifier</key><string>site.portholehq.controlsharness</string><key>CFBundleName</key><string>ControlsHarness</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1</string><key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>18.0</string>
<key>UILaunchScreen</key><dict/><key>UIRequiresFullScreen</key><true/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationLandscapeRight</string></array></dict></plist>
PLIST
fi
UDID="$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
[ -n "$UDID" ] || { echo "no booted simulator: xcrun simctl boot <udid>"; exit 1; }
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" site.portholehq.controlsharness 2>/dev/null || true
xcrun simctl launch "$UDID" site.portholehq.controlsharness "$@"
