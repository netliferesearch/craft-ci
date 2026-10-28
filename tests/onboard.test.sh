#!/usr/bin/env bash
# Tests for scripts/onboard.sh: GitHub settings, secrets, the files PR and the manual steps.
# gh is a stub: it logs each call to $T/gh.log and answers from $T/gh/<key> (key = the sanitised
# argument string). A missing answer fails with "HTTP 404", except for write calls, which succeed
# silently. $T/gh/<key>.fail makes the call fail with that file as stderr. Stdin given to
# "--input -" or "--body-file -" is saved as $T/stdin/<key>.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/onboard.sh"
SCHEMA_URL="https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json"
R="Feedsystem/NCH"
TITLE="Adopt craft-ci fleet configuration"

gh_key() { printf '%s' "$*" | tr -c 'A-Za-z0-9' '_' | cut -c1-200; }
answer() { printf '%s' "$2" > "$T/gh/$(gh_key "$1")"; } # "args" content
fail() { printf '%s' "$2" > "$T/gh/$(gh_key "$1").fail"; } # "args" stderr
forget() { rm -f "$T/gh/$(gh_key "$1")"; } # "args"

install_gh_stub() {
  mkdir -p "$T/bin" "$T/gh" "$T/stdin"; : > "$T/gh.log"
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
T="$T"
printf '%s\n' "\$*" >> "\$T/gh.log"
key="\$(printf '%s' "\$*" | tr -c 'A-Za-z0-9' '_' | cut -c1-200)"
case " \$* " in *" --input - "*|*" --body-file - "*) cat > "\$T/stdin/\$key" ;; esac
if [ -f "\$T/gh/\$key.fail" ]; then cat "\$T/gh/\$key.fail" >&2; exit 1; fi
if [ -f "\$T/gh/\$key" ]; then cat "\$T/gh/\$key"; exit 0; fi
case " \$* " in *" -X "*|" repo edit "*|" pr create "*) exit 0 ;; esac
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$T/bin/gh"
}

put() { mkdir -p "$(dirname "$T/work/$1")"; printf '%s' "$2" > "$T/work/$1"; } # path content
# A forge checkout that onboard-files.sh reports as clean (as in onboard-files.test.sh), committed and pushed.
nch_site() {
  make_repo
  put .netlife/fleet.json '{"$schema":"'"$SCHEMA_URL"'","slug":"nch"}'
  mkdir -p "$T/work/.github/workflows"
  cp "$ROOT/examples/verify.yml" "$T/work/.github/workflows/verify.yml"
  cp "$ROOT/examples/snapshot.yml" "$T/work/.github/workflows/snapshot.yml"
  cp "$ROOT/examples/backmerge.yml" "$T/work/.github/workflows/backmerge.yml"
  put .ddev/config.yaml $'name: nch\ndatabase:\n  type: mysql\n  version: "8.0"\n'
  put .netlife/scrub.sql 'select 1;'
  ( cd "$T/work" && git add -A && git commit -q -m site && git push -q origin main )
}
# A forge checkout with no fleet files at all.
bare_site() {
  make_repo
  put .ddev/config.yaml $'database:\n  type: mysql\n  version: "8.0"\n'
  put .netlife/scrub.sql 'select 1;'
  ( cd "$T/work" && git add -A && git commit -q -m site && git push -q origin main )
}
names() { jq -nc '$ARGS.positional | map({name: .})' --args "$@"; }
secrets() { answer "secret list --repo $R --json name" "$(names "$@")"; }
org_secrets() { answer "api repos/$R/actions/organization-secrets?per_page=100" "$(jq -nc '{secrets: ($ARGS.positional | map({name: .}))}' --args "$@")"; }

# Every read answers as a compliant forge repo.
compliant_gh() {
  install_gh_stub
  answer "api repos/$R" '{"topics":["netlife-fleet"],"allow_auto_merge":true}'
  answer "api repos/$R/branches/main/protection" '{"required_status_checks":{"strict":true,"contexts":["verify / verify"]}}'
  answer "api repos/$R/vulnerability-alerts" ''
  answer "api repos/$R/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}'
  answer "api -H Accept: application/vnd.github.raw repos/netliferesearch/renovate/contents/config.js" "repositories: ['$R'],"
  answer "pr list --repo $R --state open --json title,url,headRefName,isCrossRepository --limit 100" '[]'
  secrets SOURCE_DB_HOST SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY RENOVATE_PUSH_TOKEN
  answer "variable list --repo $R --json name" '[]'
  org_secrets SNAPSHOT_WRITE_KEY SNAPSHOT_WRITE_SECRET SNAPSHOT_READ_KEY SNAPSHOT_READ_SECRET
  answer "api repos/$R/actions/organization-variables?per_page=100" '{"variables":[]}'
}
# Every setting off, nothing visible.
noncompliant_gh() {
  compliant_gh
  answer "api repos/$R" '{"topics":[],"allow_auto_merge":false}'
  forget "api repos/$R/branches/main/protection"
  forget "api repos/$R/vulnerability-alerts"
  answer "api repos/$R/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
  answer "api -H Accept: application/vnd.github.raw repos/netliferesearch/renovate/contents/config.js" "repositories: [],"
  secrets
  org_secrets
}

