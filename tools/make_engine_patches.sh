#!/bin/bash
# Writes the engine source patches for the PUBLIC repository: for each of the five engine repositories, everything that differs between the upstream commit the public
# source pins (docs/SOURCE.md, "Pinned upstream commits") and the commit the shipped engine was built from, as a patch that applies to the pinned commit.
# The engine repository's own host tests (tests/) are left out: they build nothing, and their sample data is somebody else's. Binary files are not patched: their SHA-256 goes in a list (they are rebuilt from the sources, see docs/REBUILD.md).
#
#   tools/make_engine_patches.sh <number> <name> [engine repo]       e.g.  tools/make_engine_patches.sh 0204 engine-1.4.0
#
# Writes patches/<number>-<name>-{madeira,fex,wine,dxmt,madeira-dock}.patch and patches/<number>-<name>-binaries.sha256, then checks each patch the way a reader would:
# it applies to the pinned commit with nothing left over, and the result is the shipped tree (every text file). It changes nothing in the engine repositories.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NUM="${1:?patch number, e.g. 0204}"; NAME="${2:?name, e.g. engine-1.4.0}"
ENGINE="${3:-$(cd "$HERE/vendor/Madeira" && pwd -P)}"
# the pinned upstream commits, as recorded in docs/SOURCE.md
pin() { grep -E "^\| $1 " "$HERE/docs/SOURCE.md" | grep -oE '`[0-9a-f]{40}`' | head -1 | tr -d '`'; }
BASE_MADEIRA="$(sed -n '1p' "$HERE/docs/ENGINE_BASE" | tr -d '[:space:]')"
BASE_WINE="$(pin 'Wine \(LGPL branch\)')"; BASE_FEX="$(pin FEX)"; BASE_DXMT="$(pin DXMT)"; BASE_DOCK="$(pin 'Madeira Dock')"
for v in BASE_MADEIRA BASE_WINE BASE_FEX BASE_DXMT BASE_DOCK; do [ -n "${!v}" ] || { echo "✗ $v not found (docs/SOURCE.md, docs/ENGINE_BASE)"; exit 1; }; done
OUT="$HERE/patches"; BIN="$OUT/$NUM-$NAME-binaries.sha256"; : > "$BIN"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

one() { # <repo path relative to the engine> <patch suffix> <base commit> <paths to leave out, space separated>
  local rel="$1" suffix="$2" base="$3" skip="$4" repo="$ENGINE/$1" head
  head="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" cat-file -e "$base^{commit}" || { echo "✗ $repo does not have $base"; exit 1; }
  # files that differ, split into text (patched) and binary (listed). Submodule links, symlinks and the paths in $skip are left out.
  git -C "$repo" diff --raw --no-renames "$base" "$head" > "$W/raw"
  : > "$W/text"; : > "$W/bin"
  while IFS=$'\t' read -r meta path; do
    set -- $meta; local oldmode="${1#:}" newmode="$2" status="${5}"
    [ "$oldmode" = 160000 ] || [ "$newmode" = 160000 ] && continue                    # submodule link
    [ "$oldmode" = 120000 ] || [ "$newmode" = 120000 ] && continue                    # symlink (a build folder link)
    for s in $skip; do case "$path" in $s|$s/*) continue 2;; esac; done
    case "$path" in "app/Madeira/"*.a|*.dll|*.exe|*.dylib|*.png|*.jpg|*.ico|*.bin|*.gz|*.zip|*.nls|*.ttf|*.otf) echo "$status $path" >> "$W/bin"; continue;; esac
    echo "$path" >> "$W/text"
  done < "$W/raw"
  # anything git itself calls binary joins the list too
  git -C "$repo" diff --numstat --no-renames "$base" "$head" | awk '$1=="-" {print $3}' | while read -r p; do
    if grep -qxF "$p" "$W/text"; then grep -vxF "$p" "$W/text" > "$W/text.n" || true; mv "$W/text.n" "$W/text"; echo "M $p" >> "$W/bin"; fi
  done
  : > "$W/patch"
  [ -s "$W/text" ] && git -C "$repo" diff --no-renames --no-color "$base" "$head" -- $(tr '\n' ' ' < "$W/text") > "$W/patch"
  cp "$W/patch" "$OUT/$NUM-$NAME-$suffix.patch"
  while read -r st p; do [ "$st" = D ] && continue; printf '%s  %s/%s\n' "$(git -C "$repo" show "$head:$p" | shasum -a 256 | cut -d' ' -f1)" "$rel" "$p" >> "$BIN"; done < "$W/bin"
  # check: apply to the pinned commit in a scratch index, compare every text file with the shipped tree
  export GIT_INDEX_FILE="$W/index-$suffix"; rm -f "$GIT_INDEX_FILE"
  git -C "$repo" read-tree "$base"
  if [ -s "$W/patch" ]; then git -C "$repo" apply --cached --whitespace=nowarn "$OUT/$NUM-$NAME-$suffix.patch"; fi
  local bad=0
  while read -r p; do
    a="$(git -C "$repo" ls-files -s -- "$p" | awk '{print $2}')"; b="$(git -C "$repo" rev-parse "$head:$p" 2>/dev/null || true)"
    [ "$a" = "$b" ] || { echo "   ✗ $p differs after applying"; bad=$((bad+1)); }
  done < "$W/text"
  unset GIT_INDEX_FILE
  [ "$bad" = 0 ] || { echo "✗ $suffix: $bad file(s) do not match the shipped tree"; exit 1; }
  echo "✓ $suffix: $(wc -l < "$W/text" | tr -d ' ') text file(s) patched, $(wc -l < "$W/bin" | tr -d ' ') binary file(s) listed ($(wc -c < "$W/patch" | tr -d ' ') bytes, $base..${head:0:8})"
}

one .            madeira       "$BASE_MADEIRA" "FEX wine dxmt madeira-dock research toolchains tests"
one FEX          fex           "$BASE_FEX"     ""
one wine         wine          "$BASE_WINE"    ""
one dxmt         dxmt          "$BASE_DXMT"    "build-arm64ec build-arm64ec-r27 build-arm64ec-r28 build-arm64ec-r29 build-arm64ec-140 build-arm64ec-nl"
one madeira-dock madeira-dock  "$BASE_DOCK"    ""
sort -k2 -o "$BIN" "$BIN"
echo "✓ patches/$NUM-$NAME-*.patch and $NUM-$NAME-binaries.sha256 ($(wc -l < "$BIN" | tr -d ' ') binary files)"
