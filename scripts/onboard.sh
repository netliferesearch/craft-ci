#!/usr/bin/env bash
# Onboard one site repo into the craft-ci fleet, or report its drift.
# Usage: onboard.sh <owner>/<repo> [--slug S] [--develop B|none] [--host forge|servebolt|cloud] [--apply]
# Without --apply it only reads. With --apply it changes the repo settings, writes the fleet files on
# the branch netlife/fleet-onboarding and opens the PR "Adopt craft-ci fleet configuration" (or pushes
# to the open one). It never sets or deletes secrets or variables: it reads their names only.
# Prints the onboard-files.sh lines, then one line per check: "ok|diff|todo|note <check>: <detail>".
# Exit 0: no diff or todo. Exit 1: some diff or todo. Exit 2: usage error, or the repo cannot be
# cloned, or the host cannot be determined. Notes never affect the exit code.
# ONBOARD_CHECKOUT=<dir> uses that checkout instead of cloning the repo into a temp directory.
set -euo pipefail

FILES_SH="$(cd "$(dirname "$0")" && pwd)/onboard-files.sh"
TOPIC=netlife-fleet
CONTEXT="verify / verify"
BRANCH=netlife/fleet-onboarding
PR_TITLE="Adopt craft-ci fleet configuration"
# Paths onboard-files.sh --write may change; only these are committed.
FILE_PATHS=".netlife/fleet.json .github/workflows/verify.yml .github/workflows/snapshot.yml .github/workflows/backmerge.yml .craft-preview.json"

usage() { echo "usage: onboard.sh <owner>/<repo> [--slug S] [--develop B|none] [--host forge|servebolt|cloud] [--apply]" >&2; exit 2; }

repo="" apply=0 files_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug|--develop|--host) [ $# -ge 2 ] || usage; files_args+=("$1" "$2"); shift 2 ;;
    --apply) apply=1; shift ;;
    -*) usage ;;
    *) [ -z "$repo" ] || usage; repo="$1"; shift ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

lines=() status=0
report() { # state check detail
  lines+=("$1 $2: $3")
  case "$1" in diff|todo) status=1 ;; esac
}
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

# Run gh, keeping stdout in GH_OUT and stderr in GH_ERR. Returns 0, 4 when GitHub said 404, 1 otherwise.
GH_OUT="" GH_ERR=""
gh_read() {
  local code=0
  GH_OUT="$(gh "$@" 2>"$tmp/gh.err")" || code=$?
  GH_ERR="$(oneline < "$tmp/gh.err")"
  [ "$code" -eq 0 ] && return 0
  case "$GH_ERR" in *"HTTP 404"*) return 4 ;; esac
  return 1
}

# Report a setting that needs a change: diff without --apply; with --apply run the command and report the result.
fix() { # check problem fixed-detail command...
  local check="$1" problem="$2" fixed="$3" err; shift 3
  if [ "$apply" = 0 ]; then report diff "$check" "$problem"; return; fi
  if err="$("$@" 2>&1 >/dev/null)"; then
    report ok "$check" "$fixed (applied)"
  else
    report diff "$check" "$problem; apply failed: $(printf '%s' "$err" | oneline)"
  fi
}

# Checkout
if [ -n "${ONBOARD_CHECKOUT:-}" ]; then
  checkout="$ONBOARD_CHECKOUT"
  [ -d "$checkout/.git" ] || { echo "onboard: ONBOARD_CHECKOUT=$checkout is not a git checkout" >&2; exit 2; }
else
  checkout="$tmp/repo"
  gh repo clone "$repo" "$checkout" -- -q || { echo "onboard: cannot clone $repo" >&2; exit 2; }
fi
export GITHUB_REPOSITORY="$repo"

# Files, read only. This also tells the host, so it runs before any change.
files_rc=0
files_out="$(bash "$FILES_SH" "$checkout" ${files_args[@]+"${files_args[@]}"} 2>"$tmp/files.err")" || files_rc=$?
if [ "$files_rc" -eq 2 ]; then cat "$tmp/files.err" >&2; exit 2; fi
host_line="$(printf '%s\n' "$files_out" | tail -1)"
host="$(printf '%s' "$host_line" | sed -n 's/^host=\([a-z]*\) backup=.*/\1/p')"
backup="$(printf '%s' "$host_line" | sed -n 's/^host=[a-z]* backup=\([a-z]*\)$/\1/p')"
[ -n "$host" ] || { echo "onboard: unexpected onboard-files.sh output: $host_line" >&2; exit 2; }