run_onboard() { # args...  → CODE, output in $T/out
  CODE=0
  ( cd "$T" && PATH="$T/bin:$PATH" ONBOARD_CHECKOUT="$T/work" bash "$SCRIPT" "$@" ) > "$T/out" 2>&1 || CODE=$?
}
count() { grep -c -- "$1" "$2" || true; } # regex file
countx() { grep -cFx -- "$1" "$2" || true; } # exact-line file
log_has() { count "$1" "$T/gh.log"; }

test_clean_repo_exits_zero() {
  nch_site; compliant_gh
  run_onboard "$R" --host forge
  assert_eq 0 "$CODE" "exit code"
  assert_eq 0 "$(count '^diff \|^todo ' "$T/out")" "no diff or todo"
  assert_eq 1 "$(countx "note app: confirm the GitHub App installation includes $R" "$T/out")" "app note"
  assert_eq 1 "$(countx "note deploy: confirm the host deploys from main" "$T/out")" "deploy note"
}

test_dry_run_changes_nothing() {
  bare_site; noncompliant_gh
  run_onboard "$R" --host forge
  assert_eq 1 "$CODE" "exit code"
  for c in topic protection auto-merge "dependabot alerts" "actions create PRs" files; do
    assert_eq 1 "$(count "^diff $c:" "$T/out")" "diff $c"
  done
  assert_eq 1 "$(count '^todo renovate:' "$T/out")" "todo renovate"
  assert_eq 0 "$(log_has '-X PUT\|-X PATCH\|repo edit\|pr create')" "no writes"
  assert_eq none "$(origin_rev netlife/fleet-onboarding)" "no branch on origin"
  assert_eq 0 "$(cd "$T/work" && git status --porcelain | wc -l | tr -d ' ')" "checkout untouched"
}

test_apply_protection_keeps_contexts() {
  nch_site; compliant_gh
  answer "api repos/$R/branches/main/protection" '{"required_status_checks":{"strict":false,"contexts":["build"]}}'
  run_onboard "$R" --host forge --apply
  local key; key="$(gh_key "api -X PUT repos/$R/branches/main/protection --input -")"
  assert_eq '["build","verify / verify"]' "$(jq -c '.required_status_checks.contexts' "$T/stdin/$key")" "contexts"
  assert_eq 'true false null null' "$(jq -r '[.required_status_checks.strict, .enforce_admins, .required_pull_request_reviews, .restrictions] | map(tostring) | join(" ")' "$T/stdin/$key")" "other fields"
  assert_eq 1 "$(count '^ok protection:.*(applied)' "$T/out")" "applied line"
  assert_eq 0 "$CODE" "exit code"
}

test_apply_protection_keeps_rules() {
  nch_site; compliant_gh
  answer "api repos/$R/branches/main/protection" '{
    "required_status_checks": {"strict": false, "contexts": ["build", "lint"],
      "checks": [{"context": "build", "app_id": 15368}, {"context": "lint", "app_id": null}]},
    "enforce_admins": {"enabled": true},
    "required_pull_request_reviews": {"required_approving_review_count": 1},
    "restrictions": {"users": [{"login": "svale"}], "teams": [], "apps": []},
    "required_linear_history": {"enabled": true},
    "allow_force_pushes": {"enabled": false},
    "allow_deletions": {"enabled": false},
    "required_conversation_resolution": {"enabled": true}}'
  run_onboard "$R" --host forge
  assert_eq 1 "$(count '^diff protection:.*removes required reviews' "$T/out")" "dry run says reviews go"
  run_onboard "$R" --host forge --apply
  local b; b="$T/stdin/$(gh_key "api -X PUT repos/$R/branches/main/protection --input -")"
  assert_eq '[{"context":"build","app_id":15368},{"context":"lint"},{"context":"verify / verify"}]' \
    "$(jq -c '.required_status_checks.checks' "$b")" "checks keep app_id"
  assert_eq 'null' "$(jq -c '.required_status_checks.contexts' "$b")" "no contexts next to checks"
  assert_eq 'true true null' "$(jq -r '[.required_status_checks.strict, .enforce_admins, .required_pull_request_reviews] | map(tostring) | join(" ")' "$b")" "strict, admins, reviews"
  assert_eq '{"users":["svale"],"teams":[],"apps":[]}' "$(jq -c '.restrictions' "$b")" "restrictions"
  assert_eq 'true false false true' "$(jq -r '[.required_linear_history, .allow_force_pushes, .allow_deletions, .required_conversation_resolution] | map(tostring) | join(" ")' "$b")" "other rules kept"
  assert_eq 'false' "$(jq -c 'has("lock_branch")' "$b")" "absent rules not added"
  assert_eq 1 "$(count '^ok protection:.*required reviews removed.*(applied)' "$T/out")" "applied line"
}

