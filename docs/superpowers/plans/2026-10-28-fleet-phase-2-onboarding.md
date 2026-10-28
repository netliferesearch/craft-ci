# Fleet Phase 2 (Onboarding Script, nfi) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `scripts/onboard.sh` onboards a site into the fleet (or reports its drift), and Feedsystem/nfi on Craft Cloud is onboarded with it: green `verify / verify`, a nightly scrubbed snapshot, back-merge, Renovate.

**Architecture:** Two scripts in craft-ci. `scripts/onboard-files.sh` works on a local checkout only: detects host and backup template, compares or writes `.netlife/fleet.json` and the three callers (copied verbatim from `examples/`), checks DDEV's database and the scrub file. `scripts/onboard.sh` is the entry point: it gets a checkout, calls `onboard-files.sh`, checks and applies repo settings through `gh`, checks secret names, opens or updates the onboarding PR, and prints the manual steps. The reusable verify workflow gains four optional Craft Cloud secrets.

**Tech Stack:** bash, `gh`, `jq`, git, the `tests/lib.sh` harness, `actionlint`, system ruby for YAML reads in tests. No yq.

**Spec:** `docs/superpowers/specs/2026-10-28-fleet-phase-2-onboarding-design.md` (and, for anything it does not change, `docs/superpowers/specs/2026-10-20-fleet-config-simplification-design.md`).

## Global Constraints

