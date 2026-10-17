# Renovate Pilot on nch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Renovate opens grouped Composer update PRs on Feedsystem/nch, verify gates them, patch PRs merge and deploy on their own, and `develop` follows `main`.

**Architecture:** Three repos take part. `netliferesearch/craft-ci` (this repo) gains a reusable back-merge workflow and an optional "commit project config back to the PR branch" step in the verify action, both backed by shell scripts with local tests. A new public repo `netliferesearch/renovate` holds the preset (policy), the runner config and a scheduled workflow that runs Renovate against nch with a fine-grained token. Feedsystem/nch gets branch protection, auto-merge, Dependabot alerts, a back-merge caller and a one-line `renovate.json`.

**Tech Stack:** GitHub Actions (composite action, reusable workflow), bash, `gh` CLI, Renovate self-hosted via `renovatebot/github-action`, `renovate-config-validator`, `actionlint`.

**Spec:** `docs/superpowers/specs/2026-10-16-renovate-pilot-design.md`

## Global Constraints

- Composer manager only. npm and GitHub Actions managers stay off.
- Patch group name `Craft patches`, schedule `before 6am on monday`. Minor group name `Craft minors`, schedule `before 6am on the first day of the month`. Timezone `Europe/Oslo`. Majors disabled.
- Automerge ships **off** in the preset (Tasks 5 and 6) and is switched on only in Task 10, after a grouped PR has been merged by hand.
- `rangeStrategy` is `update-lockfile`: exact pins get replaced, caret ranges keep the range and update the lock.
- The CI git author for project-config commits is `Craft CI <craft-ci@netlife.no>`. The preset's `gitIgnoredAuthors` carries the same email. The two must match.
- Never push a project-config commit for a PR whose head repository is not the base repository (forks).
- The runner never uses `GITHUB_TOKEN`. Verify and the project-config push use a token that triggers workflows.
- Runner secret `RENOVATE_TOKEN` lives in an Actions environment named `renovate` on the renovate repo, restricted to protected branches. The nch push secret is `RENOVATE_PUSH_TOKEN`.
- Shell scripts: `set -euo pipefail`, no interactive prompts, every failure path prints why and exits non-zero.
- Commit only with the user's go-ahead per task; never force-push anything except moving the `v1` tag in Task 4.

## Review Focus

1. **A PR from a fork** with project-config changes: verify must skip the push and still fail the check with the diff printed, never push with the token. Test in Task 4 (condition on the step) and Task 3 (script refuses when `HEAD_REPO != BASE_REPO`).
2. **`main` changed `config/project` since the Renovate branch was cut**: the stash pop in the commit script conflicts. Expected: no partial commit, no push, non-zero exit with the conflict shown. Test in Task 3.
3. **Back-merge conflict pushed twice**: the second push to `main` must not open a second "Back-merge main" PR. Test in Task 1.
4. **`develop` does not exist** on a site that adopts the caller: the back-merge fails with a one-line reason and opens nothing. Test in Task 1.
5. **Renovate rebases its branch** and force-pushes over the CI project-config commit. Expected: verify re-runs and re-commits, and Renovate still automerges because the CI author is in `gitIgnoredAuthors`. Pinned by the email-equality check in Task 5 and observed in Task 9.

---

### Task 1: Back-merge script

**Files:**
- Create: `scripts/backmerge.sh`
- Create: `tests/backmerge.test.sh`
- Create: `tests/lib.sh` (tiny assert helpers: `assert_eq`, `assert_exit`, `make_repo`)

**Interfaces:**
- Produces: `scripts/backmerge.sh <source-branch> <target-branch>` run inside a clone with `origin` set. Exit `0` when target now contains source (fast-forward, merge commit, or already up to date). Exit `2` on merge conflict after aborting the merge and leaving the tree clean. Exit `3` when the target branch does not exist on `origin`. Env `BACKMERGE_AUTHOR` (default `Craft CI <craft-ci@netlife.no>`) sets the merge commit author. The script never opens PRs; the workflow does that on exit `2`.

- [ ] **Step 1: Write the failing tests**

