#!/usr/bin/env bash
# After craft up in verify: if config/project changed, commit it back onto the PR's head branch.
# Runs inside the verify checkout (a detached merge commit, as actions/checkout gives a pull_request run).
# Env: HEAD_REF (PR head branch), HEAD_REPO and BASE_REPO (owner/name), PUSH_URL (remote carrying the
#      token, e.g. https://x-access-token:TOKEN@github.com/owner/name.git), CI_AUTHOR, PATHS
# Exit 0 and "changed=false": nothing under PATHS changed
# Exit 0 and "changed=true":  committed and pushed
# Exit 4: changes exist but PUSH_URL is empty (diff printed)
# Exit 5: HEAD_REPO is not BASE_REPO, a fork; never pushed to (diff printed)
# Exit 6: the change does not apply onto the current head branch; tree left clean, nothing pushed
set -euo pipefail

: "${HEAD_REF:?}" "${HEAD_REPO:?}" "${BASE_REPO:?}"
PUSH_URL="${PUSH_URL:-}"
author="${CI_AUTHOR:-Craft CI <craft-ci@netlife.no>}"
PATHS="${PATHS:-config/project}"
name="${author%% <*}"; email="${author##*<}"; email="${email%>}"
export GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email"

# shellcheck disable=SC2086  # PATHS is a space-separated list on purpose
if [ -z "$(git status --porcelain -- $PATHS)" ]; then
  echo "changed=false"
  exit 0
fi

echo "project config changed during verify:"
# shellcheck disable=SC2086
git --no-pager diff -- $PATHS

if [ "$HEAD_REPO" != "$BASE_REPO" ]; then
  echo "::error::project config changed, but the PR comes from a fork ($HEAD_REPO); commit it yourself"
  exit 5
fi
if [ -z "$PUSH_URL" ]; then
  echo "::error::project config changed and no push-token is configured; commit the diff above to the PR"
  exit 4
fi

# shellcheck disable=SC2086
git stash push -q -- $PATHS
git fetch -q origin "$HEAD_REF"
git checkout -q -B "$HEAD_REF" FETCH_HEAD
if ! git stash pop -q; then
  git reset -q --hard
  git stash drop -q
  echo "::error::project config change does not apply onto $HEAD_REF (the branch moved); rerun verify"
  exit 6
fi

git commit -q -am "Update project config after dependency update"
git push -q "$PUSH_URL" "HEAD:refs/heads/$HEAD_REF"
echo "changed=true"
