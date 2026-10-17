#!/usr/bin/env bash
# Structural check of action.yml (actionlint only lints workflows): parses, has the expected inputs
# and outputs, every step has a shell, and every inline script passes bash -n.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_action_yml_structure() {
  local out; out="$(ruby -ryaml -e '
    a = YAML.load_file("action.yml")
    %w[snapshot-key spaces-key spaces-secret environment extra-env ignore-log-pattern commit-project-config push-token].each { |k| abort "missing input #{k}" unless a["inputs"].key?(k) }
    abort "missing output project-config-changed" unless a.dig("outputs","project-config-changed","value").to_s.include?("steps.project-config.outputs.changed")
    abort "runs.using must be composite" unless a.dig("runs","using") == "composite"
    a["runs"]["steps"].each_with_index do |s,i|
      next unless s["run"]
      abort "step #{i} has run without shell" unless s["shell"] == "bash"
      IO.popen(["bash","-n"], "w") { |io| io.write(s["run"]) }
      abort "step #{i} (#{s["name"]}) fails bash -n" unless $?.success?
    end
    env = a["runs"]["steps"].find { |s| s["name"] == "Environment file" }
    abort "verify must allow admin changes so update migrations can write project config" unless env["run"].include?("CRAFT_ALLOW_ADMIN_CHANGES=true")
    step = a["runs"]["steps"].find { |s| s["id"] == "project-config" }
    abort "no project-config step" unless step
    abort "project-config step must be gated on the input and pull_request" unless step["if"].include?("commit-project-config == '"'"'true'"'"'") && step["if"].include?("pull_request")
    puts "ok"
  ' 2>&1)"
  assert_eq ok "$out" "action.yml structure"
}

run_tests