`tests/backmerge.test.sh` creates a bare `origin` and a clone with `main` and `develop`, then:

```bash
test_fast_forward      # develop behind main, no own commits → exit 0, origin/develop == origin/main
test_merge_commit      # develop has its own commit → exit 0, origin/develop has both, parents == 2
test_already_contains  # develop == main → exit 0, no new commit on origin/develop
test_conflict          # both edit the same line → exit 2, `git status --porcelain` empty afterwards, origin/develop unchanged
test_missing_target    # no develop on origin → exit 3, nothing pushed
test_runs_twice        # run test_conflict scenario twice → second run also exit 2, still one commit on origin/develop
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/backmerge.test.sh`
Expected: FAIL, `scripts/backmerge.sh: No such file`

- [ ] **Step 3: Implement `scripts/backmerge.sh`**

Fetch both branches, `git checkout -B "$target" "origin/$target"`, `git merge --no-edit "origin/$source"` with author from env; on conflict `git merge --abort` and exit 2; on success `git push origin "$target"`. Detect a missing target with `git ls-remote --exit-code --heads origin "$target"` before anything else.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/backmerge.test.sh`
Expected: `6 passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/backmerge.sh tests/backmerge.test.sh tests/lib.sh
git commit -m "Add backmerge script with local tests"
```

### Task 2: Reusable back-merge workflow

**Files:**
- Create: `.github/workflows/backmerge.yml`
- Modify: `README.md` (new section "Back-merge to develop")

**Interfaces:**
- Consumes: `scripts/backmerge.sh` exit codes from Task 1.
- Produces: reusable workflow `netliferesearch/craft-ci/.github/workflows/backmerge.yml@v1` with `workflow_call` inputs `source-branch` (default `main`) and `target-branch` (default `develop`). Job permissions `contents: write`, `pull-requests: write`.

- [ ] **Step 1: Write the workflow**

Steps: checkout caller repo with `fetch-depth: 0`; checkout `netliferesearch/craft-ci` at `v1` into `.craft-ci`; run `bash .craft-ci/scripts/backmerge.sh "$SOURCE" "$TARGET"` capturing the exit code without failing the step; on exit `2`: if `gh pr list --base "$TARGET" --head "$SOURCE" --state open --json number --jq length` is `0`, run `gh pr create --base "$TARGET" --head "$SOURCE" --title "Back-merge $SOURCE" --body "Automatic back-merge conflicted. Resolve and merge."`, then `exit 1`; on exit `3`: print `target branch $TARGET not found on origin` and `exit 1`; on `0`: done. `GH_TOKEN: ${{ github.token }}`.

- [ ] **Step 2: Lint**

Run: `actionlint .github/workflows/backmerge.yml` (install with `brew install actionlint` if missing)
Expected: no output, exit 0

- [ ] **Step 3: Document**

README section "Back-merge to develop": what it does, the six-line caller (see Task 8 for the exact caller), conflict behaviour.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/backmerge.yml README.md
git commit -m "Add reusable back-merge workflow"
```

### Task 3: Project-config commit script

**Files:**
- Create: `scripts/commit-project-config.sh`
- Create: `tests/commit-project-config.test.sh`

**Interfaces:**
- Produces: `scripts/commit-project-config.sh` run inside the verify checkout (detached merge commit). Env: `HEAD_REF` (PR head branch), `HEAD_REPO` and `BASE_REPO` (`owner/name`), `PUSH_URL` (remote URL carrying the token, e.g. `https://x-access-token:TOKEN@github.com/owner/name.git`), `CI_AUTHOR` (default `Craft CI <craft-ci@netlife.no>`), `PATHS` (default `config/project`). Exit `0` with `changed=false` on stdout when nothing under `PATHS` changed; exit `0` with `changed=true` after a successful push; exit `4` when changes exist but `PUSH_URL` is empty (prints the diff); exit `5` when `HEAD_REPO != BASE_REPO` (prints the diff, pushes nothing); exit `6` when applying the change onto the head branch conflicts (tree left clean, nothing pushed).

