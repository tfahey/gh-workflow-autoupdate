#!/usr/bin/env bash
# Manual fallback: merge a public upstream repo into a private clone and push.
# Run from inside the private repo's clone.
#
#   sync-upstream.sh owner/public-repo [upstream-branch] [target-branch]
set -euo pipefail

UPSTREAM_REPO="${1:?usage: $0 owner/public-repo [upstream-branch] [target-branch]}"
UPSTREAM_BRANCH="${2:-main}"
TARGET_BRANCH="${3:-main}"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean; commit or stash first." >&2
  exit 1
fi

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi
# Guard against accidentally pushing to the public repo.
git remote set-url --push upstream DISABLED

git checkout "$TARGET_BRANCH"
git pull --ff-only origin "$TARGET_BRANCH"
git fetch --no-tags upstream "$UPSTREAM_BRANCH"

if git merge-base --is-ancestor "upstream/${UPSTREAM_BRANCH}" HEAD; then
  echo "Already up to date."
  exit 0
fi

if ! git merge --no-edit "upstream/${UPSTREAM_BRANCH}"; then
  echo
  echo "Merge conflicts. Resolve them, then run:"
  echo "  git commit && git push origin ${TARGET_BRANCH}"
  exit 1
fi

git push origin "$TARGET_BRANCH"
