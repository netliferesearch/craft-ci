#!/usr/bin/env bash
# Merge <source> into <target> and push, so a long-lived branch follows main.
# Usage: backmerge.sh <source-branch> <target-branch>   (inside a clone with origin)
# Exit 0: target now contains source (fast-forward, merge commit or already up to date)
# Exit 2: merge conflict; the merge is aborted and the tree left clean, nothing pushed
# Exit 3: target branch does not exist on origin
# Env: BACKMERGE_AUTHOR (default "Craft CI <craft-ci@netlife.no>") for the merge commit
set -euo pipefail

source="${1:?source branch}"
target="${2:?target branch}"
author="${BACKMERGE_AUTHOR:-Craft CI <craft-ci@netlife.no>}"
name="${author%% <*}"; email="${author##*<}"; email="${email%>}"
export GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email"

if ! git ls-remote --exit-code --heads origin "$target" >/dev/null 2>&1; then
  echo "backmerge: target branch '$target' not found on origin"
  exit 3
fi

git fetch -q origin "$source" "$target"
git checkout -q -B "$target" "origin/$target"

if git merge-base --is-ancestor "origin/$source" HEAD; then
  echo "backmerge: $target already contains $source"
  exit 0
fi

if ! git merge --no-edit -m "Back-merge $source into $target" "origin/$source"; then
  git merge --abort
  echo "backmerge: conflict merging $source into $target, aborted"
  exit 2
fi

git push -q origin "$target"
echo "backmerge: pushed $target"
