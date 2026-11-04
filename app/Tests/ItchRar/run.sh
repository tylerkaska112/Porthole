#!/bin/bash
# Host test for the .rar reader (Sources/Itch/itch_rar.c): builds small stored RAR 4 and RAR 5 archives and checks the items and their data come out of the system libarchive.
# Compressed archives are Apple's code and are not covered. usage: app/Tests/ItchRar/run.sh
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp -d)
python3 mk.py >/dev/null && mv stored4.rar stored5.rar "$OUT/"
cc -I../../Sources/Itch -o "$OUT/t" t.c ../../Sources/Itch/itch_rar.c
RESULT=$("$OUT/t" "$OUT/stored5.rar" "$OUT/stored4.rar" /etc/hosts)
fail=0
check() { if echo "$RESULT" | grep -qF -- "$1"; then echo "ok    $2"; else echo "FAIL  $2"; fail=1; fi; }
[ "$(echo "$RESULT" | grep -c 'extract status=0')" = 2 ] && echo "ok    both archives unpack" || { echo "FAIL  both archives unpack"; fail=1; }
check "#1 Game/game.exe flags=0 size=304" "a file is listed with its size"
check "#0 Game flags=1" "a folder is flagged as a folder"
check "end #3 read=500" "a file's data is read in full"
check "#4 Game/empty.bin flags=0 size=0" "an empty file is listed"
check "/etc/hosts is_rar=0" "a file that is not a RAR is refused"
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
