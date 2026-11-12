#!/bin/bash
# Compiles LogThinner with its test and runs it. LOG_THINNER_FILE=<a real log> also prints how much of it is kept and how long it takes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d)
cp "$HERE/main.swift" "$W/main.swift"
swiftc -O -o "$W/t" "$HERE/../../Sources/Core/LogThinner.swift" "$W/main.swift" 2>&1
"$W/t"
