#!/bin/bash
# After a release is out, bring `prerelease` and `main` up to the commit it was built from, tag it, and push. main is the released state: it moves when a
# release goes out (and for fixes and docs that are ready), and stays where it is only while feature work or a Madeira merge is in progress on another branch.
#
#   tools/finish_release.sh [--dry-run] [commit]          default commit: HEAD of the checkout this is run in
#
# Fast-forward only: it stops if main or prerelease holds anything the commit does not. Tags v<MARKETING_VERSION> at the commit when that tag is absent.

# 1.4.0 (with the Discord features) is not released until the maintainer says so (docs/BRANCH-1.4.0.md).
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "1.4.0" ] && [ -z "$ALLOW_DISCORD_RELEASE" ]; then
  echo "✗ This is the 1.4.0 branch: it is not released, built for the public channel or promoted yet. See docs/BRANCH-1.4.0.md." >&2
  exit 1
fi
set -euo pipefail
cd "$(dirname "$0")/.."
DRY=0; ARG=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) ARG="$a" ;; esac; done
COMMIT=$(git rev-parse --verify "${ARG:-HEAD}^{commit}")
VERSION=$(git show "$COMMIT:app/project.yml" | grep -m1 -E '^[[:space:]]+MARKETING_VERSION:' | sed -E 's/.*: *"?([0-9.]+)"?.*/\1/')
BUILD=$(git show "$COMMIT:app/project.yml" | grep -m1 -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' | sed -E 's/.*: *"?([0-9]+)"?.*/\1/')
echo "▸ commit ${COMMIT:0:7}: version $VERSION (build $BUILD)"
# The commit must already be on origin, or main would point at something nobody else can fetch.
git fetch -q origin 2>/dev/null || true
git branch -r --contains "$COMMIT" 2>/dev/null | grep -q . || { echo "✗ ${COMMIT:0:7} is not on origin yet: push its branch first"; exit 1; }
for b in prerelease main; do
  git rev-parse -q --verify "refs/heads/$b" >/dev/null || { echo "✗ no local branch $b"; exit 1; }
  git merge-base --is-ancestor "$b" "$COMMIT" || { echo "✗ $b (${b:+$(git rev-parse --short $b)}) has commits that ${COMMIT:0:7} does not: not a fast-forward. Resolve by hand."; exit 1; }
  echo "  $b: $(git rev-parse --short "$b") -> ${COMMIT:0:7}"
done
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "  tag $TAG already exists at $(git rev-parse --short "$TAG^{commit}") (left alone)"; TAGGED=0; else echo "  tag $TAG -> ${COMMIT:0:7}"; TAGGED=1; fi
[ "$DRY" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }
for b in prerelease main; do
  git branch -f "$b" "$COMMIT" 2>&1 | sed 's/^/  /' || { echo "✗ could not move $b (checked out in another worktree?)"; exit 1; }
done
[ "$TAGGED" = 1 ] && git tag -a "$TAG" "$COMMIT" -m "Porthole $VERSION (build $BUILD)"
git push origin prerelease main ${TAGGED:+"$TAG"} 2>&1 | tail -4
echo "✓ main and prerelease are at ${COMMIT:0:7}"