# Settings
repo_rc=0; gh_read api "repos/$repo" || repo_rc=$?
repo_json="$GH_OUT"; repo_err="$GH_ERR"
if [ "$repo_rc" -ne 0 ]; then
  report todo topic "cannot read repos/$repo: $repo_err"
  report todo auto-merge "cannot read repos/$repo: $repo_err"
else
  if jq -e --arg t "$TOPIC" '(.topics // []) | index($t) != null' <<<"$repo_json" >/dev/null; then
    report ok topic "$TOPIC"
  else
    fix topic "$TOPIC topic missing" "$TOPIC added" gh repo edit "$repo" --add-topic "$TOPIC"
  fi
  if jq -e '.allow_auto_merge == true' <<<"$repo_json" >/dev/null; then
    report ok auto-merge "allowed"
  else
    fix auto-merge "auto-merge not allowed" "auto-merge allowed" gh api -X PATCH "repos/$repo" -F allow_auto_merge=true
  fi
fi

rc=0; gh_read api "repos/$repo/branches/main/protection" || rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then
  if [ "$rc" -eq 4 ]; then prot='{}'; problems="main is not protected"; else
    prot="$GH_OUT"
    problems="$(jq -r --arg v "$CONTEXT" '[
        (if (.required_status_checks.contexts // []) | index($v) then empty else "\($v) not required" end),
        (if .required_status_checks.strict == true then empty else "status checks not strict" end),
        (if .required_pull_request_reviews == null then empty else "pull request reviews required" end)
      ] | join(", ")' <<<"$prot")"
  fi
  if [ -z "$problems" ]; then
    report ok protection "main requires $CONTEXT, strict, no required reviews"
  else
    body="$(jq -c --arg v "$CONTEXT" '(.required_status_checks.contexts // []) as $c
      | {required_status_checks: {strict: true, contexts: ($c + ([$v] - $c))},
         enforce_admins: false, required_pull_request_reviews: null, restrictions: null}' <<<"$prot")"
    fix protection "$problems" "main requires $CONTEXT, strict, no required reviews" \
      gh api -X PUT "repos/$repo/branches/main/protection" --input - <<<"$body"
  fi
else
  report todo protection "cannot read branch protection on main: $GH_ERR"
fi

rc=0; gh_read api "repos/$repo/vulnerability-alerts" || rc=$?
case "$rc" in
  0) report ok "dependabot alerts" "enabled" ;;
  4) fix "dependabot alerts" "disabled" "enabled" gh api -X PUT "repos/$repo/vulnerability-alerts" ;;
  *) report todo "dependabot alerts" "cannot read: $GH_ERR" ;;
esac

rc=0; gh_read api "repos/$repo/actions/permissions/workflow" || rc=$?
if [ "$rc" -ne 0 ]; then
  report todo "actions create PRs" "cannot read workflow permissions: $GH_ERR"
elif jq -e '.can_approve_pull_request_reviews == true' <<<"$GH_OUT" >/dev/null; then
  report ok "actions create PRs" "allowed"
else
  body="$(jq -c '{default_workflow_permissions: (.default_workflow_permissions // "read"), can_approve_pull_request_reviews: true}' <<<"$GH_OUT")"
  fix "actions create PRs" "not allowed" "allowed" gh api -X PUT "repos/$repo/actions/permissions/workflow" --input - <<<"$body"
fi

rc=0; gh_read api -H "Accept: application/vnd.github.raw" repos/netliferesearch/renovate/contents/config.js || rc=$?
if [ "$rc" -ne 0 ]; then
  report todo renovate "cannot read netliferesearch/renovate config.js ($GH_ERR); make sure '$repo' is in repositories"
elif grep -qiF "'$repo'" <<<"$GH_OUT"; then
  report ok renovate "listed in netliferesearch/renovate config.js"
else
  report todo renovate "add '$repo' to repositories in netliferesearch/renovate config.js"
fi

# Files and PR
pr_url="" pr_head="" pr_rc=0
gh_read pr list --repo "$repo" --state open --json title,url,headRefName --limit 100 || pr_rc=$?
pr_err="$GH_ERR"
if [ "$pr_rc" -eq 0 ]; then
  pr_url="$(jq -r --arg t "$PR_TITLE" '[.[] | select(.title == $t)][0].url // empty' <<<"$GH_OUT")"
  pr_head="$(jq -r --arg t "$PR_TITLE" '[.[] | select(.title == $t)][0].headRefName // empty' <<<"$GH_OUT")"
