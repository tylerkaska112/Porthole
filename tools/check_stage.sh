#!/bin/bash
# Fails when the staged runtime (app/RuntimeStage, which is NOT in git) was made from somewhere other than the checkout and build folder this build uses.
#
#   tools/check_stage.sh        (F4_BUILD_ROOT from tools/local.env or the environment, as for the release scripts)
#
# Why: the engine's binaries are not in git. Each working copy has its own staged runtime whose libraries and DLLs are links into a build folder. A copy staged
# before an engine merge (or against another build folder) still builds, and ships the OLD engine: the 1.0.0 public IPA was built that way and lacked the
# 0.50.376-0.50.383 engine fixes (Factorio through Steam: "no package core"), although the branch and the version were right. tools/engine.sh only checks the source record.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
ROOT="${F4_BUILD_ROOT:-$HERE/build}"
[ -d "$HERE/app/RuntimeStage" ] || { echo "✗ no staged runtime (app/RuntimeStage): run tools/stage_runtime.sh"; exit 1; }
bad=0
# app/RuntimeStage is itself usually a link into the build folder; then check where it points, and look inside it too.
top="$HERE/app/RuntimeStage"
if [ -L "$top" ]; then
  target="$(readlink "$top")"
  case "$target" in "$HERE"/*|"$ROOT"/*) ;; /*) echo "✗ app/RuntimeStage -> $target"; bad=$((bad + 1)) ;; esac
fi
# A worktree whose vendor/Madeira is a link to a shared engine clone: staged files that point into another worktree's link to the same clone are this checkout's engine too.
VENDOR_REAL="$(cd "$HERE/vendor/Madeira" 2>/dev/null && pwd -P || true)"
while IFS= read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    "$HERE"/*|"$ROOT"/*) continue ;;                         # this checkout's own files, or this build folder
    /*) ;;
    *) continue ;;
  esac
  if [ -n "$VENDOR_REAL" ] && [ -e "$target" ]; then
    case "$(cd "$(dirname "$target")" && pwd -P)/" in "$VENDOR_REAL"/*) continue ;; esac
  fi
  echo "✗ ${link#$HERE/} -> $target"; bad=$((bad + 1))
done < <(find -H "$HERE/app/RuntimeStage" -type l)
if [ "$bad" -gt 0 ]; then
  echo "✗ $bad staged file(s) come from outside this checkout and outside $ROOT: the runtime was staged for another build."
  echo "  Re-stage (tools/stage_runtime.sh with this F4_BUILD_ROOT) or build from the checkout the engine was merged in."
  exit 1
fi
echo "✓ the staged runtime belongs to this checkout and build folder ($ROOT)"
