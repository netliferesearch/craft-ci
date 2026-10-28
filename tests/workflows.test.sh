#!/usr/bin/env bash
# actionlint over every workflow, plus structural assertions on the reusable verify workflow.
# Needs actionlint and the system ruby (YAML is read with Psych, which parses the key `on` as true).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT" || exit 1

yq_ruby() { ruby -ryaml -e 'doc = YAML.load_file(ARGV[0]); on = doc[true] || doc["on"]; '"$1" "${2:-.github/workflows/verify.yml}"; }

test_actionlint() {
  local out code=0
  out="$(actionlint .github/workflows/*.yml 2>&1)" || code=$?
  assert_eq 0 "$code" "actionlint exit ($out)"
}

test_verify_job_id() {
  assert_eq verify "$(yq_ruby 'puts doc["jobs"].keys.first' 2>&1)" "first job id"
}

test_verify_is_callable() {
  assert_eq true "$(yq_ruby 'puts on.is_a?(Hash) && on.key?("workflow_call")' 2>&1)" "has workflow_call"
  assert_eq true "$(yq_ruby 'puts on.keys == ["workflow_call"]' 2>&1)" "workflow_call is the only trigger"
}

test_verify_declares_secrets() {
  assert_eq "CRAFT_CLOUD_ENVIRONMENT_ID CRAFT_CLOUD_PROJECT_ID CRAFT_CLOUD_SIGNING_KEY CRAFT_CLOUD_USE_ASSET_CDN RENOVATE_APP_PRIVATE_KEY RENOVATE_PUSH_TOKEN SNAPSHOT_READ_KEY SNAPSHOT_READ_SECRET" "$(yq_ruby 'puts on["workflow_call"]["secrets"].keys.sort.join(" ")' 2>&1)" "declared secrets"
}

test_snapshot_declares_secrets() {
  assert_eq "SNAPSHOT_WRITE_KEY SNAPSHOT_WRITE_SECRET SOURCE_DB_HOST SOURCE_DB_NAME SOURCE_DB_PASSWORD SOURCE_DB_USER SOURCE_SSH_HOST SOURCE_SSH_KEY SOURCE_SSH_USER" "$(yq_ruby 'puts on["workflow_call"]["secrets"].keys.sort.join(" ")' .github/workflows/snapshot.yml 2>&1)" "declared secrets"
}

test_examples_map_every_secret() {
  local cloud="CRAFT_CLOUD_PROJECT_ID CRAFT_CLOUD_ENVIRONMENT_ID CRAFT_CLOUD_USE_ASSET_CDN CRAFT_CLOUD_SIGNING_KEY"
  local ssh="SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY"
  local row name file exempt
  for row in "verify|verify.yml|$cloud" "verify|verify-cloud.yml|" "snapshot|snapshot.yml|" "snapshot|snapshot-cloud-backup.yml|$ssh"; do
    IFS='|' read -r name file exempt <<< "$row"
    assert_eq "" "$(ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); e = YAML.load_file(ARGV[1]); on = w[true] || w["on"]; want = on["workflow_call"]["secrets"].keys - ARGV[2].split; got = e["jobs"].values.first["secrets"]; puts "x" unless got.is_a?(Hash) && got.keys.sort == want.sort' ".github/workflows/$name.yml" "examples/$file" "$exempt" 2>&1)" "$file maps exactly the declared secrets minus exempt"
    assert_eq 1 "$(grep -c -E '^[[:space:]]+uses: netliferesearch/craft-ci/' "examples/$file")" "$file calls the reusable workflow"
    assert_eq 0 "$(grep -c 'secrets: inherit' "examples/$file")" "$file has no secrets: inherit"
  done
}

test_cloud_snapshot_maps_backup_names() {
  local n
  for n in HOST NAME USER PASSWORD; do
    assert_eq '${{ secrets.DB_'"$n"' }}' "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"].values.first["secrets"]["SOURCE_DB_" + ARGV[1]]' examples/snapshot-cloud-backup.yml "$n" 2>&1)" "SOURCE_DB_$n mapping"
  done
}

