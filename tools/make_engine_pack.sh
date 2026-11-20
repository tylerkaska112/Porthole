#!/bin/bash
# Makes the ENGINE PACK: the built parts of Porthole that are not in git, in one file, so GitHub (or anyone without this Mac's build folder) can build the app:
#   RuntimeStage/   the staged runtime (Madeira's DLL farms and libraries + our rebuilt ones), links followed
#   DaveStage/      the Discord libraries (tools/build_dave.sh)
#   engine-headers/ vendor/Madeira's app/Madeira/*.h and build/*.h of the engine commit this checkout is pinned to (the shipped engine's headers) - the C glue includes them
# Left out on purpose: Microsoft's Visual C++ DLLs (the app downloads them), StikJIT (tools/prepare_stikjit.py fetches it), anything of the builder's.
# The machine's paths are scrubbed the same way package_app.sh scrubs an IPA, then the pack is checked against tools/public_banned.txt; it refuses to finish dirty.
#
#   tools/make_engine_pack.sh [outdir]      default outdir: dist/engine-pack     (reads app/RuntimeStage and app/DaveStage, so stage first: tools/stage_runtime.sh)
# Writes engine-pack-<engine id>.tar.gz, its .sha256 and a file list. It uploads nothing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
OUT="${1:-$HERE/dist/engine-pack}"
ENGINE_ID="$(sed -n 's/^PORTHOLE_ENGINE_ID *= *//p' "$HERE/app/Config/Engine.xcconfig" | tr -d '[:space:]')"
BASE="$(git -C "$HERE" ls-tree HEAD vendor/Madeira | awk '{print $3}')"      # the engine commit this checkout is pinned to
[ -n "$ENGINE_ID" ] && [ -n "$BASE" ] || { echo "✗ engine id or the vendor/Madeira pin missing"; exit 1; }
ENGINE_REPO="${ENGINE_REPO:-$(cd "$HERE/vendor/Madeira" && pwd -P)}"      # any clone that has the base commit
git -C "$ENGINE_REPO" cat-file -e "$BASE^{commit}" 2>/dev/null || { echo "✗ $ENGINE_REPO does not have the engine base commit $BASE (set ENGINE_REPO)"; exit 1; }
"$HERE/tools/check_stage.sh" >/dev/null || { echo "✗ the staged runtime does not belong to this checkout (tools/check_stage.sh)"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
P="$W/pack"; mkdir -p "$P/engine-headers/app/Madeira" "$P/engine-headers/build"
echo "▸ copying the staged runtime"
cp -RL "$HERE/app/RuntimeStage" "$P/RuntimeStage"
cp -RL "$HERE/app/DaveStage" "$P/DaveStage"
rm -f "$P"/RuntimeStage/Resources/x86_64-vcruntime/*.dll
find "$P" \( -name '._*' -o -name '.DS_Store' \) -delete
echo "▸ engine headers from $BASE"
# the top-level headers of app/Madeira and of build/ of the shipped engine, read straight from its commit (no sparse-checkout state, no 1 GB archive); the Build workflow lays them over vendor/Madeira
git -C "$ENGINE_REPO" ls-tree -r --name-only "$BASE" app/Madeira build | grep -E '^(app/Madeira|build)/[^/]+\.h$' | while read -r f; do git -C "$ENGINE_REPO" show "$BASE:$f" > "$P/engine-headers/$f"; done
find "$P/engine-headers" -type f ! -name '*.h' -delete; find "$P/engine-headers" -type d -empty -delete
echo "▸ scrubbing the builder's paths"
"$HERE/tools/scrub_paths.py" "$P" ${SCRUB_ALLOW:+--allow "$SCRUB_ALLOW"} --strict
echo "▸ checking for personal strings (tools/public_banned.txt)"
bad=0
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue; case "$pattern" in \#*) continue;; esac
  # third-party licence texts keep their authors' own copyright lines (names, addresses); they are not this project's (export_public.sh does the same)
  hits=$(grep -rlaE --exclude-dir=licenses --exclude-dir=legal -- "$pattern" "$P" 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "✗ /$pattern/ found in:"; echo "$hits" | sed "s|$P/|    |"; bad=1; fi
done < "$HERE/tools/public_banned.txt"
[ "$bad" = 0 ] || { echo "✗ the pack is not clean; nothing written"; exit 1; }
mkdir -p "$OUT"; FILE="$OUT/engine-pack-$ENGINE_ID.tar.gz"
( cd "$P" && find . \( -type f -o -type d -empty \) | sort | sed 's|^\./||' > "$OUT/engine-pack-$ENGINE_ID.files.txt" )
# a fixed order and no owner/time data, so the same inputs give the same file
( cd "$P" && tar --no-xattrs --uid 0 --gid 0 --uname '' --gname '' -cf - -T "$OUT/engine-pack-$ENGINE_ID.files.txt" ) | gzip -9n > "$FILE"
( cd "$OUT" && shasum -a 256 "$(basename "$FILE")" > "$(basename "$FILE").sha256" )
ls -l "$FILE"; cat "$FILE.sha256"
echo "✓ engine pack for engine $ENGINE_ID (headers of $BASE), $(wc -l < "$OUT/engine-pack-$ENGINE_ID.files.txt" | tr -d ' ') files"
