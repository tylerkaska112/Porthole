#!/bin/bash
# Build an unsigned IPA and publish it to your own Hub, so the app can update itself. (Maintainer tooling: a public build does not need it.)
#
#   tools/release.sh --notes "What changed"             # publishes to the REAL Hub data folder ($HUB_DATA, default ~/launcher-data)
#   HUB_DATA=/tmp/scratch-hub tools/release.sh ...      # publishes to a scratch folder instead (use this to test)
#
# Before running: bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in app/project.yml and add a CHANGELOG.json entry for that build.
# Builds the Release configuration. F4_CONFIGURATION=Debug builds Debug instead (tried on devices for much longer; see docs/ENGINE.md).
# Fails fast, BEFORE the build, if the build is already published or has no changelog entry. Publishing is state-changing: it writes into the Hub's folder.

set -euo pipefail
cd "$(dirname "$0")/.."
# This machine's paths (F4_BUILD_ROOT, HUB_PUBLISH, ...) live in tools/local.env, which is not committed.
[ -f tools/local.env ] && . tools/local.env
F4_BUILD_ROOT="${F4_BUILD_ROOT:-$PWD/build}"

NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

VERSION=$(grep -m1 -E '^[[:space:]]+MARKETING_VERSION:' app/project.yml | sed -E 's/.*: *"?([0-9.]+)"?.*/\1/')
BUILD=$(grep -m1 -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' app/project.yml | sed -E 's/.*: *"?([0-9]+)"?.*/\1/')
DATA="${HUB_DATA:-$HOME/launcher-data}"
PUBLISH="${HUB_PUBLISH:-}"
# The name this build has on the Hub: PORTHOLE_HUB_APP_ID from your Local.xcconfig (it must match what the installed app asks for), else "porthole".
APPID=$(sed -n -E 's/^[[:space:]]*PORTHOLE_HUB_APP_ID[[:space:]]*=[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' app/Config/Local.xcconfig 2>/dev/null | tail -1)
APPID="${APPID:-porthole}"
# The public channel is promote_public.sh's: a private build never goes there. A build for the old Discord test channel keeps its label and tag; everything else is a normal private build.
[ "$APPID" != "porthole-stable" ] || { echo "✗ 'porthole-stable' is the public channel: tools/promote_public.sh owns it, not release.sh." >&2; exit 1; }
if [ "$APPID" = "porthole-discord" ]; then
  HUB_NAME="Porthole (Discord test)"; TAG_NAME="discord-${BUILD}"
else
  HUB_NAME="Porthole"; TAG_NAME="v${VERSION}"
fi
IPA="dist/Porthole-${VERSION}-${BUILD}-unsigned.ipa"

[ -f "$PUBLISH" ] || { echo "✗ set HUB_PUBLISH (in tools/local.env) to your Hub's publish.py; not found: '$PUBLISH'"; exit 1; }
[ ! -f "$DATA/updates/$APPID/Porthole-${VERSION}-${BUILD}.ipa" ] \
  || { echo "✗ build $BUILD ($VERSION) is already published to $DATA. Bump CURRENT_PROJECT_VERSION first."; exit 1; }
python3 - "$BUILD" <<'PY' || { echo "✗ CHANGELOG.json has no entry for build $BUILD. Add one first."; exit 1; }
import json, sys
sys.exit(0 if any(str(e.get("build")) == sys.argv[1] for e in json.load(open("CHANGELOG.json"))) else 1)
PY

# The engine record must match the source (a changed Madeira pin, patch or runtime needs `tools/engine.sh bump`), or the badges would be wrong.
tools/engine.sh check || exit 1
# The staged runtime must be the one this build folder holds (a stale stage ships an old engine without any other sign).
tools/check_stage.sh || exit 1

echo "▸ Releasing $VERSION ($BUILD) to $DATA"
( cd app && xcodegen generate >/dev/null )
xcodebuild -project app/Porthole.xcodeproj -scheme Porthole -configuration "${F4_CONFIGURATION:-Release}" -destination 'generic/platform=iOS' \
  -derivedDataPath "${F4_DERIVED:-$F4_BUILD_ROOT/DD-head}" CODE_SIGNING_ALLOWED=NO build | tail -1
mkdir -p dist
tools/package_app.sh "${F4_DERIVED:-$F4_BUILD_ROOT/DD-head}/Build/Products/${F4_CONFIGURATION:-Release}-iphoneos/Porthole.app" "$IPA"
# Sign the release (Ed25519, key in ~/.porthole, never in the repository). Installs that carry the matching public key refuse an update without a valid signature.
SIGNATURE=""
if [ -f "$HOME/.porthole/release-signing.key" ]; then
  SHA=$(shasum -a 256 "$IPA" | cut -d' ' -f1)
  SIGNATURE=$(swift tools/release_sign.swift sign "$APPID" "$VERSION" "$BUILD" "$SHA") || { echo "✗ signing the release failed"; exit 1; }
  swift tools/release_sign.swift verify "$APPID" "$VERSION" "$BUILD" "$SHA" "$SIGNATURE" || { echo "✗ the release signature does not verify"; exit 1; }
  echo "▸ release signed"
else
  echo "⚠ no release signing key (~/.porthole/release-signing.key): publishing unsigned. Installs that carry the release key will refuse this update."
fi
python3 "$PUBLISH" "$IPA" --app "$APPID" --name "$HUB_NAME" --notes "${NOTES:-Build $BUILD}" --changelog CHANGELOG.json --data "$DATA" ${SIGNATURE:+--signature "$SIGNATURE"}
for old in dist/Porthole-*-unsigned.ipa; do [ "$old" = "$IPA" ] || rm -f "$old"; done
echo "▸ done"

# Mark this exact source state so any release can be restored later:  git checkout v<version>
if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null 2>&1; then
  echo "▸ tag ${TAG_NAME} already exists (not moved)"
else
  git tag -a "${TAG_NAME}" -m "Release ${VERSION} (build ${BUILD})" 2>/dev/null && echo "▸ tagged ${TAG_NAME}" || true
fi
