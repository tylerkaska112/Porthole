#!/bin/bash
# Builds the UI kit and its preview screens into a small app for the iOS simulator, installs it on the booted simulator(s) and launches it.
#   app/Tests/UIPreview/build.sh                 build + install on every booted simulator
#   app/Tests/UIPreview/build.sh shot <name> [-- app args]    launch with --screen <name> and save <name>-<device>.png in $OUT (default /tmp/claude-501/uishots)
# Needs no runtime, no signing and no device: only SwiftUI files without app dependencies (Sources/UI/Kit + Preview/).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE/../../Sources/UI/Kit"
OUT="${OUT:-/tmp/claude-501/uishots}"; mkdir -p "$OUT"
BUILD="${BUILD:-/tmp/claude-501/uipreview-build}"; APP="$BUILD/Preview.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# ORIENT=landscape (default) or portrait: the orientations the preview app allows, which decides how it launches.
if [ "${ORIENT:-landscape}" = "portrait" ]; then
  ORIENTS='<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array><key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string></array>'
else
  ORIENTS='<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeRight</string></array><key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationLandscapeRight</string></array>'
fi
if [ "${1:-}" != "shot" ]; then
  rm -rf "$BUILD"; mkdir -p "$APP"
  swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
    -module-name Preview -o "$APP/Preview" "$KIT"/*.swift "$HERE/../../Sources/Core/ControllerKind.swift" "$HERE/../../Sources/Core/ControllerKindDetect.swift" "$HERE/../../Sources/Compat/CompatBadges.swift" "$HERE/../../Sources/Compat/ReportsLogic.swift" "$HERE/../../Sources/Compat/CompatViews.swift" "$HERE"/../../Sources/UI/Reports/ReportsParts.swift "$HERE"/../../Sources/UI/Reports/ReportsLayouts.swift "$HERE"/Preview/*.swift
  for n in Steam Epic Gog Itch Amazon; do cp "$HERE/../../Assets.xcassets/Store$n.imageset/Store$n.png" "$APP/Store$n.png"; done   # the store logos (an asset catalog in the real app)
  cp "$HERE/../../Assets.xcassets/PortholeMark.imageset/PortholeMark.png" "$APP/PortholeMark.png"   # the top bar's porthole (an asset catalog in the real app)
  cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Preview</string><key>CFBundleIdentifier</key><string>site.portholehq.uipreview</string>
<key>CFBundleName</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1</string>
<key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>18.0</string><key>UILaunchScreen</key><dict/>
<key>UIRequiresFullScreen</key><true/>
$ORIENTS
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
  for udid in $(xcrun simctl list devices booted | grep -o '[0-9A-F-]\{36\}'); do xcrun simctl install "$udid" "$APP"; echo "installed on $udid"; done
  exit 0
fi
name="$2"; shift 2; [ "${1:-}" = "--" ] && shift
for udid in $(xcrun simctl list devices booted | grep "${ONLY:-}" | grep -o "[0-9A-F-]\{36\}"); do
  dev="$(xcrun simctl list devices | grep "$udid" | sed -E 's/^ *([^()]*[^ (]) .*/\1/' | tr ' ' '_' | tr -d '()')"
  xcrun simctl terminate "$udid" site.portholehq.uipreview >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" site.portholehq.uipreview --screen "$name" "$@" >/dev/null
  sleep "${WAIT:-3}"
  xcrun simctl io "$udid" screenshot "$OUT/$name-$dev.png" >/dev/null 2>&1 && echo "$OUT/$name-$dev.png"
done
