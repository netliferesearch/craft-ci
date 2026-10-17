#!/usr/bin/env bash
# Tests for scripts/backmerge.sh: merge <source> into <target> and push, or report why not.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/backmerge.sh"

test_fast_forward() {
  make_repo; commit_on main a.txt two "two"
  run_in_work "$SCRIPT" main develop
  assert_eq 0 "$CODE" "exit code"
  assert_eq "$(origin_rev main)" "$(origin_rev develop)" "develop fast-forwarded to main"
}

test_merge_commit() {
  make_repo; commit_on main a.txt two "two"; commit_on develop b.txt x "dev work"
  run_in_work "$SCRIPT" main develop
  assert_eq 0 "$CODE" "exit code"
  assert_eq 3 "$(git -C "$T/origin.git" rev-list --parents -n1 develop | wc -w | tr -d ' ')" "merge commit has two parents"
  git -C "$T/origin.git" merge-base --is-ancestor main develop; assert_eq 0 $? "develop contains main"
}

test_already_contains() {
  make_repo; local before; before="$(origin_rev develop)"
  run_in_work "$SCRIPT" main develop
  assert_eq 0 "$CODE" "exit code"
  assert_eq "$before" "$(origin_rev develop)" "develop unchanged"
}

test_conflict() {
  make_repo; commit_on main a.txt main-edit "main edit"; commit_on develop a.txt dev-edit "dev edit"
  local before; before="$(origin_rev develop)"
  run_in_work "$SCRIPT" main develop
  assert_eq 2 "$CODE" "exit code"
  assert_eq "" "$(git -C "$T/work" status --porcelain)" "tree clean after abort"
  assert_eq "$before" "$(origin_rev develop)" "develop unchanged"
}

test_missing_target() {
  make_repo; git -C "$T/work" push -q origin --delete develop
  run_in_work "$SCRIPT" main develop
  assert_eq 3 "$CODE" "exit code"
  assert_eq none "$(origin_rev develop)" "nothing pushed"
}

test_runs_twice() {
  make_repo; commit_on main a.txt main-edit "main edit"; commit_on develop a.txt dev-edit "dev edit"
  local before; before="$(origin_rev develop)"
  run_in_work "$SCRIPT" main develop; assert_eq 2 "$CODE" "first run"
  run_in_work "$SCRIPT" main develop; assert_eq 2 "$CODE" "second run"
  assert_eq "$before" "$(origin_rev develop)" "develop still unchanged"
}

run_tests
