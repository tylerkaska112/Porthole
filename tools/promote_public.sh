#!/bin/bash
# Puts a built PUBLIC IPA on the public update channel of the Hub, signed, so installs of the public build are offered it as an update.
#
#   tools/promote_public.sh [--hub-hosted] [--skip-check] [path/to/Porthole-<version>-<build>.ipa]      default: the newest IPA in dist/public
#   HUB_DATA=/tmp/scratch-hub tools/promote_public.sh ...                 publishes to a scratch folder instead (use this to test)
#
# Where installs download the IPA from: its GitHub release asset (PUBLIC_SOURCE_URL/releases/download/v<version>/<file>), so the Hub only serves the small
# update files and none of its bandwidth. The asset must already be uploaded; unless --skip-check, it is downloaded here and compared with the IPA first,
# because a wrong address would strand every install. --hub-hosted serves the IPA from the Hub instead.
#
# The IPA must be the one tools/release_public.sh built (the same file that is uploaded to GitHub), so the checksum on the Hub is the checksum on GitHub.
# The channel is PUBLIC_HUB_APP_ID from tools/local.env (default "porthole-stable"); it is NOT the maintainer's own channel, which tools/release.sh publishes
# to. Publishing is state-changing: it writes into the Hub's data folder, and every public install can see the build the moment it is there.

# 1.4.0 (with the Discord features) is not released until the maintainer says so (docs/BRANCH-1.4.0.md).
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "1.4.0" ] && [ -z "$ALLOW_DISCORD_RELEASE" ]; then
  echo "✗ This is the 1.4.0 branch: it is not released, built for the public channel or promoted yet. See docs/BRANCH-1.4.0.md." >&2
  exit 1
fi
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f tools/local.env ] && . tools/local.env
CHANNEL="${PUBLIC_HUB_APP_ID:-porthole-stable}"
DATA="${HUB_DATA:-$HOME/launcher-data}"
PUBLISH="${HUB_PUBLISH:-}"
HUB_HOSTED=0; SKIP_CHECK=0; ARGS=()
for a in "$@"; do case "$a" in --hub-hosted) HUB_HOSTED=1 ;; --skip-check) SKIP_CHECK=1 ;; *) ARGS+=("$a") ;; esac; done
IPA="${ARGS[0]:-$(ls -t dist/public/Porthole-*.ipa 2>/dev/null | head -1)}"

[ -n "$IPA" ] && [ -f "$IPA" ] || { echo "✗ no public IPA given and none in dist/public (run tools/release_public.sh first)"; exit 1; }
[ -f "$PUBLISH" ] || { echo "✗ set HUB_PUBLISH (in tools/local.env) to your Hub's publish.py; not found: '$PUBLISH'"; exit 1; }
echo "$CHANNEL" | grep -qE '^[a-z0-9][a-z0-9-]{0,40}$' || { echo "✗ channel '$CHANNEL' must be lowercase letters, digits and dashes"; exit 1; }
[ -f "$HOME/.porthole/release-signing.key" ] || { echo "✗ no release signing key (~/.porthole/release-signing.key): public installs would refuse an unsigned update"; exit 1; }

# What the IPA says it is, and what the build asks for: the channel and the key must be the ones this IPA was built with.
read -r VERSION BUILD CHAN KEY < <(python3 - "$IPA" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
    i = plistlib.loads(z.read(name))
print(i.get("CFBundleShortVersionString", "0"), i.get("CFBundleVersion", "0"), i.get("PortholeHubAppID") or "-", i.get("PortholeReleaseKey") or "-")
PY
)
[ "$CHAN" = "$CHANNEL" ] || { echo "✗ this IPA asks the Hub for '$CHAN', not '$CHANNEL': publishing it there would strand its installs. Rebuild with tools/release_public.sh."; exit 1; }
[ "$KEY" = "$(swift tools/release_sign.swift public)" ] || { echo "✗ this IPA does not carry the current release public key; installs would refuse its updates"; exit 1; }
[ ! -f "$DATA/updates/$CHANNEL/Porthole-${VERSION}-${BUILD}.ipa" ] || { echo "✗ build $BUILD ($VERSION) is already on channel '$CHANNEL' in $DATA"; exit 1; }
python3 - "$BUILD" <<'PY' || { echo "✗ CHANGELOG.json has no entry for build $BUILD"; exit 1; }
import json, sys
sys.exit(0 if any(str(e.get("build")) == sys.argv[1] for e in json.load(open("CHANGELOG.json"))) else 1)
PY