- The script never writes, overwrites or deletes a secret value: no `gh secret set|delete`, no `gh variable set|delete`. It reads names only.
- Nothing writes to a production database or changes a host's deploy settings.
- Topic: `netlife-fleet`. Required check: `verify / verify`, strict, no required reviews.
- Craft Cloud secret names: `CRAFT_CLOUD_PROJECT_ID`, `CRAFT_CLOUD_ENVIRONMENT_ID`, `CRAFT_CLOUD_USE_ASSET_CDN`, `CRAFT_CLOUD_SIGNING_KEY`.
- Backup template detection: `.github/workflows/backup-database.yml` exists; its secrets are `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.
- Host detection: `craft-cloud.yaml` at the repo root means `cloud`; otherwise `--host forge|servebolt` is required (exit 2 without it).
- Expected DDEV database: `type: mysql`, `version: "8.0"`.
- PR title: `Adopt craft-ci fleet configuration`. Branch: `netlife/fleet-onboarding`.
- Callers are byte-for-byte copies of files in `examples/`; nch's current callers equal `examples/verify.yml`, `examples/snapshot.yml`, `examples/backmerge.yml` and must keep doing so.
- All shell: `set -euo pipefail`, no prompts, every failure prints why and exits non-zero.
- Subagents do not push, open PRs, move tags or change GitHub settings; the controlling session does, with Svale's go-ahead. Node 24 via nvm if Node is needed. Do not read `.env*` files in any repo.

## Review Focus

1. **Existing manifest with keys the script would not write** (nch's `verify.ignoreLogPattern` and `preview` block) must count as no drift. Test in Task 2 (`test_existing_manifest_kept`).
2. **Existing branch protection with other required checks** must keep them when `--apply` adds `verify / verify`. Test in Task 3 (`test_apply_protection_keeps_contexts`).
3. **Org secrets the token cannot list** must not fail the run: a shared secret absent at repo level is reported as `todo` with "may exist at org level". Test in Task 3 (`test_org_secrets_unreadable`).
4. **Re-running `--apply` while the onboarding PR is open** updates its branch, never opens a second PR. Test in Task 3 (`test_apply_reuses_open_pr`).
5. **A cloud site without the backup template** gets the plain snapshot caller and needs `SOURCE_DB_*`. Test in Task 2 (`test_cloud_without_backup`) and Task 3 (`test_secrets_cloud_without_backup`).

---

### Task 1: Craft Cloud secrets in verify, cloud example callers

**Files:**
- Modify: `.github/workflows/verify.yml`
- Create: `examples/verify-cloud.yml`, `examples/snapshot-cloud-backup.yml`
- Modify: `tests/workflows.test.sh`

**Interfaces:**
- Produces: reusable verify accepts optional secrets `CRAFT_CLOUD_PROJECT_ID`, `CRAFT_CLOUD_ENVIRONMENT_ID`, `CRAFT_CLOUD_USE_ASSET_CDN`, `CRAFT_CLOUD_SIGNING_KEY` and appends `NAME=value` to `.env` for each one that is non-empty, after `inputs.extra-env`. `examples/verify-cloud.yml` = `examples/verify.yml` plus those four mappings. `examples/snapshot-cloud-backup.yml` = `examples/snapshot.yml` with `SOURCE_DB_HOST: ${{ secrets.DB_HOST }}` (likewise `_NAME`, `_USER`, `_PASSWORD`), no `SOURCE_SSH_*` lines, a header comment saying it reuses the backup template's database secrets.

- [ ] **Step 1: Update the tests**

In `tests/workflows.test.sh`:
- `test_verify_declares_secrets` expects `CRAFT_CLOUD_ENVIRONMENT_ID CRAFT_CLOUD_PROJECT_ID CRAFT_CLOUD_SIGNING_KEY CRAFT_CLOUD_USE_ASSET_CDN RENOVATE_APP_PRIVATE_KEY RENOVATE_PUSH_TOKEN SNAPSHOT_READ_KEY SNAPSHOT_READ_SECRET`.
- `test_examples_map_every_secret` becomes table-driven over (workflow, example, exempt names): `verify`/`verify.yml` exempt the four `CRAFT_CLOUD_*`; `verify`/`verify-cloud.yml` exempt none; `snapshot`/`snapshot.yml` none; `snapshot`/`snapshot-cloud-backup.yml` exempt `SOURCE_SSH_HOST SOURCE_SSH_USER SOURCE_SSH_KEY`. Each example maps exactly declared minus exempt.
- New `test_cloud_snapshot_maps_backup_names`: in `snapshot-cloud-backup.yml`, `SOURCE_DB_HOST` maps to `${{ secrets.DB_HOST }}` and likewise for `NAME`, `USER`, `PASSWORD`.
- New `test_verify_appends_cloud_env`: the `extra-env` value passed to the action in `verify.yml` contains each of the four names.
- New `test_forge_examples_unchanged`: `git show HEAD:examples/verify.yml` equals the working file (same for `snapshot.yml`, `backmerge.yml`), so nch stays drift-free.

- [ ] **Step 2: Run, expect the new and changed tests to fail**

Run: `bash tests/workflows.test.sh`
Expected: FAIL on `test_verify_declares_secrets`, `test_examples_map_every_secret`, `test_cloud_snapshot_maps_backup_names`, `test_verify_appends_cloud_env`.

- [ ] **Step 3: Implement**

Declare the four secrets (`required: false`, one-line descriptions). Build the action's `extra-env` as a block scalar: `${{ inputs.extra-env }}` followed by one line per secret using `format('NAME={0}', secrets.NAME)` guarded so an empty secret yields an empty line (blank lines in `.env` are harmless; `action.yml` already appends `extra-env` verbatim). Write the two examples.

- [ ] **Step 4: Run, expect pass**

Run: `bash tests/workflows.test.sh && actionlint .github/workflows/*.yml examples/*.yml`
Expected: all ok, actionlint silent.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/verify.yml examples/verify-cloud.yml examples/snapshot-cloud-backup.yml tests/workflows.test.sh
git commit -m "Verify passes Craft Cloud asset values; cloud example callers"
```

---

### Task 2: `scripts/onboard-files.sh` (local checks and writes)

**Files:**
- Create: `scripts/onboard-files.sh`
- Test: `tests/onboard-files.test.sh`

**Interfaces:**
- Consumes: `examples/*.yml` from Task 1, `scripts/manifest.sh`.
- Produces: `onboard-files.sh <checkout-dir> [--host forge|servebolt|cloud] [--slug S] [--develop B|none] [--write]`. Prints one line per check to stdout, each starting with `ok`, `diff` or `todo` followed by a space, a check name and `: detail`. Last line `host=<host> backup=<yes|no>` (consumed by Task 3). Exit 0 when no `diff`/`todo`, 1 when any, 2 on usage error or host not determinable. With `--write`, fixes every `diff` it owns (files) in the checkout's working tree, does not commit, and reports the fixed ones as `ok … (written)`.
- Check names: `manifest`, `caller verify`, `caller snapshot`, `caller backmerge`, `ddev database`, `scrub`, `legacy preview config`.

Behaviour the tests pin:
- Callers: verify ← `verify-cloud.yml` on cloud, else `verify.yml`; snapshot ← `snapshot-cloud-backup.yml` on cloud with backup template, else `snapshot.yml`; backmerge ← `backmerge.yml`. A caller that differs from its example in any byte is `diff`.
- Manifest absent: `diff`; `--write` creates `{"$schema": "https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json"}` plus `slug` only when `--slug` is given and differs from the repo-derived default, plus `"branches": {"develop": null}` only for `--develop none`. Pretty-printed with `jq .`. The repo name comes from `GITHUB_REPOSITORY`, which Task 3 sets.
- Manifest present: run `manifest.sh` with `MANIFEST_NO_REMOTE=1`; exit ≠ 0 is `diff` with its stderr; when `--slug`/`--develop` are given and the resolved `SLUG`/`BRANCH_DEVELOP` differ, `diff`. Never rewritten by `--write`.
- `ddev database`: `.ddev/config.yaml` without `type: mysql` and `version: "8.0"` under `database:` is `todo` (never written). No `.ddev/` is `todo` too.
- `scrub`: `.netlife/scrub.sql` absent is `todo` with detail `write and review .netlife/scrub.sql before merging (the snapshot runs without it)`.
- `legacy preview config`: `.craft-preview.json` present is `diff`; `--write` deletes it.

- [ ] **Step 1: Write the failing tests** in `tests/onboard-files.test.sh` (use `make_repo`, write files into `$T/work`, `run_in_work`):

- `test_nch_shape_is_clean`: checkout with nch's manifest (`slug`, `verify.ignoreLogPattern`, `preview` block), the three Forge examples copied, MySQL 8.0 ddev config, a scrub file, `--host forge` → exit 0, every check `ok`, last line `host=forge backup=no`.
- `test_existing_manifest_kept`: same as above with `--write`; `.netlife/fleet.json` byte-identical afterwards.
- `test_cloud_with_backup_writes_cloud_callers`: `craft-cloud.yaml` and `.github/workflows/backup-database.yml` present, nothing else; `--write` → `verify.yml` equals `examples/verify-cloud.yml`, `snapshot.yml` equals `examples/snapshot-cloud-backup.yml`, manifest equals the `$schema`-only object, last line `host=cloud backup=yes`.
- `test_cloud_without_backup`: `craft-cloud.yaml` only; `--write` → `snapshot.yml` equals `examples/snapshot.yml`.
- `test_host_required_without_cloud_file`: no `craft-cloud.yaml`, no `--host` → exit 2, stderr names `--host`.
- `test_mariadb_is_todo`: ddev `type: mariadb` → line starting `todo ddev database`, exit 1; `--write` leaves `.ddev/config.yaml` unchanged.
- `test_missing_scrub_is_todo`: line `todo scrub: write and review .netlife/scrub.sql before merging (the snapshot runs without it)`.
- `test_slug_flag_differs`: existing manifest with `slug: abc`, `--slug xyz` → `diff manifest`.
- `test_develop_none_written`: no manifest, `--develop none --write` → `.branches.develop == null` in the written file.
- `test_legacy_preview_removed`: `.craft-preview.json` present, `--write` → file gone.
- `test_caller_one_byte_off`: verify caller with a trailing space added → `diff caller verify`.

- [ ] **Step 2: Run, expect fail**

Run: `bash tests/onboard-files.test.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `scripts/onboard-files.sh`** per the interface above. Read the ddev database block with a small awk over the `database:` section (no yq). Locate examples relative to the script (`$(dirname "$0")/../examples`).

- [ ] **Step 4: Run, expect pass**

Run: `bash tests/onboard-files.test.sh`
Expected: all ok.

- [ ] **Step 5: Commit**

```bash
git add scripts/onboard-files.sh tests/onboard-files.test.sh
git commit -m "onboard-files.sh: compare or write a site's manifest and callers"
```

---

### Task 3: `scripts/onboard.sh` (GitHub settings, secrets, PR, manual steps)

**Files:**
- Create: `scripts/onboard.sh`
- Test: `tests/onboard.test.sh` (with a `gh` stub written into `$T/bin` and put first on `PATH`)

**Interfaces:**
- Consumes: `onboard-files.sh` (Task 2): its check lines and final `host=… backup=…` line.
- Produces: `onboard.sh <owner>/<repo> [--slug S] [--develop B|none] [--host H] [--apply]`. Env `ONBOARD_CHECKOUT=<dir>` uses an existing checkout instead of `gh repo clone` (tests, and a local re-run). Output: the `onboard-files.sh` lines, then its own `ok|diff|todo|note <check>: detail` lines. Exit 0 when no `diff`/`todo`, 1 otherwise, 2 on usage error. `note` never affects the exit code.

Checks and `--apply` actions (all `gh api` against `repos/<owner>/<repo>` unless noted):

| Check | Reads | `--apply` |
| --- | --- | --- |
| `topic` | `topics` contains `netlife-fleet` | `gh repo edit --add-topic netlife-fleet` |
| `protection` | `branches/main/protection`: contexts include `verify / verify`, `strict` true, `required_pull_request_reviews` null; 404 = absent | PUT protection with existing contexts ∪ `verify / verify`, `strict: true`, `enforce_admins: false`, `required_pull_request_reviews: null`, `restrictions: null` |
| `auto-merge` | `.allow_auto_merge` | PATCH `allow_auto_merge=true` |
| `dependabot alerts` | `vulnerability-alerts` 204 vs 404 | PUT `vulnerability-alerts` |
| `actions create PRs` | `actions/permissions/workflow` `.can_approve_pull_request_reviews` | PUT with `can_approve_pull_request_reviews=true` (keep `default_workflow_permissions`) |
| `renovate` | `repos/netliferesearch/renovate/contents/config.js` contains `'<owner>/<repo>'` | none; `todo` "add to repositories in netliferesearch/renovate config.js" |
| `secret <NAME>` | names from `gh secret list --repo`, `gh variable list --repo`, `repos/<r>/actions/organization-secrets`, `…/organization-variables` | none; missing = `todo` |
| `files` | `onboard-files.sh` result | branch `netlife/fleet-onboarding`, `onboard-files.sh --write`, commit, push, open PR titled `Adopt craft-ci fleet configuration`, or push to the branch of the open PR with that title |

Required secret names, from the spec's table: `SNAPSHOT_WRITE_KEY`, `SNAPSHOT_WRITE_SECRET`, `SNAPSHOT_READ_KEY`, `SNAPSHOT_READ_SECRET` always (repo or org); cloud: the four `CRAFT_CLOUD_*`; cloud with backup: `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`; otherwise `SOURCE_DB_HOST`, `_NAME`, `_USER`, `_PASSWORD`; forge/servebolt also `SOURCE_SSH_HOST`, `_USER`, `_KEY`. App: when variable `RENOVATE_APP_CLIENT_ID` and secret `RENOVATE_APP_PRIVATE_KEY` are both visible (repo or org), `RENOVATE_PUSH_TOKEN` is not required; otherwise it is. When an org endpoint fails (403/404), a missing shared name is `todo … (missing on repo, may exist at org level)`.

Notes always printed: `note app: confirm the GitHub App installation includes <repo>`, `note deploy: confirm the host deploys from main`. When the PR is open: `note pr: merge <url> once verify / verify is green`.

- [ ] **Step 1: Write the failing tests.** The stub `gh` logs its arguments (one call per line) to `$T/gh.log` and answers from a per-test table (`$T/gh/<key>` files where key is a sanitised argument string, missing file = exit 1 with "HTTP 404"). Tests:

- `test_clean_repo_exits_zero`: every read reports compliant, all secrets present, `onboard-files.sh` clean → exit 0, no `diff`/`todo` lines, both `note` lines present.
- `test_dry_run_changes_nothing`: non-compliant everything, no `--apply` → exit 1, and `gh.log` contains no `-X PUT`, `-X PATCH`, `repo edit`, `pr create`; `git -C origin` has no `netlife/fleet-onboarding` branch.
- `test_apply_protection_keeps_contexts`: protection has contexts `["build"]` → the PUT body has contexts containing `build` and `verify / verify`.
- `test_apply_never_sets_secrets`: `--apply` with secrets missing → `gh.log` contains no `secret set`, `secret delete`, `variable set`, `variable delete`.
- `test_apply_reuses_open_pr`: `pr list` returns an open PR with the title → no `pr create` in the log, branch pushed to origin.
- `test_apply_opens_pr`: no open PR → exactly one `pr create` with `--title Adopt craft-ci fleet configuration`.
- `test_org_secrets_unreadable`: org endpoints 403, `SNAPSHOT_READ_KEY` not on repo → line `todo secret SNAPSHOT_READ_KEY: missing on repo, may exist at org level`.
- `test_secrets_cloud_with_backup`: host cloud, backup yes → required set contains `DB_HOST`, not `SOURCE_DB_HOST`, not `SOURCE_SSH_KEY`.
- `test_secrets_cloud_without_backup`: host cloud, backup no → requires `SOURCE_DB_HOST`, not `SOURCE_SSH_KEY`.
- `test_app_configured_drops_push_token`: variable and private key present, `RENOVATE_PUSH_TOKEN` absent → no `todo secret RENOVATE_PUSH_TOKEN`.
- `test_renovate_missing_is_todo`: config.js without the repo → `todo renovate: …`.

- [ ] **Step 2: Run, expect fail**

Run: `bash tests/onboard.test.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `scripts/onboard.sh`.** Clone with `gh repo clone <r> <tmp> -- -q` unless `ONBOARD_CHECKOUT` is set; when the checkout is already on `netlife/fleet-onboarding`, commit there instead of creating the branch (Task 6 relies on this; add `test_apply_on_existing_branch`); export `GITHUB_REPOSITORY=<r>` for `onboard-files.sh`. Settings first, then files and PR, then secrets, then notes, so the PR URL is known for the last note.

- [ ] **Step 4: Run, expect pass**

Run: `bash tests/onboard.test.sh && bash tests/onboard-files.test.sh`
Expected: all ok.

- [ ] **Step 5: Commit**

```bash
git add scripts/onboard.sh tests/onboard.test.sh
git commit -m "onboard.sh: fleet onboarding and drift check for one site"
```

---

### Task 4: Docs, schema defaults, release

**Files:**
- Modify: `README.md`, `fleet.schema.json`, `tests/workflows.test.sh` (or a new `tests/schema.test.sh`)

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces: README sections Svale and the onboarding note link to; `v1` at the new main.

- [ ] **Step 1: Failing test** `test_example_manifest_resolves`: `bash scripts/manifest.sh examples/fleet.json` with `GITHUB_REPOSITORY=Feedsystem/nch MANIFEST_NO_REMOTE=1` exits 0 and prints `SLUG=nch` (phase 1 follow-up F).

- [ ] **Step 2: Run, expect fail if the resolver rejects the example; otherwise keep it as a guard and continue.**

Run: `bash tests/workflows.test.sh`

- [ ] **Step 3: Edit**
- README: an "Onboarding a site" section: the dry run, `--apply`, the output prefixes and exit codes, what stays manual (secrets, Renovate `config.js`, App, scrub review, deploy branch). Hosting table: a Craft Cloud row (direct connection, backup template `DB_*` reused, `CRAFT_CLOUD_*` values, `examples/verify-cloud.yml`, `examples/snapshot-cloud-backup.yml`); `SOURCE_SSH_*` names in the Forge and Servebolt rows. Phase 1 follow-ups T5: "four callers" wording, back-merge "if the configured target branch does not exist", verify does a fresh install when `snapshot.source` is `none`, intro mentions the reusable workflows; F: `examples/backmerge.yml` triggers on `main` while `branches.main` may differ.
- `fleet.schema.json`: `default` annotations matching the resolver for `webDirectory`, `language`, `maxAgeDays`, `env` where craft-preview defines them; `preview.phpVersion` described as derived from composer.json when absent; remove the template-string `default` from `snapshot.key` (describe it instead).

- [ ] **Step 4: Run every test**

Run: `for t in tests/*.test.sh; do bash "$t" || exit 1; done`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add README.md fleet.schema.json tests/
git commit -m "Docs and schema for onboarding; phase 1 doc follow-ups"
```

- [ ] **Step 6 (controlling session, Svale's go-ahead): push main and move `v1`**

```bash
git push origin main
git tag -f v1 && git push -f origin v1
```
Expected: `gh api repos/netliferesearch/craft-ci/git/ref/tags/v1 --jq .object.sha` equals `git rev-parse HEAD`. (Repo admins bypass the tag ruleset.)

---

### Task 5: nfi repo changes: MySQL 8.0 in DDEV and the scrub file

**Files (in `~/code/nfi`, on branch `netlife/fleet-onboarding` from `main`):**
- Modify: `.ddev/config.yaml` (`database: type: mysql`, `version: "8.0"`)
- Create: `.netlife/scrub.sql`

**Interfaces:**
- Produces: the two files Task 6's PR must contain beside the script's output.

- [ ] **Step 1: List tables holding personal data.** From nfi's code only (`modules/`, `migrations/`, `config/project/`, plugin names in `composer.json`), never production. At least: Formie submissions and their related tables, Social Login's linked accounts, every table created by the custom auth and gamekey modules, and any plugin table storing emails, names, IPs or tokens. Write the list with one line of reasoning per table as the header comment of `scrub.sql`.

- [ ] **Step 2: Write `.netlife/scrub.sql`.** `DELETE FROM` for tables whose rows are personal data, `UPDATE … SET` anonymised values where rows must survive for the site to render (follow `scripts/scrub.sql`'s style). Only statements that are valid on MySQL 8.0 and tolerate an empty table.

- [ ] **Step 3: Test the scrub against a local copy**

```bash
cd ~/code/nfi && ddev export-db --file=/tmp/nfi-local.sql.gz   # local dev data, never production
docker run -d --rm --name nfi-scrub -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -p 3310:3306 mysql:8.0
# wait for mysqladmin ping, then:
mysql -h127.0.0.1 -P3310 -uroot -e 'CREATE DATABASE s'
gunzip -c /tmp/nfi-local.sql.gz | mysql -h127.0.0.1 -P3310 -uroot s
mysql -h127.0.0.1 -P3310 -uroot s < ~/code/craft-ci/scripts/scrub.sql
mysql -h127.0.0.1 -P3310 -uroot s < .netlife/scrub.sql
docker stop nfi-scrub
```
Expected: both scrubs exit 0; spot checks show no real email addresses left in the listed tables. The local dump comes from MariaDB; if it does not load into MySQL 8.0, report that to Svale (the team's local data then needs a fresh import from a snapshot after the switch) and test the scrub against a database built from `ddev craft install` plus the plugin tables instead.

- [ ] **Step 4: Commit on the branch (no push)**

```bash
git add .ddev/config.yaml .netlife/scrub.sql
git commit -m "DDEV on MySQL 8.0 like Craft Cloud; scrub rules for the fleet snapshot"
```

---

### Task 6: Onboard nfi live (controlling session, Svale at each gate)

No new code. Each step is a command and its expected result; stop and report when a result differs.

- [ ] **Step 1: Dry run**

Run: `bash scripts/onboard.sh Feedsystem/nfi`
Expected: exit 1; `diff` for topic, protection, auto-merge, dependabot alerts, actions create PRs, manifest and the three callers; `todo` for renovate, ddev database, scrub, and secrets `CRAFT_CLOUD_*`, `SNAPSHOT_*`, `RENOVATE_PUSH_TOKEN`; no `todo` for `DB_*` (they exist); `host=cloud backup=yes`.

- [ ] **Step 2 (Svale): add the secrets** listed as `todo` to Feedsystem/nfi (values from Craft Cloud and 1Password).

- [ ] **Step 3: Apply** with `ONBOARD_CHECKOUT` pointing at `~/code/nfi-fleet-onboarding` (a worktree of `~/code/nfi` on branch `netlife/fleet-onboarding`, Task 5's commit), so the PR carries the DDEV and scrub changes too:

Run: `ONBOARD_CHECKOUT=~/code/nfi-fleet-onboarding bash scripts/onboard.sh Feedsystem/nfi --apply`
Expected: one PR "Adopt craft-ci fleet configuration" on nfi with manifest, three callers, `.ddev/config.yaml`, `.netlife/scrub.sql`; settings applied. PR description says the team needs a fresh local DB import after MySQL 8.0 lands.

- [ ] **Step 4: Renovate.** PR on netliferesearch/renovate adding `'Feedsystem/nfi'` to `repositories` in `config.js`; Svale merges.

- [ ] **Step 5: Verify on the PR.** Expected: `verify / verify` green, crawl without `ImageTransformException`. If it times out, raise `timeout-minutes` (spec: builder's call) and re-release `v1`.

- [ ] **Step 6 (Svale): review `scrub.sql` in the PR, then merge.** Expected: back-merge to `develop` green; Craft Cloud deploy healthy.

- [ ] **Step 7: Snapshot.** `gh workflow run snapshot.yml --repo Feedsystem/nfi && gh run watch`. Expected: green, `snapshots/nfi/latest.sql.gz` uploaded.

- [ ] **Step 8: Drift checks.** `bash scripts/onboard.sh Feedsystem/nfi` and `bash scripts/onboard.sh Feedsystem/nch --host forge`. Expected: both exit 0 (only `ok` and `note` lines). nch has no `.netlife/scrub.sql` today, so it reports `todo scrub` until Svale reviews nch's tables and a scrub file (comment-only if the shared scrub suffices) is merged on nch; any `todo secret` on nch is reported, not papered over.

- [ ] **Step 9: Record.** Pilot log row and TODO updates in the Obsidian note; first Renovate run on nfi checked the next morning (Dependency Dashboard issue created).