test_apply_fixes_settings() {
  nch_site; noncompliant_gh
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$(log_has "^repo edit $R --add-topic netlife-fleet$")" "topic"
  assert_eq 1 "$(log_has "^api -X PATCH repos/$R -F allow_auto_merge=true$")" "auto-merge"
  assert_eq 1 "$(log_has "^api -X PUT repos/$R/vulnerability-alerts$")" "alerts"
  local key; key="$(gh_key "api -X PUT repos/$R/actions/permissions/workflow --input -")"
  assert_eq '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}' "$(jq -c . "$T/stdin/$key")" "workflow permissions body"
  key="$(gh_key "api -X PUT repos/$R/branches/main/protection --input -")"
  assert_eq '["verify / verify"]' "$(jq -c '.required_status_checks.contexts' "$T/stdin/$key")" "contexts from none"
}

test_apply_failure_is_diff() {
  nch_site; noncompliant_gh
  fail "api -X PUT repos/$R/vulnerability-alerts" "gh: Must have admin rights to Repository. (HTTP 403)"
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$CODE" "exit code"
  assert_eq 1 "$(count '^diff dependabot alerts:.*apply failed.*HTTP 403' "$T/out")" "diff line"
}

test_apply_never_sets_secrets() {
  bare_site; noncompliant_gh
  run_onboard "$R" --host forge --apply
  assert_eq 0 "$(log_has 'secret set\|secret delete\|variable set\|variable delete')" "no secret writes"
  assert_eq 1 "$(count '^todo secret SOURCE_DB_HOST:' "$T/out")" "secret still todo"
  assert_eq 1 "$CODE" "exit code"
}

test_apply_reuses_open_pr() {
  bare_site; compliant_gh
  ( cd "$T/work" && git checkout -q -b netlife/fleet-onboarding && echo x > b.txt && git add b.txt \
    && git commit -q -m earlier && git push -q origin netlife/fleet-onboarding && git checkout -q main \
    && git branch -q -D netlife/fleet-onboarding )
  answer "pr list --repo $R --state open --json title,url,headRefName,isCrossRepository --limit 100" \
    '[{"title":"Other","url":"https://x/pull/1","headRefName":"other","isCrossRepository":false},{"title":"'"$TITLE"'","url":"https://x/pull/7","headRefName":"netlife/fleet-onboarding","isCrossRepository":false}]'
  run_onboard "$R" --host forge --apply
  assert_eq 0 "$(log_has 'pr create')" "no pr create"
  assert_eq 0 "$CODE" "exit code"
  git -C "$T/origin.git" cat-file -e "refs/heads/netlife/fleet-onboarding:.netlife/fleet.json" 2>/dev/null
  assert_eq 0 $? "manifest pushed to the PR branch"
  git -C "$T/origin.git" cat-file -e "refs/heads/netlife/fleet-onboarding:b.txt" 2>/dev/null
  assert_eq 0 $? "earlier commit kept"
  assert_eq 1 "$(countx "note pr: merge https://x/pull/7 once verify / verify is green" "$T/out")" "pr note"
}