SHA=$(shasum -a 256 "$IPA" | cut -d' ' -f1)
DOWNLOAD_URL=""
if [ "$HUB_HOSTED" = 0 ]; then
  [ -n "${PUBLIC_SOURCE_URL:-}" ] || { echo "✗ PUBLIC_SOURCE_URL (tools/local.env) is not set, so the GitHub address of the IPA is unknown; use --hub-hosted to serve it from the Hub"; exit 1; }
  DOWNLOAD_URL="${PUBLIC_SOURCE_URL%/}/releases/download/v${VERSION}/$(basename "$IPA")"
  if [ "$SKIP_CHECK" = 0 ]; then
    echo "▸ Checking that $DOWNLOAD_URL serves this exact file"
    GOT=$(curl -fsSL --max-time 900 "$DOWNLOAD_URL" 2>/dev/null | shasum -a 256 | cut -d' ' -f1) || GOT=""
    [ "$GOT" = "$SHA" ] || { echo "✗ that address does not serve this IPA yet (got '${GOT:0:12}', wanted '${SHA:0:12}'). Upload $(basename "$IPA") to the GitHub release v${VERSION} first."; exit 1; }
    echo "  ✓ the GitHub release asset is this IPA"
  fi
fi
SIGNATURE=$(swift tools/release_sign.swift sign "$CHANNEL" "$VERSION" "$BUILD" "$SHA")
swift tools/release_sign.swift verify "$CHANNEL" "$VERSION" "$BUILD" "$SHA" "$SIGNATURE" || { echo "✗ the signature does not verify"; exit 1; }
SUMMARY=$(python3 - "$BUILD" <<'PY'
import json, sys
print(next(e["summary"] for e in json.load(open("CHANGELOG.json")) if str(e.get("build")) == sys.argv[1]))
PY
)
echo "▸ Putting $VERSION ($BUILD) on channel '$CHANNEL' in $DATA"
python3 "$PUBLISH" "$IPA" --app "$CHANNEL" --name "Porthole" --notes "$SUMMARY" --changelog CHANGELOG.json --data "$DATA" --signature "$SIGNATURE" ${DOWNLOAD_URL:+--download-url "$DOWNLOAD_URL"}

# Read back what the Hub will serve.
python3 - "$DATA/updates/$CHANNEL" "$VERSION" "$BUILD" "$SHA" "$SIGNATURE" "$DOWNLOAD_URL" <<'PY'
import json, os, sys
folder, version, build, sha, sig, url = sys.argv[1:]
latest = json.load(open(os.path.join(folder, "latest.json")))
assert latest["version"] == version and str(latest["build"]) == build, "latest.json is not this build"
assert latest["sha256"] == sha, "latest.json checksum differs from the IPA"
assert latest.get("signature") == sig, "latest.json has no signature for this build"
if url:
    assert latest.get("downloadUrl") == url, "latest.json does not point at the GitHub asset"
print("✓ latest.json: %s (%s), checksum and signature match the IPA%s" % (version, build, "; downloads come from GitHub" if url else "; downloads come from the Hub"))
PY
echo "▸ done. The IPA to upload to GitHub is the same file: $IPA"
echo "   SHA-256: $SHA"
echo "   Next: tools/finish_release.sh   (brings main and prerelease up to this release's commit and tags it)"