fi

pr_body() {
  cat <<EOF
Written by \`scripts/onboard.sh\` in netliferesearch/craft-ci.

- \`.netlife/fleet.json\`: the site's fleet manifest.
- \`.github/workflows/verify.yml\`, \`snapshot.yml\`, \`backmerge.yml\`: callers of the shared craft-ci workflows.

Before merging, review \`.netlife/scrub.sql\` (site-specific personal data the snapshot must remove) and wait for \`$CONTEXT\` to pass.
EOF
  if git -C "$checkout" rev-parse -q --verify origin/main >/dev/null \
    && ! git -C "$checkout" diff --quiet origin/main HEAD -- .ddev/config.yaml; then
    printf '\nThis PR changes `.ddev/config.yaml`. Everyone needs a fresh local database import after it lands.\n'
  fi
}

# With --apply: check out the onboarding branch, write, commit, push, open or reuse the PR.
# Sets files_out/files_rc to the --write run and reports the "files" line.
apply_files() {
  local branch cur err paths=() f
  cur="$(git -C "$checkout" rev-parse --abbrev-ref HEAD)"
  if [ "$pr_rc" -ne 0 ]; then report todo files "cannot list open PRs ($pr_err); nothing written"; return; fi
  if [ "$cur" = "$BRANCH" ]; then branch="$BRANCH"
  else
    branch="${pr_head:-$BRANCH}"
    if git -C "$checkout" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      err="$(git -C "$checkout" checkout -q "$branch" 2>&1)" || { report diff files "cannot check out $branch: $(printf '%s' "$err" | oneline)"; return; }
    elif [ -n "$pr_head" ] && git -C "$checkout" fetch -q origin "$branch" 2>/dev/null; then
      err="$(git -C "$checkout" checkout -q -b "$branch" FETCH_HEAD 2>&1)" || { report diff files "cannot check out $branch: $(printf '%s' "$err" | oneline)"; return; }
    else
      err="$(git -C "$checkout" checkout -q -b "$branch" 2>&1)" || { report diff files "cannot create $branch: $(printf '%s' "$err" | oneline)"; return; }
    fi
  fi

  local write_rc=0 write_out
  write_out="$(bash "$FILES_SH" "$checkout" ${files_args[@]+"${files_args[@]}"} --write 2>"$tmp/files.err")" || write_rc=$?
  if [ "$write_rc" -eq 2 ]; then report diff files "onboard-files.sh --write failed: $(oneline < "$tmp/files.err")"; return; fi
  files_out="$write_out" files_rc="$write_rc"

  for f in $FILE_PATHS; do
    if [ -e "$checkout/$f" ] || git -C "$checkout" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      git -C "$checkout" add -A -- "$f"; paths+=("$f")
    fi
  done
  if [ ${#paths[@]} -gt 0 ] && ! git -C "$checkout" diff --cached --quiet -- "${paths[@]}"; then
    err="$(git -C "$checkout" commit -q -m "$PR_TITLE" -- "${paths[@]}" 2>&1)" || { report diff files "commit failed: $(printf '%s' "$err" | oneline)"; return; }
  fi
  err="$(git -C "$checkout" push -q -u origin "$branch" 2>&1)" || { report diff files "push of $branch failed: $(printf '%s' "$err" | oneline)"; return; }
  if [ -z "$pr_url" ]; then
    pr_url="$(pr_body | gh pr create --repo "$repo" --base main --head "$branch" --title "$PR_TITLE" --body-file - 2>"$tmp/gh.err" | tail -1)" \
      || { pr_url=""; report diff files "$branch pushed, pr create failed: $(oneline < "$tmp/gh.err")"; return; }
  fi
  report ok files "$branch pushed, PR ${pr_url:-opened} (applied)"
}

n_diff="$(printf '%s\n' "$files_out" | grep -c '^diff ' || true)"
on_branch=0; [ "$(git -C "$checkout" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] && on_branch=1
if [ "$apply" = 1 ] && { [ "$n_diff" -gt 0 ] || [ "$on_branch" = 1 ]; }; then
  apply_files
elif [ "$n_diff" -gt 0 ]; then
  report diff files "$n_diff file checks differ${pr_url:+ (open PR $pr_url)}; --apply writes them on a branch and opens or updates the PR"
else
  report ok files "nothing to write"
fi

# Secrets: names only, from the repo and, when readable, the org.
shared_names=" SNAPSHOT_WRITE_KEY SNAPSHOT_WRITE_SECRET SNAPSHOT_READ_KEY SNAPSHOT_READ_SECRET RENOVATE_PUSH_TOKEN "
hint() {
  case "$1" in
    CRAFT_CLOUD_*) echo "from the Craft Cloud console, production environment" ;;
    DB_*) echo "the database secrets of the backup-database workflow" ;;
    SOURCE_DB_*) echo "production database credentials" ;;
    SOURCE_SSH_*) echo "SSH access to the production server" ;;
  esac
}
rc_s=0; gh_read secret list --repo "$repo" --json name || rc_s=$?
repo_secrets="$GH_OUT" err_s="$GH_ERR"
rc_v=0; gh_read variable list --repo "$repo" --json name || rc_v=$?
repo_vars="$GH_OUT" err_v="$GH_ERR"
if [ "$rc_s" -ne 0 ] || [ "$rc_v" -ne 0 ]; then
  report todo secrets "cannot list repo secret and variable names: $err_s $err_v"
else
  org_secrets_ok=1; org_vars_ok=1
  gh_read api "repos/$repo/actions/organization-secrets?per_page=100" || org_secrets_ok=0
  org_secrets="$GH_OUT"
  gh_read api "repos/$repo/actions/organization-variables?per_page=100" || org_vars_ok=0
  org_vars="$GH_OUT"
  # "repo", "org" or "" for a secret (kind=secret) or variable (kind=variable) name.
  where() { # kind name
    local list ok org
    if [ "$1" = secret ]; then list="$repo_secrets" org="$org_secrets" ok="$org_secrets_ok"
    else list="$repo_vars" org="$org_vars" ok="$org_vars_ok"; fi
    if jq -e --arg n "$2" 'any(.[]; .name == $n)' <<<"$list" >/dev/null; then echo repo
    elif [ "$ok" = 1 ] && jq -e --arg n "$2" 'any((.secrets // .variables // [])[]; .name == $n)' <<<"$org" >/dev/null; then echo org
    fi
  }

  required="SNAPSHOT_WRITE_KEY SNAPSHOT_WRITE_SECRET SNAPSHOT_READ_KEY SNAPSHOT_READ_SECRET"
  if [ "$host" = cloud ]; then
    required="$required CRAFT_CLOUD_PROJECT_ID CRAFT_CLOUD_ENVIRONMENT_ID CRAFT_CLOUD_USE_ASSET_CDN CRAFT_CLOUD_SIGNING_KEY"
  fi
  if [ "$host" = cloud ] && [ "$backup" = yes ]; then
    required="$required DB_HOST DB_NAME DB_USER DB_PASSWORD"
  else
    required="$required SOURCE_DB_HOST SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD"
  fi
  if [ "$host" != cloud ]; then required="$required SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY"; fi

  if [ -n "$(where variable RENOVATE_APP_CLIENT_ID)" ] && [ -n "$(where secret RENOVATE_APP_PRIVATE_KEY)" ]; then
    report note "app config" "RENOVATE_APP_CLIENT_ID and RENOVATE_APP_PRIVATE_KEY visible, RENOVATE_PUSH_TOKEN not required"
  else
    report note "app config" "RENOVATE_APP_CLIENT_ID variable and RENOVATE_APP_PRIVATE_KEY secret not both visible, RENOVATE_PUSH_TOKEN required"
    required="$required RENOVATE_PUSH_TOKEN"
  fi

  for name in $required; do
    found="$(where secret "$name")"
    if [ -n "$found" ]; then
      report ok "secret $name" "$found"
    elif [[ "$shared_names" == *" $name "* ]]; then
      if [ "$org_secrets_ok" = 1 ]; then report todo "secret $name" "missing on repo and org"
      else report todo "secret $name" "missing on repo, may exist at org level"; fi
    else
      report todo "secret $name" "missing on repo ($(hint "$name"))"
    fi
  done
fi

# Manual steps
report note app "confirm the GitHub App installation includes $repo"
report note deploy "confirm the host deploys from main"
[ -z "$pr_url" ] || report note pr "merge $pr_url once $CONTEXT is green"

printf '%s\n' "$files_out"
printf '%s\n' "${lines[@]}"
[ "$files_rc" -eq 0 ] && [ "$status" -eq 0 ] || exit 1