test_apply_opens_pr() {
  bare_site; compliant_gh
  answer "pr create --repo $R --base main --head netlife/fleet-onboarding --title $TITLE --body-file -" "https://x/pull/9"
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$(log_has "^pr create .*--title $TITLE ")" "one pr create"
  assert_eq 0 "$CODE" "exit code"
  assert_eq 1 "$(count '^ok caller verify:.*(written)' "$T/out")" "write output printed"
  assert_eq "$(git -C "$T/work" rev-parse HEAD)" "$(origin_rev netlife/fleet-onboarding)" "branch pushed"
  assert_eq "$(origin_rev main)" "$(git -C "$T/work" rev-parse HEAD~1)" "one commit on top of main"
  assert_eq "$TITLE" "$(git -C "$T/work" log -1 --format=%s)" "commit subject"
  assert_eq 1 "$(countx "note pr: merge https://x/pull/9 once verify / verify is green" "$T/out")" "pr note"
}

prs() { answer "pr list --repo $R --state open --json title,url,headRefName,isCrossRepository --limit 100" "$1"; }

test_ignores_fork_pr() {
  bare_site; compliant_gh
  prs '[{"title":"'"$TITLE"'","url":"https://x/pull/3","headRefName":"main","isCrossRepository":true}]'
  local main_before; main_before="$(origin_rev main)"
  run_onboard "$R" --host forge --apply
  assert_eq "$main_before" "$(origin_rev main)" "main untouched"
  assert_eq 1 "$(log_has '^pr create .*--head netlife/fleet-onboarding ')" "new PR from the onboarding branch"
  assert_eq "$(git -C "$T/work" rev-parse HEAD)" "$(origin_rev netlife/fleet-onboarding)" "onboarding branch pushed"
  assert_eq 0 "$(count 'pull/3' "$T/out")" "fork PR not mentioned"
}

test_refuses_push_to_main() {
  bare_site; compliant_gh
  prs '[{"title":"'"$TITLE"'","url":"https://x/pull/4","headRefName":"main","isCrossRepository":false}]'
  local main_before; main_before="$(origin_rev main)"
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$CODE" "exit code"
  assert_eq "$main_before" "$(origin_rev main)" "main untouched"
  assert_eq 1 "$(count '^diff files:.*refusing' "$T/out")" "diff files"
  assert_eq 0 "$(log_has 'pr create')" "no pr create"
  assert_eq 0 "$(cd "$T/work" && git status --porcelain | wc -l | tr -d ' ')" "nothing written"
}

test_refuses_default_branch() {
  bare_site; compliant_gh
  answer "api repos/$R" '{"topics":["netlife-fleet"],"allow_auto_merge":true,"default_branch":"trunk"}'
  prs '[{"title":"'"$TITLE"'","url":"https://x/pull/5","headRefName":"trunk","isCrossRepository":false}]'
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$(count '^diff files:.*refusing to commit on trunk' "$T/out")" "diff files"
  assert_eq none "$(origin_rev trunk)" "nothing pushed"
}

test_on_branch_with_other_pr_head() {
  bare_site; compliant_gh
  ( cd "$T/work" && git checkout -q -b netlife/fleet-onboarding )
  prs '[{"title":"'"$TITLE"'","url":"https://x/pull/6","headRefName":"someone/else","isCrossRepository":false}]'
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$(count '^diff files:.*is from someone/else' "$T/out")" "diff files"
  assert_eq none "$(origin_rev netlife/fleet-onboarding)" "nothing pushed"
}

test_apply_on_existing_branch() {
  bare_site; compliant_gh
  ( cd "$T/work" && git checkout -q -b netlife/fleet-onboarding && echo x > b.txt && git add b.txt && git commit -q -m earlier )
  local earlier; earlier="$(git -C "$T/work" rev-parse HEAD)"
  run_onboard "$R" --host forge --apply
  assert_eq netlife/fleet-onboarding "$(git -C "$T/work" rev-parse --abbrev-ref HEAD)" "still on the branch"
  assert_eq "$earlier" "$(git -C "$T/work" rev-parse HEAD~1)" "committed on top of the branch"
  assert_eq "$(git -C "$T/work" rev-parse HEAD)" "$(origin_rev netlife/fleet-onboarding)" "pushed"
  assert_eq 1 "$(log_has '^pr create')" "pr created"
}

test_apply_clean_files_no_pr() {
  nch_site; compliant_gh
  run_onboard "$R" --host forge --apply
  assert_eq 0 "$(log_has 'pr create')" "no pr create"
  assert_eq none "$(origin_rev netlife/fleet-onboarding)" "no branch"
  assert_eq 1 "$(count '^ok files:' "$T/out")" "ok files"
}

