#!/bin/bash
# Builds the PUBLIC package: the clean source tree and an IPA made with no maintainer identity, then audits both. Publishes nothing.
#
#   tools/release_public.sh [outdir]          default outdir: dist/public
#
# Produces in outdir:  source/ (one-commit copy for the public repository), Porthole-<version>-<build>.ipa (unsigned), its SHA-256, and RELEASE-NOTES.md.
# The IPA is built in a scratch copy of this tree without app/Config/Local.xcconfig and tools/local.env, so none of this machine's identity can get in.

# 1.4.0 (with the Discord features) is not released until the maintainer says so (docs/BRANCH-1.4.0.md).
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "1.4.0" ] && [ -z "$ALLOW_DISCORD_RELEASE" ]; then
  echo "✗ This is the 1.4.0 branch: it is not released, built for the public channel or promoted yet. See docs/BRANCH-1.4.0.md." >&2
  exit 1
fi
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/public}"
[ -f tools/local.env ] && . tools/local.env
F4_BUILD_ROOT="${F4_BUILD_ROOT:-$PWD/build}"

VERSION=$(grep -m1 -E '^[[:space:]]+MARKETING_VERSION:' app/project.yml | sed -E 's/.*: *"?([0-9.]+)"?.*/\1/')
BUILD=$(grep -m1 -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' app/project.yml | sed -E 's/.*: *"?([0-9]+)"?.*/\1/')
rm -rf "$OUT"; mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "▸ Porthole $VERSION ($BUILD), public build"
tools/engine.sh check
# The staged runtime must be the one this build folder holds (a stale stage ships an old engine without any other sign).
tools/check_stage.sh || exit 1

echo "▸ 1/4 the clean source tree"
tools/export_public.sh "$OUT/source" | tail -2

echo "▸ 2/4 building without this machine's identity"
mkdir -p "$WORK/tree"
rsync -a --exclude .git --exclude dist --exclude logs --exclude baseline --exclude build --exclude 'Factorio_*' \
  --exclude 'app/*.xcodeproj' --exclude vendor --exclude app/Config/Local.xcconfig --exclude tools/local.env ./ "$WORK/tree/"
ln -s "$PWD/vendor" "$WORK/tree/vendor"
# The public IPA is given the community server (the address is compiled in and shown nowhere in the app) but the public SOURCE never contains it: it is written into this scratch copy only,
# from PUBLIC_HUB_URL in tools/local.env (not committed). Nothing else of the maintainer's identity is added.
HUB_FOR_AUDIT=""
# The public build asks the Hub for its updates under its OWN name (a channel), not the maintainer's: the maintainer's day-to-day builds go to "porthole" and
# are never offered to the public. A release is put on the public channel by tools/promote_public.sh. Compatibility reports, key binds and problem
# reports do not use this name; they go to the Hub address, which is the same for both channels.
PUBLIC_CHANNEL="${PUBLIC_HUB_APP_ID:-porthole-stable}"
PRIVATE_CHANNEL=$(sed -n -E 's/^[[:space:]]*PORTHOLE_HUB_APP_ID[[:space:]]*=[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' app/Config/Local.xcconfig 2>/dev/null | tail -1)
PRIVATE_CHANNEL="${PRIVATE_CHANNEL:-porthole}"
echo "$PUBLIC_CHANNEL" | grep -qE '^[a-z0-9][a-z0-9-]{0,40}$' || { echo "✗ PUBLIC_HUB_APP_ID '$PUBLIC_CHANNEL' must be lowercase letters, digits and dashes"; exit 1; }
[ "$PUBLIC_CHANNEL" != "$PRIVATE_CHANNEL" ] || { echo "✗ the public update channel must differ from the maintainer's ('$PRIVATE_CHANNEL'): set PUBLIC_HUB_APP_ID in tools/local.env"; exit 1; }
RELEASE_KEY=""
if [ -n "${PUBLIC_HUB_URL:-}" ]; then
  to_xcconfig() { echo "$1" | sed 's#//#/$()/#'; }   # in an xcconfig "//" starts a comment
  { echo "// Written by tools/release_public.sh for this build only. Not part of the source."
    echo "PORTHOLE_HUB_URL = $(to_xcconfig "$PUBLIC_HUB_URL")"
    echo "PORTHOLE_HUB_APP_ID = $PUBLIC_CHANNEL"
    [ -n "${PUBLIC_SOURCE_URL:-}" ] && echo "PORTHOLE_SOURCE_URL = $(to_xcconfig "$PUBLIC_SOURCE_URL")"
    # The maintainer's release PUBLIC key (not secret): with it, the public build installs only updates signed by the matching private key.
    if [ -f "$HOME/.porthole/release-signing.key" ]; then RELEASE_KEY="$(swift tools/release_sign.swift public)"; echo "PORTHOLE_RELEASE_KEY = $RELEASE_KEY"; fi
    true; } > "$WORK/tree/app/Config/Local.xcconfig"
  HUB_FOR_AUDIT="$PUBLIC_HUB_URL"
  HOST="$(echo "$PUBLIC_HUB_URL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  if grep -rIl --exclude-dir=.git -F -- "$HOST" "$OUT/source" >/dev/null 2>&1; then echo "✗ the community server address is in the public source ($OUT/source)"; grep -rIl -F -- "$HOST" "$OUT/source" | head -3; exit 1; fi
  echo "   the community server is compiled into this IPA only; the public source does not contain it"
fi
( cd "$WORK/tree/app" && xcodegen generate >/dev/null )
xcodebuild -project "$WORK/tree/app/Porthole.xcodeproj" -scheme Porthole -configuration "${F4_CONFIGURATION:-Release}" -destination 'generic/platform=iOS' \
  -derivedDataPath "$WORK/DD" CODE_SIGNING_ALLOWED=NO build | tail -1

echo "▸ 3/4 packaging (strict: the builder's name must not remain anywhere)"
IPA="$OUT/Porthole-${VERSION}-${BUILD}.ipa"
SCRUB_ALLOW="tylerkaska112" SCRUB_STRICT=1 tools/package_app.sh "$WORK/DD/Build/Products/${F4_CONFIGURATION:-Release}-iphoneos/Porthole.app" "$IPA" | tail -2
( cd "$OUT" && shasum -a 256 "$(basename "$IPA")" > "$(basename "$IPA").sha256" )

echo "▸ 4/4 audit"
AUDIT_ALLOW_HUB="$HUB_FOR_AUDIT" AUDIT_ALLOW_SOURCE="${PUBLIC_SOURCE_URL:-}" AUDIT_EXPECT_APPID="${HUB_FOR_AUDIT:+$PUBLIC_CHANNEL}" AUDIT_EXPECT_RELEASE_KEY="$RELEASE_KEY" tools/audit_ipa.sh "$IPA"

NOTES="$(python3 - <<PY
import json
d=json.load(open("CHANGELOG.json"))
e=next((x for x in d if x["version"]=="$VERSION" and str(x["build"])=="$BUILD"), d[0])
print("## Porthole %s (%s)\n\n%s\n" % (e["version"], e["build"], e["summary"]))
for k,t in (("added","Added"),("changed","Changed"),("fixed","Fixed")):
    if e.get(k): print("### "+t); [print("- "+i) for i in e[k]]; print()
PY
)"
cat > "$OUT/RELEASE-NOTES.md" <<MD
$NOTES
### What this is
Porthole runs Windows games on iPhone and iPad using the Madeira runtime (Wine, FEX, DXMT). It is unofficial, not affiliated with Valve, Microsoft, Apple or any game publisher, and does not bypass any licence check. The IPA is **unsigned**: you sign and install it yourself (see the README). Source: see docs/SOURCE.md in the repository (the exact versions of everything it is built from are listed there).

Licence: GPL-3.0-or-later with an additional permission for the Apple Metal Shader Converter (LICENSE, LICENSE-EXCEPTION.md); third-party licences and credits are in the app under Settings > About > Licences.

SHA-256 of the IPA: \`$(cut -d' ' -f1 "$IPA.sha256")\`
MD
echo "▸ done: $OUT"
if [ -n "$HUB_FOR_AUDIT" ]; then echo "   update channel in this IPA: $PUBLIC_CHANNEL (on the Hub; put this IPA there with tools/promote_public.sh)"
else echo "   update channel in this IPA: none (no update server is built in)"; fi
ls -la "$OUT" | sed 's/^/   /'