- [ ] **Step 1: Write the failing tests**

```bash
test_no_change          # clean tree → exit 0, stdout "changed=false"
test_commits_and_pushes # modify config/project/project.yaml → exit 0, origin/<HEAD_REF> has 1 new commit by craft-ci@netlife.no with message "Update project config after dependency update", file content matches
test_no_token           # change present, PUSH_URL="" → exit 4, diff on stdout, origin unchanged
test_fork_refused       # HEAD_REPO=other/repo → exit 5, origin unchanged
test_conflict           # head branch moved and edited the same yaml line after the merge commit was built → exit 6, `git status --porcelain` empty, origin unchanged
```

Fixture: bare origin with `main` and branch `renovate/craft-patches`; the clone checks out a detached merge of the two, as verify's `actions/checkout` does.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/commit-project-config.test.sh`
Expected: FAIL, script missing

- [ ] **Step 3: Implement `scripts/commit-project-config.sh`**

Order: `git status --porcelain -- $PATHS` empty → `changed=false`, exit 0. Then the refusals (exit 5, then exit 4), each printing `git diff -- $PATHS` first. Then: `git stash push -- $PATHS`, `git fetch origin "$HEAD_REF"`, `git checkout -B "$HEAD_REF" FETCH_HEAD`, `git stash pop` (on failure: `git checkout -- . && git stash drop`, exit 6), `git -c user.name=... -c user.email=... commit -am "Update project config after dependency update"` with name and email split from `CI_AUTHOR`, `git push "$PUSH_URL" "HEAD:refs/heads/$HEAD_REF"`, print `changed=true`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/commit-project-config.test.sh`
Expected: `5 passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/commit-project-config.sh tests/commit-project-config.test.sh
git commit -m "Add project-config commit script with local tests"
```

### Task 4: Wire the commit step into the verify action and release

**Files:**
- Modify: `action.yml` (inputs block; new step after "Migrate and apply project config")
- Modify: `README.md` ("What the action does" list and inputs paragraph)

**Interfaces:**
- Consumes: `scripts/commit-project-config.sh` env contract from Task 3.
- Produces: action inputs `commit-project-config` (default `"false"`) and `push-token` (default `""`). The step runs only when `inputs.commit-project-config == 'true' && github.event_name == 'pull_request'`. It exports `HEAD_REF=${{ github.event.pull_request.head.ref }}`, `HEAD_REPO=${{ github.event.pull_request.head.repo.full_name }}`, `BASE_REPO=${{ github.repository }}`, and `PUSH_URL` built as `https://x-access-token:${PUSH_TOKEN}@github.com/${BASE_REPO}.git` only when `PUSH_TOKEN` is non-empty, else empty. Output `project-config-changed` (`true`/`false`) from the script's stdout.

- [ ] **Step 1: Add the inputs and the step**

Step name "Commit project config to the PR branch". Mask the token with `::add-mask::` before building the URL. The step fails on script exit 4, 5 or 6 (default `set -e` behaviour), so an uncommitted change can never merge silently.

- [ ] **Step 2: Lint and smoke**

Run: `actionlint action.yml` → exit 0.
Run: `bash tests/backmerge.test.sh && bash tests/commit-project-config.test.sh` → all pass.

- [ ] **Step 3: Document**

README: add step "7. If `commit-project-config` is on and `craft up` changed `config/project`, commit it back to the PR branch with `push-token`" and the two inputs in the "Inputs worth knowing" paragraph, including why the token must trigger workflows.

- [ ] **Step 4: Commit, push, move the `v1` tag**

```bash
git add action.yml README.md
git commit -m "Add commit-project-config and push-token inputs"
git push origin main
git tag -f v1 && git push origin -f v1
```

Expected: `git ls-remote --tags origin v1` shows the new commit.

### Task 5: Renovate repo files (local)

**Files:**
- Create (new local repo `~/code/renovate`): `default.json`, `config.js`, `.github/workflows/renovate.yml`, `README.md`, `tests/validate.sh`