test_org_secrets_unreadable() {
  nch_site; compliant_gh
  forget "api repos/$R/actions/organization-secrets?per_page=100"
  fail "api repos/$R/actions/organization-secrets?per_page=100" "gh: Resource not accessible by integration (HTTP 403)"
  run_onboard "$R" --host forge
  assert_eq 1 "$(countx "todo secret SNAPSHOT_READ_KEY: missing on repo, may exist at org level" "$T/out")" "todo line"
  assert_eq 1 "$CODE" "exit code"
}

cloud_site() { # backup yes|no
  bare_site; rm "$T/work/.ddev/config.yaml"; put craft-cloud.yaml 'x: 1'
  [ "$1" = yes ] && put .github/workflows/backup-database.yml 'name: b'
  compliant_gh; secrets
}
todo_secret() { count "^todo secret $1:" "$T/out"; }

test_secrets_cloud_with_backup() {
  cloud_site yes
  run_onboard "$R"
  assert_eq 1 "$(todo_secret DB_HOST)" "DB_HOST"
  assert_eq 1 "$(todo_secret CRAFT_CLOUD_SIGNING_KEY)" "CRAFT_CLOUD_SIGNING_KEY"
  assert_eq 0 "$(todo_secret SOURCE_DB_HOST)" "no SOURCE_DB_HOST"
  assert_eq 0 "$(todo_secret SOURCE_SSH_KEY)" "no SOURCE_SSH_KEY"
}

test_secrets_cloud_without_backup() {
  cloud_site no
  run_onboard "$R"
  assert_eq 1 "$(todo_secret SOURCE_DB_HOST)" "SOURCE_DB_HOST"
  assert_eq 0 "$(todo_secret DB_HOST)" "no DB_HOST"
  assert_eq 0 "$(todo_secret SOURCE_SSH_KEY)" "no SOURCE_SSH_KEY"
}

test_forge_with_backup_file_needs_source() {
  nch_site; compliant_gh; secrets
  put .github/workflows/backup-database.yml 'name: b'
  run_onboard "$R" --host forge
  assert_eq 1 "$(todo_secret SOURCE_DB_HOST)" "SOURCE_DB_HOST"
  assert_eq 1 "$(todo_secret SOURCE_SSH_KEY)" "SOURCE_SSH_KEY"
  assert_eq 0 "$(todo_secret DB_HOST)" "no DB_HOST"
}

test_app_configured_drops_push_token() {
  nch_site; compliant_gh
  secrets SOURCE_DB_HOST SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY RENOVATE_APP_PRIVATE_KEY
  answer "api repos/$R/actions/organization-variables?per_page=100" '{"variables":[{"name":"RENOVATE_APP_CLIENT_ID"}]}'
  run_onboard "$R" --host forge
  assert_eq 0 "$(todo_secret RENOVATE_PUSH_TOKEN)" "push token not required"
  assert_eq 0 "$CODE" "exit code"
}

test_app_missing_needs_push_token() {
  nch_site; compliant_gh
  secrets SOURCE_DB_HOST SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY RENOVATE_APP_PRIVATE_KEY
  run_onboard "$R" --host forge
  assert_eq 1 "$(todo_secret RENOVATE_PUSH_TOKEN)" "push token required"
}

test_renovate_missing_is_todo() {
  nch_site; compliant_gh
  answer "api -H Accept: application/vnd.github.raw repos/netliferesearch/renovate/contents/config.js" "repositories: ['Feedsystem/other'],"
  run_onboard "$R" --host forge
  assert_eq 1 "$(countx "todo renovate: add '$R' to repositories in netliferesearch/renovate config.js" "$T/out")" "todo line"
  assert_eq 1 "$CODE" "exit code"
}

test_unreadable_protection_is_todo_not_applied() {
  nch_site; compliant_gh
  forget "api repos/$R/branches/main/protection"
  fail "api repos/$R/branches/main/protection" "gh: Resource not accessible (HTTP 403)"
  run_onboard "$R" --host forge --apply
  assert_eq 1 "$(count '^todo protection: cannot read' "$T/out")" "todo line"
  assert_eq 0 "$(log_has 'protection --input')" "no PUT"
}

test_usage_errors() {
  nch_site; compliant_gh
  run_onboard; assert_eq 2 "$CODE" "no repo"
  run_onboard not-a-repo; assert_eq 2 "$CODE" "bad repo"
  run_onboard "$R" --bogus; assert_eq 2 "$CODE" "bad flag"
  bare_site; compliant_gh
  run_onboard "$R" --apply; assert_eq 2 "$CODE" "host undeterminable"
  assert_eq 0 "$(log_has '-X\|repo edit')" "nothing applied"
}

run_tests
