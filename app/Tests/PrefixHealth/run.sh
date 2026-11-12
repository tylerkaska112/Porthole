#!/bin/bash
# Compiles PrefixHealth's parser with its test (the app-only parts are stubbed) and runs it.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d)
cat > "$W/stub.swift" <<'STUB'
import Foundation
enum AppModel { static var prefix: URL { URL(fileURLWithPath: "/nonexistent") } }
STUB
cp "$HERE/main.swift" "$W/main.swift"
swiftc -o "$W/t" "$W/stub.swift" "$HERE/../../Sources/Core/PrefixHealth.swift" "$W/main.swift" 2>&1
"$W/t"
