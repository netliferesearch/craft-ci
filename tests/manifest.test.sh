#!/usr/bin/env bash
# Tests for scripts/manifest.sh: resolve .netlife/fleet.json defaults into KEY=value lines.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/manifest.sh"

# Sets up origin+clone, writes the manifest JSON ($1, empty = no file) and runs the resolver.
resolve() { # manifest-json repository
  make_repo
  if [ -n "$1" ]; then mkdir -p "$T/work/.netlife"; printf '%s' "$1" > "$T/work/.netlife/fleet.json"; fi
  export GITHUB_REPOSITORY="${2:-Feedsystem/NCH}"
  run_in_work "$SCRIPT"
}

no_develop() { git -C "$T/work" push -q origin --delete develop; }

val() { grep "^$1=" "$T/out" | head -1 | cut -d= -f2-; } # key → value from output

assert_defaults() {
  assert_eq 0 "$CODE" "exit code"
  assert_eq nch "$(val SLUG)" SLUG
  assert_eq production "$(val SNAPSHOT_SOURCE)" SNAPSHOT_SOURCE
  assert_eq snapshots/nch/latest.sql.gz "$(val SNAPSHOT_KEY)" SNAPSHOT_KEY
  assert_eq 40 "$(val VERIFY_CRAWL_LIMIT)" VERIFY_CRAWL_LIMIT
  assert_eq "" "$(val VERIFY_IGNORE_LOG_PATTERN)" VERIFY_IGNORE_LOG_PATTERN
  assert_eq staging "$(val VERIFY_ENVIRONMENT)" VERIFY_ENVIRONMENT
  assert_eq main "$(val BRANCH_MAIN)" BRANCH_MAIN
}

test_no_file() { resolve ""; no_develop; run_in_work "$SCRIPT"; assert_defaults; }

test_defaults_empty_object() { resolve '{}'; assert_defaults; }

test_explicit_values() {
  resolve '{"slug":"acme","snapshot":{"key":"custom/key.sql.gz"},"verify":{"crawlLimit":10,"ignoreLogPattern":"ImageTransformException"}}'
  assert_eq 0 "$CODE" "exit code"
  assert_eq acme "$(val SLUG)" SLUG
  assert_eq custom/key.sql.gz "$(val SNAPSHOT_KEY)" SNAPSHOT_KEY
  assert_eq 10 "$(val VERIFY_CRAWL_LIMIT)" VERIFY_CRAWL_LIMIT
  assert_eq ImageTransformException "$(val VERIFY_IGNORE_LOG_PATTERN)" VERIFY_IGNORE_LOG_PATTERN
}

test_slug_cleaning() {
  resolve '{}' netliferesearch/My-Long_Site-Name-2026
  assert_eq 0 "$CODE" "exit code"
  assert_eq mylongsitena "$(val SLUG)" SLUG
}

test_slug_from_bad_repo_name() {
  resolve '{}' org/2026
  assert_eq 2 "$CODE" "exit code"
  grep -q "set slug" "$T/out"; assert_eq 0 $? "stderr says 'set slug'"
}

test_bad_slug() { resolve '{"slug":"Ab"}'; assert_eq 2 "$CODE" "exit code"; }

test_bad_source() {
  resolve '{"snapshot":{"source":"prod"}}'
  assert_eq 2 "$CODE" "exit code"
  local s; for s in production staging none forge-backup; do
    grep -q "$s" "$T/out"; assert_eq 0 $? "stderr lists $s"
  done
}

test_unknown_key() {
  resolve '{"snapshotKey":"x"}'
  assert_eq 2 "$CODE" "exit code"
  grep -q snapshotKey "$T/out"; assert_eq 0 $? "stderr names snapshotKey"
}

test_develop_detected() { resolve '{}'; assert_eq develop "$(val BRANCH_DEVELOP)" BRANCH_DEVELOP; }

test_develop_absent() {
  make_repo; no_develop
  export GITHUB_REPOSITORY=Feedsystem/NCH
  run_in_work "$SCRIPT"
  assert_eq 0 "$CODE" "exit code"
  assert_eq "" "$(val BRANCH_DEVELOP)" BRANCH_DEVELOP
  grep -q '^BRANCH_DEVELOP=$' "$T/out"; assert_eq 0 $? "BRANCH_DEVELOP line printed empty"
}

test_develop_null() { resolve '{"branches":{"develop":null}}'; assert_eq 0 "$CODE" "exit code"; assert_eq "" "$(val BRANCH_DEVELOP)" BRANCH_DEVELOP; }

test_develop_named() {
  resolve '{"branches":{"develop":"staging"}}'
  assert_eq 0 "$CODE" "exit code"
  assert_eq staging "$(val BRANCH_DEVELOP)" BRANCH_DEVELOP
}

test_fixture_cases() {
  local fixture="$ROOT/tests/fixtures/manifest-cases.json" n i name repo manifest
  n="$(jq length "$fixture")"
  for ((i = 0; i < n; i++)); do
    name="$(jq -r ".[$i].name" "$fixture")"; repo="$(jq -r ".[$i].repository" "$fixture")"
    manifest="$(jq -c ".[$i].manifest" "$fixture")"
    resolve "$manifest" "$repo"
    if [ "$(jq -r ".[$i].expect" "$fixture")" = error ]; then
      assert_eq 2 "$CODE" "$name: exit code"
    else
      assert_eq 0 "$CODE" "$name: exit code"
      assert_eq "$(jq -r ".[$i].expect.slug" "$fixture")" "$(val SLUG)" "$name: SLUG"
      assert_eq "$(jq -r ".[$i].expect.snapshotKey" "$fixture")" "$(val SNAPSHOT_KEY)" "$name: SNAPSHOT_KEY"
    fi
  done
}

run_tests
