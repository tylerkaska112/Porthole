#!/bin/bash
# Compiles LogCleaner with its checks (what is taken out of a log, what stays) and runs them.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d)
cp "$HERE/main.swift" "$W/main.swift"
swiftc -O -o "$W/t" "$HERE/../../Sources/Core/LogCleaner.swift" "$W/main.swift" 2>&1
"$W/t"
