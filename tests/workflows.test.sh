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

test_verify_no_secret_decl() {
  assert_eq false "$(yq_ruby 'puts on["workflow_call"].key?("secrets")' 2>&1)" "no declared secrets"
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

run_tests
