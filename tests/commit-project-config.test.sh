#!/usr/bin/env bash
# Tests for scripts/commit-project-config.sh: after craft up in verify, commit config/project changes
# back onto the PR head branch, or refuse for the right reason.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/commit-project-config.sh"
HEAD_BRANCH=renovate/craft-patches
YAML=config/project/project.yaml

# origin with main and $HEAD_BRANCH; $T/work checked out as a detached merge of the two,
# which is what actions/checkout gives a pull_request run.
make_pr_checkout() {
  make_repo
  ( cd "$T/work" && git checkout -q main && mkdir -p config/project && printf 'dateModified: 1\nschemaVersion: 5.0.0\n' > "$YAML" \
    && git add "$YAML" && git commit -q -m "project config" && git push -q origin main \
    && git checkout -q -b "$HEAD_BRANCH" && echo '{"craftcms/cms":"5.8.1"}' > composer.json \
    && git add composer.json && git commit -q -m "Update Craft patches" && git push -q -u origin "$HEAD_BRANCH" \
    && git checkout -q main && echo two > a.txt && git commit -q -am "main moves on" && git push -q origin main \
    && git checkout -q --detach origin/main && git merge -q --no-edit "origin/$HEAD_BRANCH" )
}

run_script() { # extra env assignments...
  CODE=0
  ( cd "$T/work" && env HEAD_REF="$HEAD_BRANCH" HEAD_REPO=Feedsystem/nch BASE_REPO=Feedsystem/nch \
      PUSH_URL="$T/origin.git" "$@" bash "$SCRIPT" ) > "$T/out" 2>&1 || CODE=$?
}

test_no_change() {
  make_pr_checkout; local before; before="$(origin_rev "$HEAD_BRANCH")"
  run_script
  assert_eq 0 "$CODE" "exit code"
  grep -q '^changed=false$' "$T/out"; assert_eq 0 $? "prints changed=false"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_commits_and_pushes() {
  make_pr_checkout; local before; before="$(origin_rev "$HEAD_BRANCH")"
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script
  assert_eq 0 "$CODE" "exit code"
  grep -q '^changed=true$' "$T/out"; assert_eq 0 $? "prints changed=true"
  assert_eq "$before" "$(git -C "$T/origin.git" rev-parse "$HEAD_BRANCH~1")" "exactly one new commit on the head branch"
  assert_eq "craft-ci@netlife.no" "$(git -C "$T/origin.git" log -1 --format=%ae "$HEAD_BRANCH")" "author email"
  assert_eq "Update project config after dependency update" "$(git -C "$T/origin.git" log -1 --format=%s "$HEAD_BRANCH")" "message"
  assert_eq "schemaVersion: 5.1.0" "$(git -C "$T/origin.git" show "$HEAD_BRANCH:$YAML" | tail -n1)" "pushed content"
}

test_no_token() {
  make_pr_checkout; local before; before="$(origin_rev "$HEAD_BRANCH")"
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script PUSH_URL=
  assert_eq 4 "$CODE" "exit code"
  grep -q '^+schemaVersion: 5.1.0' "$T/out"; assert_eq 0 $? "diff printed"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_fork_refused() {
  make_pr_checkout; local before; before="$(origin_rev "$HEAD_BRANCH")"
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script HEAD_REPO=someone/nch
  assert_eq 5 "$CODE" "exit code"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_conflict() {
  make_pr_checkout
  git clone -q "$T/origin.git" "$T/other" && ( cd "$T/other" && git checkout -q "$HEAD_BRANCH" \
    && printf 'dateModified: 3\nschemaVersion: 5.2.0\n' > "$YAML" && git commit -q -am "someone else edits" && git push -q origin "$HEAD_BRANCH" )
  local before head; before="$(origin_rev "$HEAD_BRANCH")"; head="$(git -C "$T/work" rev-parse HEAD)"
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script
  assert_eq 6 "$CODE" "exit code"
  assert_eq "$head" "$(git -C "$T/work" rev-parse HEAD)" "verify checkout untouched"
  assert_eq 1 "$(git -C "$T/work" worktree list | wc -l | tr -d ' ')" "temporary worktree removed"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_new_file_included() {
  make_pr_checkout
  printf 'schemaVersion: 1.0.0\n' > "$T/work/config/project/plugins-newplugin.yaml"
  run_script
  assert_eq 0 "$CODE" "exit code"
  assert_eq "schemaVersion: 1.0.0" "$(git -C "$T/origin.git" show "$HEAD_BRANCH:config/project/plugins-newplugin.yaml" 2>/dev/null)" "new file pushed"
}

test_verify_tree_untouched() {
  make_pr_checkout; local head; head="$(git -C "$T/work" rev-parse HEAD)"
  echo built > "$T/work/a.txt"                                   # a build step touched a tracked file outside PATHS
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script
  assert_eq 0 "$CODE" "exit code"
  assert_eq "$head" "$(git -C "$T/work" rev-parse HEAD)" "verify checkout still on the merge commit"
  assert_eq built "$(cat "$T/work/a.txt")" "unrelated local change kept"
  assert_eq "schemaVersion: 5.1.0" "$(git -C "$T/origin.git" show "$HEAD_BRANCH:$YAML" | tail -n1)" "pushed anyway"
}

test_date_modified_only_is_no_change() {
  make_pr_checkout; local before; before="$(origin_rev "$HEAD_BRANCH")"
  printf 'dateModified: 99\nschemaVersion: 5.0.0\n' > "$T/work/$YAML"
  run_script
  assert_eq 0 "$CODE" "exit code"
  grep -q '^changed=false$' "$T/out"; assert_eq 0 $? "prints changed=false"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_loop_guard() {
  make_pr_checkout
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script; assert_eq 0 "$CODE" "first run pushes"
  local before; before="$(origin_rev "$HEAD_BRANCH")"
  printf 'dateModified: 3\nschemaVersion: 5.3.0\n' > "$T/work/$YAML"   # a second run changes it again
  run_script
  assert_eq 7 "$CODE" "second run refuses"
  grep -qi 'loop' "$T/out"; assert_eq 0 $? "explains the loop"
  assert_eq "$before" "$(origin_rev "$HEAD_BRANCH")" "nothing pushed"
}

test_push_overrides_persisted_credentials() {
  make_pr_checkout
  git -C "$T/work" config http.https://github.com/.extraheader "AUTHORIZATION: basic Z2l0aHViLWFjdGlvbnM6eA=="
  mkdir -p "$T/bin"; printf '#!/bin/bash\nprintf "git %%s\\n" "$*" >> "%s/gitlog"\nexec "%s" "$@"\n' "$T" "$REAL_GIT" > "$T/bin/git"; chmod +x "$T/bin/git"
  printf 'dateModified: 2\nschemaVersion: 5.1.0\n' > "$T/work/$YAML"
  run_script PATH="$T/bin:$PATH"
  assert_eq 0 "$CODE" "exit code"
  grep -E '^git .*-c http\.https://github\.com/\.extraheader= .*push ' "$T/gitlog" >/dev/null; assert_eq 0 $? "push resets the checkout's extraheader"
}

run_tests
