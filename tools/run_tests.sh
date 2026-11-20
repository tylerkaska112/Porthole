#!/bin/bash
# Runs every host test: the swiftc test scripts in app/Tests/*/run.sh and the LauncherCore package tests. They need no device, no engine and no network
# (STEAM_LIVE stays off). Used by the GitHub workflow and by anyone before opening a pull request.
#   tools/run_tests.sh            all of them
#   tools/run_tests.sh Nav Steam  only these app/Tests folders
set -u
cd "$(dirname "$0")/.."
fail=0; ran=0; skipped=0; failed=()
if [ "$#" -gt 0 ]; then names=("$@"); else names=(); for d in app/Tests/*/; do [ -f "$d/run.sh" ] && names+=("$(basename "$d")"); done; fi
for n in "${names[@]}"; do
  [ -f "app/Tests/$n/run.sh" ] || { echo "no such test: $n"; fail=1; continue; }
  ran=$((ran + 1)); start=$(date +%s)
  if out=$(bash "app/Tests/$n/run.sh" 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 77 ]; then skipped=$((skipped + 1)); echo "– $n skipped ($(printf '%s\n' "$out" | grep -m1 '^SKIP' | sed 's/^SKIP: *//'))"; continue; fi
  # A test prints "FAIL:" for a failed check even when the script itself exits 0.
  if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -q '^FAIL'; then
    echo "✗ $n ($(( $(date +%s) - start )) s)"; printf '%s\n' "$out" | grep -E '^FAIL|error' | head -20 | sed 's/^/    /'; failed+=("$n"); fail=1
  else echo "✓ $n ($(( $(date +%s) - start )) s)"; fi
done
if [ "$#" -eq 0 ]; then
  echo "▸ LauncherCore"; ( cd Packages/LauncherCore && swift test 2>&1 | tail -5 ) || { fail=1; failed+=(LauncherCore); }
fi
echo; echo "$ran test folders, $skipped skipped, ${#failed[@]} failed${failed:+: ${failed[*]}}"
exit $fail
