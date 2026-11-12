#!/bin/bash
# Self-test of the on-device pairing code on the Mac: codecs, SRP-3072 against an independent Python client, and a whole pairing
# conversation between the host and a fake iPhone over loopback. Nothing here talks to a real device.
#   app/Tests/Pairing/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../../Sources/Pairing"
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/pairing-tests" "$SRC/ModularArithmetic.swift" "$SRC/PairingCodecs.swift" "$SRC/SRP3072.swift" "$SRC/RemotePairingHost.swift" "$HERE/../../Sources/Core/ErrorText.swift" "$HERE/../../Sources/Shared/JITMessages.swift" "$HERE/main.swift" 2>&1 | grep -E "error" || true
"$OUT/pairing-tests" "$HERE"
