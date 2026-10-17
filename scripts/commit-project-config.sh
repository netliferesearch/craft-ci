#!/usr/bin/env bash
# After craft up in verify: if config/project changed, commit it back onto the PR's head branch.
# Runs inside the verify checkout (a detached merge commit, as actions/checkout gives a pull_request run)
# and leaves that checkout as it is: the commit is built in a temporary worktree of the head branch.
# Env: HEAD_REF (PR head branch), HEAD_REPO and BASE_REPO (owner/name), PUSH_URL (remote carrying the
#      token, e.g. https://x-access-token:TOKEN@github.com/owner/name.git), CI_AUTHOR, PATHS
# Exit 0 and "changed=false": nothing under PATHS changed, or only dateModified lines did
# Exit 0 and "changed=true":  committed and pushed
# Exit 4: changes exist but PUSH_URL is empty (diff printed)
# Exit 5: HEAD_REPO is not BASE_REPO, a fork; never pushed to (diff printed)
# Exit 6: the change does not apply onto the current head branch; nothing pushed
# Exit 7: the head branch already ends in one of these commits and config changed again; nothing pushed
set -euo pipefail

: "${HEAD_REF:?}" "${HEAD_REPO:?}" "${BASE_REPO:?}"
PUSH_URL="${PUSH_URL:-}"
author="${CI_AUTHOR:-Craft CI <craft-ci@netlife.no>}"
PATHS="${PATHS:-config/project}"
message="Update project config after dependency update"
name="${author%% <*}"; email="${author##*<}"; email="${email%>}"
export GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email"

# shellcheck disable=SC2086  # PATHS is a space-separated list on purpose
git add -A -- $PATHS
# shellcheck disable=SC2086
diff="$(git diff --cached --binary HEAD -- $PATHS)"
if [ -z "$diff" ]; then
  echo "changed=false"
  exit 0
fi

# Craft rewrites dateModified whenever it touches project config. On its own that is not a change
# worth a commit, and committing it would start a new verify run every time.
substantive="$(printf '%s\n' "$diff" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[+-][[:space:]]*dateModified:' || true)"
if [ -z "$substantive" ]; then
  echo "project config: only dateModified changed, ignoring"
  echo "changed=false"
  exit 0
fi

echo "project config changed during verify:"
printf '%s\n' "$diff"

if [ "$HEAD_REPO" != "$BASE_REPO" ]; then
  echo "::error::project config changed, but the PR comes from a fork ($HEAD_REPO); commit it yourself"
  exit 5
fi
if [ -z "$PUSH_URL" ]; then
  echo "::error::project config changed and no push-token is configured; commit the diff above to the PR"
  exit 4
fi

git fetch -q origin "$HEAD_REF"
if [ "$(git log -1 --format='%ae%n%s' FETCH_HEAD)" = "$email"$'\n'"$message" ]; then
  echo "::error::$HEAD_REF already ends in a project config commit from CI and config changed again; pushing would loop. Check whether Craft rewrites config/project on every run"
  exit 7
fi

tmp="$(mktemp -d)"
patch="$(mktemp)"
cleanup() { git worktree remove --force "$tmp" 2>/dev/null || true; rm -f "$patch"; }
trap cleanup EXIT
printf '%s\n' "$diff" > "$patch"
git worktree add -q --detach "$tmp" FETCH_HEAD
if ! git -C "$tmp" apply --3way "$patch"; then
  echo "::error::project config change does not apply onto $HEAD_REF: the branch moved or main changed config/project too. Rebase the branch on main (Renovate does this when it is behind) and verify runs again"
  exit 6
fi
# shellcheck disable=SC2086
git -C "$tmp" add -A -- $PATHS
git -C "$tmp" commit -q -m "$message"
# actions/checkout persists GITHUB_TOKEN as an extraheader; git would send that instead of the URL
# credentials, and a push as GITHUB_TOKEN triggers no workflows. Reset it for this push only.
git -C "$tmp" -c http.https://github.com/.extraheader= push -q "$PUSH_URL" "HEAD:refs/heads/$HEAD_REF"
echo "changed=true"
