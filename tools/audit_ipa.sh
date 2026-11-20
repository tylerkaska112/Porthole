#!/bin/bash
# Checks a built IPA for anything that must not be in a public build: the builder's identity, personal servers, Microsoft's DLLs, wrong bundle ids.
#   tools/audit_ipa.sh <file.ipa> [--private]      (--private: the maintainer's own build; its bundle id and server are expected)
# Exit status 1 on any finding.
set -uo pipefail
IPA="$1"; MODE="${2:-public}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
unzip -q "$IPA" -d "$W" || { echo "✗ cannot unpack $IPA"; exit 1; }
APP="$(ls -d "$W"/Payload/*.app | head -1)"
BAD=0
fail() { echo "✗ $*"; BAD=1; }
ok() { echo "✓ $*"; }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
BUNDLE="$(plist "$APP/Info.plist" CFBundleIdentifier)"
echo "▸ $(basename "$IPA"): $BUNDLE, version $(plist "$APP/Info.plist" CFBundleShortVersionString) ($(plist "$APP/Info.plist" CFBundleVersion))"

if [ "$MODE" = "--private" ]; then
  ok "private build: identity checks skipped"
else
  [ "$BUNDLE" = "site.portholehq.app" ] && ok "bundle id is the neutral one" || fail "bundle id is '$BUNDLE', expected site.portholehq.app"
  for key in PortholeHubURL PortholeKeychainService PortholeStorageFolder PortholeSourceURL; do
    value="$(plist "$APP/Info.plist" "$key")"
    # A public build may carry the community server (AUDIT_ALLOW_HUB, set by tools/release_public.sh): exactly that address, in exactly that one place.
    if [ "$key" = PortholeHubURL ] && [ -n "${AUDIT_ALLOW_HUB:-}" ]; then
      [ "$value" = "$AUDIT_ALLOW_HUB" ] && ok "PortholeHubURL is the community server (compiled in, as intended)" || fail "PortholeHubURL is '$value', expected the community server"
    elif [ "$key" = PortholeSourceURL ] && [ -n "$value" ] && [ -n "${AUDIT_ALLOW_SOURCE:-}" ] && [ "$value" = "$AUDIT_ALLOW_SOURCE" ]; then ok "PortholeSourceURL is the public repository"
    else [ -z "$value" ] && ok "$key is empty" || fail "$key is '$value'"; fi
  done
  for ext in "$APP"/PlugIns/*.appex "$APP"/Frameworks/*.framework; do
    id="$(plist "$ext/Info.plist" CFBundleIdentifier)"
    case "$id" in site.portholehq.*|app.porthole.vendor.*) ;; *) fail "$(basename "$ext") has bundle id '$id'";; esac   # app.porthole.vendor.*: third-party frameworks given a neutral id (StikJIT)
  done
fi

# The update channel the build asks the Hub for, and the maintainer's release public key (set by tools/release_public.sh when it built them in).
if [ -n "${AUDIT_EXPECT_APPID:-}" ]; then
  v="$(plist "$APP/Info.plist" PortholeHubAppID)"
  [ "$v" = "$AUDIT_EXPECT_APPID" ] && ok "update channel is '$v' (compatibility reports and key binds do not depend on it)" || fail "update channel is '$v', expected '$AUDIT_EXPECT_APPID'"
fi
if [ -n "${AUDIT_EXPECT_RELEASE_KEY:-}" ]; then
  v="$(plist "$APP/Info.plist" PortholeReleaseKey)"
  [ "$v" = "$AUDIT_EXPECT_RELEASE_KEY" ] && ok "the release signing key is built in: updates must be signed by the maintainer" || fail "PortholeReleaseKey is '$v', expected the maintainer's public key"
fi

# Microsoft's runtime is downloaded by the app, never shipped.
DLLS="$(find "$APP" -ipath '*x86_64-vcruntime*' -name '*.dll' | wc -l | tr -d ' ')"
[ "$DLLS" = 0 ] && ok "no Microsoft Visual C++ DLLs inside" || fail "$DLLS Microsoft Visual C++ DLL(s) inside"

# Anything of the builder's, anywhere in any file (binary or text). In a private build the maintainer's own bundle id / server are allowed.
# Short generic words and whole mail domains match innocent text in binaries and third-party licences; the specific names are what matter.
# The list of names is the maintainer's own and is not in the public source (export_public.sh leaves it out): without it this check is skipped, and says so.
BANNED_LIST="$HERE/tools/public_banned.txt"; [ -f "$BANNED_LIST" ] || { echo "– name check skipped (no tools/public_banned.txt in this source)"; BANNED_LIST=/dev/null; }
PATTERNS="$(grep -v -E '^\s*(#|$)' "$BANNED_LIST" | grep -v -E '^@' | awk 'length($0) >= 8')"
HITS=0
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  files="$(grep -rlaE -- "$pattern" "$APP" 2>/dev/null || true)"
  if [ -n "$files" ] && [ "$MODE" = "--private" ]; then files="$(echo "$files" | grep -v -E 'Info.plist$' || true)"; fi
  # The community server's own address is allowed to match (and only that: a match with anything else around it still fails).
  if [ -n "$files" ] && [ -n "${AUDIT_ALLOW_HUB:-}" ]; then
    kept=""
    for f in $files; do
      if grep -aoE ".{0,80}($pattern).{0,80}" "$f" 2>/dev/null | grep -avF -- "$AUDIT_ALLOW_HUB" | grep -aqE -- "$pattern"; then kept="$kept $f"; fi
    done
    files="$(echo $kept | tr ' ' '\n' | grep -v '^$' || true)"
  fi
  if [ -n "$files" ]; then fail "'$pattern' found in: $(echo "$files" | sed "s|$APP/||" | head -3 | tr '\n' ' ')"; HITS=1; fi
done <<< "$PATTERNS"
[ "$HITS" = 0 ] && [ "$BANNED_LIST" != /dev/null ] && ok "none of the maintainer's names, servers or paths appear in any file"

[ "$BAD" = 0 ] && echo "▸ clean" || echo "▸ NOT clean"
exit "$BAD"