**Interfaces:**
- Produces: preset `github>netliferesearch/renovate`; workflow `renovate.yml` with `workflow_dispatch` input `dry-run` (choice `none|full`, default `none`) and a daily schedule `0 2 * * *` UTC; job `environment: renovate`.

- [ ] **Step 1: Write `tests/validate.sh` (the failing test)**

```bash
npx --yes --package renovate -- renovate-config-validator --strict default.json
RENOVATE_CONFIG_FILE=config.js npx --yes --package renovate -- renovate-config-validator --strict
actionlint .github/workflows/renovate.yml
# the CI author email in craft-ci and gitIgnoredAuthors here must match
grep -q '"craft-ci@netlife.no"' default.json
```

Run: `bash tests/validate.sh` → fails, files missing.

- [ ] **Step 2: Write `default.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "description": "Netlife Craft CMS update policy. Sites extend this with one line.",
  "enabledManagers": ["composer"],
  "timezone": "Europe/Oslo",
  "rangeStrategy": "update-lockfile",
  "dependencyDashboard": true,
  "labels": ["renovate"],
  "prConcurrentLimit": 3,
  "gitIgnoredAuthors": ["craft-ci@netlife.no"],
  "vulnerabilityAlerts": { "enabled": true, "labels": ["renovate", "security"] },
  "packageRules": [
    { "matchManagers": ["composer"], "matchUpdateTypes": ["patch"], "groupName": "Craft patches", "schedule": ["before 6am on monday"], "automerge": false },
    { "matchManagers": ["composer"], "matchUpdateTypes": ["minor"], "groupName": "Craft minors", "schedule": ["before 6am on the first day of the month"], "automerge": false },
    { "matchManagers": ["composer"], "matchUpdateTypes": ["major"], "enabled": false },
    { "matchManagers": ["composer"], "isVulnerabilityAlert": true, "matchUpdateTypes": ["patch"], "automerge": false }
  ]
}
```

If the validator rejects `isVulnerabilityAlert`, replace that rule with `"vulnerabilityAlerts": { ..., "automerge": false }` and note in the README that vulnerability automerge then applies to all update types; the Task 10 flip changes that same key.

- [ ] **Step 3: Write `config.js`**

```js
module.exports = {
  platform: 'github',
  repositories: ['Feedsystem/nch'],
  onboarding: true,
  onboardingConfig: { $schema: 'https://docs.renovatebot.com/renovate-schema.json', extends: ['github>netliferesearch/renovate'] },
  allowPlugins: true,
  allowScripts: true,
  dryRun: process.env.DRY_RUN === 'full' ? 'full' : null,
};
```

- [ ] **Step 4: Write `.github/workflows/renovate.yml`**

One job `renovate`, `runs-on: ubuntu-latest`, `environment: renovate`, `timeout-minutes: 30`. Steps: `actions/checkout@v4`; `renovatebot/github-action` pinned to its latest release tag at build time (v46.x), with `configurationFile: config.js`, `token: ${{ secrets.RENOVATE_TOKEN }}`, `renovate-version` pinned to the latest full Renovate version at build time; `env: LOG_LEVEL: info`, `DRY_RUN: ${{ inputs.dry-run || 'none' }}`, and `env-regex` extended with `|DRY_RUN` so the variable reaches `config.js`. Record both pinned versions in the README.

- [ ] **Step 5: Write `README.md`**

Sections: what this repo is, how a site adopts it (the `renovate.json` from the spec), the policy table (patch weekly automerge, minor monthly manual, major off, vulnerability immediate), where the token lives and its permission list (spec "Token" plus `Commit statuses: read and write`, `Dependabot alerts: read`, `Members: read` per Renovate docs), how to run a dry run (`gh workflow run renovate.yml -f dry-run=full`), and the pinned versions.

- [ ] **Step 6: Run the validation**

Run: `bash tests/validate.sh`
Expected: `Config validated successfully` twice, actionlint silent, grep exit 0.

- [ ] **Step 7: Commit**

```bash
git init -b main && git add -A && git commit -m "Renovate preset, runner config and workflow for the nch pilot"
```

