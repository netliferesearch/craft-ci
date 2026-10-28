#!/usr/bin/env bash
# Tests for scripts/onboard-files.sh: compare or write a site's manifest and workflow callers.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/onboard-files.sh"
SCHEMA_URL="https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json"
export GITHUB_REPOSITORY="Feedsystem/NCH"

put() { mkdir -p "$(dirname "$T/work/$1")"; printf '%s' "$2" > "$T/work/$1"; } # path content
callers() { # verify-example snapshot-example
  mkdir -p "$T/work/.github/workflows"
  cp "$ROOT/examples/$1" "$T/work/.github/workflows/verify.yml"
  cp "$ROOT/examples/$2" "$T/work/.github/workflows/snapshot.yml"
  cp "$ROOT/examples/backmerge.yml" "$T/work/.github/workflows/backmerge.yml"
}
ddev_mysql() { put .ddev/config.yaml $'name: nch\ndatabase:\n  type: mysql\n  version: "8.0"\n'; }
nch_site() {
  make_repo
  put .netlife/fleet.json '{"$schema":"'"$SCHEMA_URL"'","slug":"nch","verify":{"ignoreLogPattern":"ImageTransformException"},"preview":{"phpVersion":"php82"}}'
  callers verify.yml snapshot.yml
  ddev_mysql
  put .netlife/scrub.sql 'select 1;'
}
last_line() { tail -1 "$T/out"; }

test_nch_shape_is_clean() {
  nch_site
  run_in_work "$SCRIPT" "$T/work" --host forge
  assert_eq 0 "$CODE" "exit code"
  assert_eq 0 "$(grep -cv '^ok \|^host=' "$T/out")" "only ok lines"
  assert_eq "host=forge backup=no" "$(last_line)" "last line"
}

test_existing_manifest_kept() {
  nch_site
  cp "$T/work/.netlife/fleet.json" "$T/before.json"
  run_in_work "$SCRIPT" "$T/work" --host forge --write
  assert_eq 0 "$CODE" "exit code"
  cmp -s "$T/before.json" "$T/work/.netlife/fleet.json"; assert_eq 0 $? "manifest unchanged"
}

test_cloud_with_backup_writes_cloud_callers() {
  make_repo
  put craft-cloud.yaml 'x: 1'; put .github/workflows/backup-database.yml 'name: b'
  run_in_work "$SCRIPT" "$T/work" --write
  cmp -s "$ROOT/examples/verify-cloud.yml" "$T/work/.github/workflows/verify.yml"; assert_eq 0 $? "verify caller"
  cmp -s "$ROOT/examples/snapshot-cloud-backup.yml" "$T/work/.github/workflows/snapshot.yml"; assert_eq 0 $? "snapshot caller"
  assert_eq "$(jq -nS --arg s "$SCHEMA_URL" '{"$schema":$s}')" "$(jq -S . "$T/work/.netlife/fleet.json")" "manifest"
  assert_eq "host=cloud backup=yes" "$(last_line)" "last line"
}

test_cloud_without_backup() {
  make_repo; put craft-cloud.yaml 'x: 1'
  run_in_work "$SCRIPT" "$T/work" --write
  cmp -s "$ROOT/examples/snapshot.yml" "$T/work/.github/workflows/snapshot.yml"; assert_eq 0 $? "snapshot caller"
  assert_eq "host=cloud backup=no" "$(last_line)" "last line"
}

test_host_required_without_cloud_file() {
  make_repo
  run_in_work "$SCRIPT" "$T/work"
  assert_eq 2 "$CODE" "exit code"
  assert_eq 1 "$(grep -c -- '--host' "$T/out")" "stderr names --host"
}

test_mariadb_is_todo() {
  nch_site
  put .ddev/config.yaml $'database:\n  type: mariadb\n  version: "10.11"\n'
  cp "$T/work/.ddev/config.yaml" "$T/before.yaml"
  run_in_work "$SCRIPT" "$T/work" --host forge --write
  assert_eq 1 "$CODE" "exit code"
  assert_eq 1 "$(grep -c '^todo ddev database' "$T/out")" "todo line"
  cmp -s "$T/before.yaml" "$T/work/.ddev/config.yaml"; assert_eq 0 $? "ddev config unchanged"
}

test_missing_scrub_is_todo() {
  nch_site; rm "$T/work/.netlife/scrub.sql"
  run_in_work "$SCRIPT" "$T/work" --host forge
  assert_eq 1 "$CODE" "exit code"
  assert_eq 1 "$(grep -cFx 'todo scrub: write and review .netlife/scrub.sql before merging (blocks the snapshot)' "$T/out")" "scrub line"
}

test_slug_flag_differs() {
  nch_site; put .netlife/fleet.json '{"slug":"abc"}'
  run_in_work "$SCRIPT" "$T/work" --host forge --slug xyz
  assert_eq 1 "$CODE" "exit code"
  assert_eq 1 "$(grep -c '^diff manifest' "$T/out")" "diff manifest"
}

test_develop_none_written() {
  make_repo
  run_in_work "$SCRIPT" "$T/work" --host forge --develop none --write
  assert_eq null "$(jq -c '.branches.develop' "$T/work/.netlife/fleet.json")" "develop null"
}

test_legacy_preview_removed() {
  nch_site; put .craft-preview.json '{}'
  run_in_work "$SCRIPT" "$T/work" --host forge
  assert_eq 1 "$(grep -c '^diff legacy preview config' "$T/out")" "diff before write"
  run_in_work "$SCRIPT" "$T/work" --host forge --write
  assert_eq 0 "$CODE" "exit code"
  [ ! -e "$T/work/.craft-preview.json" ]; assert_eq 0 $? "file gone"
}

test_caller_one_byte_off() {
  nch_site; printf ' ' >> "$T/work/.github/workflows/verify.yml"
  run_in_work "$SCRIPT" "$T/work" --host forge
  assert_eq 1 "$CODE" "exit code"
  assert_eq 1 "$(grep -c '^diff caller verify' "$T/out")" "diff caller verify"
}

run_tests
