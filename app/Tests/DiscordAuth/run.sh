#!/bin/bash
# Runs the cryptography of Discord's QR-code login (Sources/Discord/DiscordRemoteAuthCrypto.swift) on the Mac: the public key's encoding, decrypting what Discord would send,
# the nonce proof and the scanned person's details. It cannot test Discord's side; it tests that our half is self-consistent and shaped as the documentation says.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/discord-auth" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordRemoteAuthCrypto.swift"
"$OUT/discord-auth"
rm -rf "$OUT"