### Task 6: Renovate repo on GitHub, token, dry run

**Files:** none in git. GitHub settings on `netliferesearch/renovate`.

**Interfaces:**
- Consumes: the local repo from Task 5.
- Produces: `https://github.com/netliferesearch/renovate` public, `main` protected, environment `renovate` with secret `RENOVATE_TOKEN`, one dry-run log.

- [ ] **Step 1: Create and push**

```bash
gh repo create netliferesearch/renovate --public --source . --push --description "Renovate preset and runner for Netlife's Craft sites"
```

- [ ] **Step 2: Protect `main` and create the environment**

```bash
gh api -X PUT repos/netliferesearch/renovate/branches/main/protection --input - <<'JSON'
{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null}
JSON
gh api -X PUT repos/netliferesearch/renovate/environments/renovate --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}
JSON
```

Expected: both return 200. If the API refuses `required_approving_review_count: 0`, use `1` and note that Svale approves his own PRs via admin bypass.

- [ ] **Step 3: Create the token (manual, Svale)**

GitHub → Settings → Developer settings → Fine-grained tokens. Resource owner `Feedsystem`, repository `nch` only, expiry 90 days. Repository permissions: Contents RW, Pull requests RW, Issues RW, Workflows RW, Commit statuses RW, Dependabot alerts R, Metadata R. Organization permission: Members R. If Feedsystem blocks fine-grained tokens, create a classic token with `repo` and `workflow`.

- [ ] **Step 4: Store the secret**

```bash
gh secret set RENOVATE_TOKEN --repo netliferesearch/renovate --env renovate
```

(paste the token at the prompt). Verify: `gh secret list --repo netliferesearch/renovate --env renovate` lists it. Check the Actions policy: `gh api repos/netliferesearch/renovate/actions/permissions --jq .allowed_actions` must be `all` or include `renovatebot/*`; otherwise switch the workflow to a `container: ghcr.io/renovatebot/renovate:<version>` job running `renovate` directly (same env), and rerun Task 5 step 6.

- [ ] **Step 5: Dry run**

```bash
gh workflow run renovate.yml --repo netliferesearch/renovate -f dry-run=full
gh run watch --repo netliferesearch/renovate $(gh run list --repo netliferesearch/renovate -L1 --json databaseId --jq '.[0].databaseId')
gh run view --repo netliferesearch/renovate --log | grep -E 'DRY-RUN|Craft patches|Craft minors|onboarding|composer' | head -50
```

Expected: the log names `Feedsystem/nch`, says onboarding would be created, lists Composer dependencies with update types, and opens nothing on nch (`gh pr list --repo Feedsystem/nch` unchanged).

### Task 7: nch repository settings

**Files:** none in git. GitHub settings on `Feedsystem/nch`.

**Interfaces:**
- Produces: branch protection on `main` requiring `verify`, auto-merge allowed, Dependabot alerts on, repo secret `RENOVATE_PUSH_TOKEN`.

- [ ] **Step 1: Apply the settings**

```bash
gh api -X PATCH repos/Feedsystem/nch -F allow_auto_merge=true
gh api -X PUT repos/Feedsystem/nch/vulnerability-alerts
gh api -X PUT repos/Feedsystem/nch/branches/main/protection --input - <<'JSON'
{"required_status_checks":{"strict":true,"contexts":["verify"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}
JSON
gh secret set RENOVATE_PUSH_TOKEN --repo Feedsystem/nch
```

(same token value as Task 6.)

- [ ] **Step 2: Verify**

```bash
gh api repos/Feedsystem/nch --jq '{allow_auto_merge, allow_squash_merge, has_issues}'
gh api repos/Feedsystem/nch/vulnerability-alerts -i | head -1
gh api repos/Feedsystem/nch/branches/main/protection --jq '.required_status_checks'
```

Expected: `allow_auto_merge: true`, `HTTP/2.0 204`, `{"strict":true,"contexts":["verify"],...}`.

- [ ] **Step 3: Tell the team**

