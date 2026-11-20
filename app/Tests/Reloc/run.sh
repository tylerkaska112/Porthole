#!/bin/bash
# Host test for patch 0020's relocation block index. usage: app/Tests/Reloc/run.sh
set -eu
cd "$(dirname "$0")"
# This test compiles a header from the engine sources, which GitHub does not have (only the engine pack): skipped there (exit 77).
[ -f ../../../vendor/Madeira/build/ntdll-unix/ios_reloc_index.h ] || { echo "SKIP: needs the engine sources (vendor/Madeira)"; exit 77; }
OUT=$(mktemp -d)
cc -O2 -Wall -o "$OUT/t" reloc_index_test.c
"$OUT/t"