test_verify_appends_cloud_env() {
  local n extra
  extra="$(yq_ruby 'puts doc["jobs"]["verify"]["steps"].find { |s| s["name"] == "Verify site" }["with"]["extra-env"]' 2>&1)"
  for n in CRAFT_CLOUD_PROJECT_ID CRAFT_CLOUD_ENVIRONMENT_ID CRAFT_CLOUD_USE_ASSET_CDN CRAFT_CLOUD_SIGNING_KEY; do
    case "$extra" in *"$n"*) ;; *) assert_eq "contains $n" "missing" "extra-env passes $n" ;; esac
  done
}

# These hashes pin nch's current callers; change them only together with nch.
test_forge_examples_unchanged() {
  assert_eq d2df07d80d4053daaaf0f2ca975e946bd95eb53954470df3022e7131478c95aa "$(shasum -a 256 examples/verify.yml | cut -d' ' -f1)" "examples/verify.yml hash"
  assert_eq e2d1ef8f1db743c33ce000d70eefc3b262478e7f09ff6f4dbd91cf1168c1bdf0 "$(shasum -a 256 examples/snapshot.yml | cut -d' ' -f1)" "examples/snapshot.yml hash"
  assert_eq 3cde676020b6954fdd343539efcd8cb2d65b95dbfae172c88acbdd98e93422ec "$(shasum -a 256 examples/backmerge.yml | cut -d' ' -f1)" "examples/backmerge.yml hash"
}

test_verify_inputs_and_job() {
  assert_eq "" "$(yq_ruby 'i = on["workflow_call"]["inputs"]; puts "x" unless i["extra-env"]["default"] == "" && i["project-config-commit"]["type"] == "boolean" && i["project-config-commit"]["default"] == true' 2>&1)" "inputs"
  assert_eq "" "$(yq_ruby 'j = doc["jobs"]["verify"]; puts "x" unless j["runs-on"] == "ubuntu-latest" && j["timeout-minutes"] == 25 && j["permissions"] == {"contents" => "read"}' 2>&1)" "job settings"
}

test_snapshot_job_id() {
  assert_eq snapshot "$(yq_ruby 'puts doc["jobs"].keys.first' .github/workflows/snapshot.yml 2>&1)" "first job id"
}

test_snapshot_has_service() {
  assert_eq mysql:8.0 "$(yq_ruby 'puts doc["jobs"]["snapshot"]["services"]["mysql"]["image"]' .github/workflows/snapshot.yml 2>&1)" "mysql service image"
}

test_backmerge_defaults_empty() {
  assert_eq "" "$(yq_ruby 'puts on["workflow_call"]["inputs"]["target-branch"]["default"]' .github/workflows/backmerge.yml 2>&1)" "target-branch default"
  assert_eq "" "$(yq_ruby 'puts on["workflow_call"]["inputs"]["source-branch"]["default"]' .github/workflows/backmerge.yml 2>&1)" "source-branch default"
}

test_examples_lint() {
  local out code=0
  out="$(actionlint examples/*.yml 2>&1)" || code=$?
  assert_eq 0 "$code" "actionlint examples ($out)"
  assert_eq nch "$(jq -r '.slug' examples/fleet.json 2>&1)" "example manifest slug"
}

test_example_manifest_resolves() {
  local out code=0
  out="$(GITHUB_REPOSITORY=Feedsystem/nch MANIFEST_NO_REMOTE=1 bash scripts/manifest.sh examples/fleet.json 2>&1)" || code=$?
  assert_eq 0 "$code" "manifest.sh exit on examples/fleet.json ($out)"
  case "$out" in *$'SLUG=nch'*) ;; *) assert_eq "contains SLUG=nch" "$out" "resolved slug" ;; esac
}

run_tests