Message in the nch channel: direct pushes to `main` now need a PR with a green verify; `develop` is back-merged automatically after each merge to `main`.

### Task 8: nch workflow files

**Files:**
- Create (in `~/code/nch`): `.github/workflows/backmerge.yml`
- Modify: `.github/workflows/verify.yml`

**Interfaces:**
- Consumes: reusable workflow from Task 2, action inputs from Task 4.

- [ ] **Step 1: Write the caller**

```yaml
name: Back-merge
on:
  push:
    branches: [main]
jobs:
  backmerge:
    uses: netliferesearch/craft-ci/.github/workflows/backmerge.yml@v1
    permissions:
      contents: write
      pull-requests: write
```

- [ ] **Step 2: Extend verify.yml**

Add under `with:`:

```yaml
          commit-project-config: "true"
          push-token: ${{ secrets.RENOVATE_PUSH_TOKEN }}
```

- [ ] **Step 3: Lint, branch, PR**

Run: `actionlint .github/workflows/*.yml` → exit 0.

```bash
git checkout -b ci/backmerge-and-project-config
git add .github/workflows && git commit -m "Add back-merge to develop and project config commit in verify"
git push -u origin HEAD && gh pr create --fill
```

Expected: verify runs on the PR and is green (no project config change on a workflow-only PR, step prints `changed=false`).

- [ ] **Step 4: Merge and watch the back-merge**

```bash
gh pr merge --squash --auto
gh run list --repo Feedsystem/nch --workflow Back-merge -L1
git fetch origin && git rev-list --count origin/develop..origin/main
```

Expected: Back-merge run green, count `0` (develop now contains main).

### Task 9: Onboarding and the first grouped PR by hand

**Files:** none authored by us. Renovate opens the PRs.

- [ ] **Step 1: Real run**

```bash
gh workflow run renovate.yml --repo netliferesearch/renovate
```

Expected within a few minutes: PR "Configure Renovate" on nch containing `renovate.json` with the one-line extends, and a Dependency Dashboard issue. Verify runs on it and is green.

- [ ] **Step 2: Merge onboarding**

`gh pr merge <n> --repo Feedsystem/nch --squash --auto`. Back-merge runs green.

- [ ] **Step 3: First "Craft patches" PR**

Either wait for the next Monday run or dispatch with `-f dry-run=none` on a Monday before 06:00 Oslo. Check:

```bash
gh pr view <n> --repo Feedsystem/nch --json title,labels,statusCheckRollup,commits
```

Expected: title `Update Craft patches` (or Renovate's group title), label `renovate`, check `verify` success. If `craft up` changed project config, the PR has a second commit by `Craft CI <craft-ci@netlife.no>` and verify ran again on it. Confirm Renovate did not mark the PR as modified: the PR body has no "edited/blocked" notice and `gh pr view --json autoMergeRequest` is unaffected.

- [ ] **Step 4: Merge by hand, confirm deploy**

Merge with squash. Forge deploys; open the site's Deployments tab, status `success`. Back-merge run green. Note timings in the fleet design's Pilot log.

### Task 10: Forge hardening and automerge on

**Files:**
- Modify (renovate repo): `default.json`
- Forge: nch site deploy script and site settings (manual, Svale)

- [ ] **Step 1: Forge (Svale)**

Deploy script: add `set -e` as the first line and `php craft db/backup` immediately before `php craft migrate/all`. Site → Notifications: enable Slack to the team channel. Site → Settings → Deployments: enable Health check with the front page URL. Run "Deploy now" once and confirm `success` and a Slack message.

- [ ] **Step 2: Flip automerge**

In `default.json`, set `"automerge": true` on the `Craft patches` rule and on the vulnerability rule. Run `bash tests/validate.sh`, open a PR on the renovate repo, merge it.

- [ ] **Step 3: Acceptance**

Next patch window: the PR opens, verify is green, the PR merges without a human (`gh pr view --json mergedBy` shows the token user with `autoMergeRequest` set), Forge deploys `success`, back-merge green, Dependency Dashboard shows no pending patch. Record the date in the spec's "Done when" line and in the Pilot log.
