# Fleet Config Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A site is configured by one `.netlife/fleet.json` with defaults and four thin workflow callers, and nch runs verify, snapshot, back-merge and preview from it with no per-site values in its workflow files.

**Architecture:** craft-ci gains `fleet.schema.json`, a bash resolver `scripts/manifest.sh` that prints resolved `KEY=VALUE` lines, and two new reusable workflows (verify, snapshot); the existing back-merge workflow reads the manifest for its target branch. craft-preview reads the same file through its zod schema, with `.craft-preview.json` accepted for one release. The composite actions keep their inputs; the reusable workflows are the only new layer.

**Tech Stack:** GitHub Actions (`workflow_call`, `secrets: inherit`), bash + jq, `actionlint`, the existing `tests/lib.sh` harness; TypeScript + zod + `node:test` in craft-preview.

**Spec:** `docs/superpowers/specs/2026-10-20-fleet-config-simplification-design.md`

## Global Constraints

- Manifest file `.netlife/fleet.json` (directory `.netlife/` at the repo root; it may also hold `.netlife/scrub.sql`). Schema file `fleet.schema.json` at craft-ci's root, `$id` `https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json`.
- Slug default: `GITHUB_REPOSITORY` after the slash, lowercased, characters outside `[a-z0-9]` removed, first 12 characters; must match `^[a-z][a-z0-9]{1,11}$`.
- `snapshot.source` enum: `production` (default), `staging`, `none`, `forge-backup` (accepted, not implemented: the snapshot workflow fails with "forge-backup source not implemented").
- `snapshot.key` default `snapshots/<slug>/latest.sql.gz`. `verify.crawlLimit` default `40`, `verify.ignoreLogPattern` default `""`, `verify.environment` default `staging`. `branches.main` default `main`; `branches.develop` default `develop` when that branch exists on origin, otherwise empty; explicit `null` means no back-merge.
- Unknown top-level keys, a bad slug, or a bad source exit `2` with the reason on stderr. A missing file equals `{}`.
- Reusable workflows live in `.github/workflows/verify.yml` and `.github/workflows/snapshot.yml` in craft-ci; both have a single job whose id is `verify` and `snapshot` respectively. The check a caller produces is named `<caller job id> / verify`; callers use job id `verify` so the required status check is `verify / verify`.
- All shell: `set -euo pipefail`, no prompts, every failure path prints why and exits non-zero.
- Commit only with the user's go-ahead per task; move the `v1` tag only in Task 5.

## Review Focus

1. **A site with no `.netlife/fleet.json`** must get the full default set, including slug from the repo name, so a repo can adopt the callers before anyone writes a manifest. Test in Task 1 (`test_no_file`).
2. **`branches.develop: null`** must disable the back-merge without error, and a missing `develop` branch must do the same, while a `develop` that exists is picked up. Tests in Task 1 (`test_develop_null`, `test_develop_absent`, `test_develop_detected`) and Task 4.
3. **A manifest with a typo** (`"snapshotKey"` at the top level, left over from `.craft-preview.json`) must fail validation, not silently fall back to the default key and verify against the wrong snapshot. Test in Task 1 (`test_unknown_key`).
4. **A repo name that yields an invalid slug** (starts with a digit, or shorter than two characters after cleaning) must fail with a message telling the user to set `slug`, not produce a bucket key with an empty segment. Test in Task 1 (`test_slug_from_bad_repo_name`).
5. **The old `.craft-preview.json` beside a new `.netlife/fleet.json`** in craft-preview must prefer `.netlife/fleet.json` and warn, so a half-migrated site does not run two configurations. Test in Task 6 (`prefers .netlife/fleet.json when both exist`).
6. **A `composer.json` with only `require.php: "^8.2"`** must resolve to `php82`, and one with nothing resolvable must fail with "set preview.phpVersion" rather than pick a version the preview server may not have. Tests in Task 6 (`phpVersion from require`, `phpVersion unresolvable fails`).

---

### Task 1: Manifest schema and resolver

**Files:**
- Create: `fleet.schema.json`
- Create: `scripts/manifest.sh`
- Create: `tests/manifest.test.sh`
- Create: `tests/fixtures/manifest-cases.json`
- Modify: `tests/lib.sh` (add `make_remote_with_branches <dir> <branch>...` if not already covered by `make_repo`)

**Interfaces:**
- Produces: `scripts/manifest.sh [path]` (default `.netlife/fleet.json`), run inside the site checkout with `origin` set and `GITHUB_REPOSITORY` in the env. Prints, one per line, `SLUG=`, `SNAPSHOT_SOURCE=`, `SNAPSHOT_KEY=`, `VERIFY_CRAWL_LIMIT=`, `VERIFY_IGNORE_LOG_PATTERN=`, `VERIFY_ENVIRONMENT=`, `BRANCH_MAIN=`, `BRANCH_DEVELOP=`. Exit `0` on success, `2` on validation failure, `3` when `jq` is missing. Env `MANIFEST_NO_REMOTE=1` skips the `git ls-remote` develop probe (then `BRANCH_DEVELOP` is `develop` only when set explicitly).
- Produces: `fleet.schema.json`, JSON Schema draft 2020-12, `additionalProperties: false` at the top level and inside `snapshot`, `verify`, `branches`, `preview`; `preview` holds `phpVersion` (enum `php82`..`php85`, no default), `webDirectory`, `buildCommand`, `siteUrls`, `env`, `domain` (enum `on-forge`, `custom`, default `on-forge`), `language`, `maxAgeDays`.
- Produces: `tests/fixtures/manifest-cases.json`, an array of `{ "name", "repository", "manifest", "expect": { "slug", "snapshotKey" } | "error" }` covering the slug and key cases below. craft-preview copies this file into its tests (Task 6).

- [ ] **Step 1: Write the failing tests**

`tests/manifest.test.sh`, using `tests/lib.sh`. Each test runs in a fresh temp clone with a bare origin.

```bash
test_no_file                # no .netlife/fleet.json, GITHUB_REPOSITORY=Feedsystem/NCH → SLUG=nch, SNAPSHOT_SOURCE=production, SNAPSHOT_KEY=snapshots/nch/latest.sql.gz, VERIFY_CRAWL_LIMIT=40, VERIFY_ENVIRONMENT=staging, BRANCH_MAIN=main
test_defaults_empty_object  # {} → same as test_no_file
test_explicit_values        # slug=acme, snapshot.key=custom/key.sql.gz, verify.crawlLimit=10, verify.ignoreLogPattern=ImageTransformException → each echoed back
test_slug_cleaning          # GITHUB_REPOSITORY=netliferesearch/My-Long_Site-Name-2026 → SLUG=mylongsitena (12 chars)
test_slug_from_bad_repo_name # GITHUB_REPOSITORY=org/2026 → exit 2, stderr contains "set slug"
test_bad_slug               # slug=Ab → exit 2
test_bad_source             # snapshot.source=prod → exit 2, stderr lists the four allowed values
test_unknown_key            # {"snapshotKey":"x"} → exit 2, stderr names "snapshotKey"
test_develop_detected       # origin has develop → BRANCH_DEVELOP=develop
test_develop_absent         # origin has only main → BRANCH_DEVELOP= (empty)
test_develop_null           # branches.develop=null, origin has develop → BRANCH_DEVELOP= (empty)
test_develop_named          # branches.develop=staging → BRANCH_DEVELOP=staging (no probe)
test_fixture_cases          # every entry in tests/fixtures/manifest-cases.json: SLUG and SNAPSHOT_KEY match expect, or exit 2 when expect is "error"
```

Fixture entries: `Feedsystem/NCH` + `{}` → `nch`, `snapshots/nch/latest.sql.gz`; `netliferesearch/My-Long_Site-Name-2026` + `{}` → `mylongsitena`; `org/2026` + `{}` → error; `org/x` + `{}` → error; `org/anything` + `{"slug":"acme"}` → `acme`, `snapshots/acme/latest.sql.gz`; `org/anything` + `{"slug":"acme","snapshot":{"key":"custom/key.sql.gz"}}` → `acme`, `custom/key.sql.gz`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/manifest.test.sh`
Expected: FAIL, `scripts/manifest.sh: No such file`

- [ ] **Step 3: Implement `scripts/manifest.sh`**

Read the file (or `{}`), validate with `jq` (top-level keys subset of `slug snapshot verify branches preview $schema`; nested key sets likewise; slug regex; source enum), resolve defaults in the order slug → snapshot key → branches, probe `origin` with `git ls-remote --exit-code --heads origin develop` unless `MANIFEST_NO_REMOTE=1` or `branches.develop` is set or `null`. Print the eight lines. Write `fleet.schema.json` in the same step with the defaults in `default` fields and descriptions copied from the spec's table.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/manifest.test.sh`
Expected: `13 passed`

- [ ] **Step 5: Schema smoke**

Run: `jq -e '.properties.snapshot.properties.source.enum == ["production","staging","none","forge-backup"]' fleet.schema.json`
Expected: `true`

- [ ] **Step 6: Commit**

```bash
git add fleet.schema.json scripts/manifest.sh tests/manifest.test.sh tests/fixtures/manifest-cases.json tests/lib.sh
git commit -m "Add .netlife/fleet.json schema and manifest resolver"
```

### Task 2: Reusable verify workflow

**Files:**
- Create: `.github/workflows/verify.yml`
- Create: `tests/workflows.test.sh` (actionlint over every workflow plus the assertions below)

**Interfaces:**
- Consumes: `scripts/manifest.sh` output from Task 1.
- Produces: reusable workflow `netliferesearch/craft-ci/.github/workflows/verify.yml@v1`, `on: workflow_call` with no required inputs and no declared secrets (callers pass `secrets: inherit`). Optional inputs: `extra-env` (string, default `""`) and `project-config-commit` (boolean, default `true`). Job id `verify`, `runs-on: ubuntu-latest`, `timeout-minutes: 25`, `permissions: contents: read`.

- [ ] **Step 1: Write the failing test**

`tests/workflows.test.sh`:

```bash
test_actionlint          # actionlint .github/workflows/*.yml → exit 0
test_verify_job_id       # yq '.jobs | keys | .[0]' .github/workflows/verify.yml == "verify"
test_verify_is_callable  # yq '.on | has("workflow_call")' == true
test_verify_no_secret_decl # yq '.on.workflow_call | has("secrets")' == false (inherit only)
```

Install `yq` with `brew install yq` if missing (document in the test header).

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/workflows.test.sh`
Expected: FAIL, verify.yml missing

- [ ] **Step 3: Write `.github/workflows/verify.yml`**

Steps: `actions/checkout@v4` (the caller's repo); `actions/checkout@v4` of `netliferesearch/craft-ci` at `v1` into `.craft-ci`; "Resolve manifest" runs `bash .craft-ci/scripts/manifest.sh >> "$GITHUB_OUTPUT"` with `id: manifest` and `GITHUB_REPOSITORY` from the default env; "App token" uses `actions/create-github-app-token` (pin latest v2 release) with `client-id: ${{ vars.RENOVATE_APP_CLIENT_ID }}`, `private-key: ${{ secrets.RENOVATE_APP_PRIVATE_KEY }}`, `owner: ${{ github.repository_owner }}`, `repositories: ${{ github.event.repository.name }}`, `permission-contents: write`, `id: app-token`, `if: vars.RENOVATE_APP_CLIENT_ID != ''`; then `uses: netliferesearch/craft-ci@v1` with `snapshot-key: ${{ steps.manifest.outputs.SNAPSHOT_SOURCE != 'none' && steps.manifest.outputs.SNAPSHOT_KEY || '' }}`, `spaces-key`/`spaces-secret` from `SNAPSHOT_READ_KEY`/`SNAPSHOT_READ_SECRET`, `crawl-limit`, `ignore-log-pattern`, `environment` from the manifest outputs, `extra-env` from the input, `commit-project-config: ${{ inputs.project-config-commit }}`, `push-token: ${{ steps.app-token.outputs.token || secrets.RENOVATE_PUSH_TOKEN }}`. Remove `.craft-ci` before the action runs so it does not end up in the site's build.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/workflows.test.sh`
Expected: `4 passed`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/verify.yml tests/workflows.test.sh
git commit -m "Add reusable verify workflow driven by .netlife/fleet.json"
```

### Task 3: Reusable snapshot workflow

**Files:**
- Create: `.github/workflows/snapshot.yml`
- Modify: `scripts/snapshot.sh` (apply `EXTRA_SCRUB_SQL`), `tests/workflows.test.sh` (two assertions), `tests/snapshot-scrub.test.sh` (new, one assertion: with a scratch MySQL on 3307 absent the script fails before dumping, with `EXTRA_SCRUB_SQL` pointing at a file containing `DELETE FROM x;` the generated command list includes it after scrub.sql; use a shim `mysql` on PATH that records its stdin, as the project-config test shims git)

**Interfaces:**
- Consumes: `scripts/manifest.sh`, `scripts/snapshot.sh` (contract: `SLUG`, `DB_*`, `SSH_*`, `DO_SPACES_*`, `AWS_*`, `SCRUB_TRUNCATE`, plus new optional `EXTRA_SCRUB_SQL`, a path applied to the scratch database after `scrub.sql` when set and the file exists).
- Produces: reusable workflow `netliferesearch/craft-ci/.github/workflows/snapshot.yml@v1`, `on: workflow_call` with optional input `scrub-truncate` (string, default `""`). Job id `snapshot`, `timeout-minutes: 30`, the MySQL 8.0 service container on `3307:3306` as in `examples/snapshot.yml` today.

- [ ] **Step 1: Add the failing assertions**

```bash
test_snapshot_job_id      # yq '.jobs | keys | .[0]' .github/workflows/snapshot.yml == "snapshot"
test_snapshot_has_service # yq '.jobs.snapshot.services.mysql.image' == "mysql:8.0"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/workflows.test.sh`
Expected: FAIL on the two new tests

- [ ] **Step 3: Write `.github/workflows/snapshot.yml`**

Steps: checkout the caller repo (manifest only is enough, but a full checkout is simpler); checkout craft-ci at `v1` into `.craft-ci`; resolve the manifest; "Skip" step that exits 0 with a notice when `SNAPSHOT_SOURCE` is `none`, and fails with "forge-backup source not implemented" when it is `forge-backup`; "Snapshot" runs `bash .craft-ci/scripts/snapshot.sh` with `SLUG` from the manifest, `DB_*` and `SSH_*` from `secrets.SOURCE_*`, `SCRUB_TRUNCATE` from the input, `EXTRA_SCRUB_SQL: .netlife/scrub.sql` (the script ignores a missing file), `DO_SPACES_BUCKET: netlife-craft-snapshots`, `DO_SPACES_REGION: fra1`, `AWS_*` from `SNAPSHOT_WRITE_*`.

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/workflows.test.sh`
Expected: `6 passed`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/snapshot.yml scripts/snapshot.sh tests/workflows.test.sh tests/snapshot-scrub.test.sh
git commit -m "Add reusable snapshot workflow driven by .netlife/fleet.json; per-site scrub.sql"
```

### Task 4: Back-merge reads the manifest

**Files:**
- Modify: `.github/workflows/backmerge.yml`
- Modify: `tests/workflows.test.sh` (one assertion)

**Interfaces:**
- Consumes: `scripts/manifest.sh` `BRANCH_MAIN`, `BRANCH_DEVELOP`.
- Produces: input `target-branch` default changes from `develop` to `""`; empty means "from the manifest". When the resolved target is empty the job prints `::notice::no develop branch configured, nothing to back-merge` and exits 0. `source-branch` default likewise becomes `""` meaning `BRANCH_MAIN`.

- [ ] **Step 1: Add the failing assertion**

```bash
test_backmerge_defaults_empty # yq '.on.workflow_call.inputs.target-branch.default' .github/workflows/backmerge.yml == ""
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/workflows.test.sh`
Expected: FAIL, default is `develop`

- [ ] **Step 3: Modify `.github/workflows/backmerge.yml`**

After the craft-ci checkout, add the "Resolve manifest" step. In "Merge and push", set `SOURCE="${{ inputs.source-branch || steps.manifest.outputs.BRANCH_MAIN }}"` and `TARGET="${{ inputs.target-branch || steps.manifest.outputs.BRANCH_DEVELOP }}"`; if `TARGET` is empty, print the notice and `exit 0` before calling the script. `MANIFEST_NO_REMOTE` stays unset so the probe runs.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/workflows.test.sh && bash tests/backmerge.test.sh`
Expected: all pass (the script tests are unchanged)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/backmerge.yml tests/workflows.test.sh
git commit -m "Back-merge reads its branches from .netlife/fleet.json"
```

### Task 5: Thin callers, README, release

**Files:**
- Replace: `examples/verify.yml`, `examples/snapshot.yml`
- Create: `examples/backmerge.yml`, `examples/fleet.json`
- Modify: `README.md` (new section "Site files" replacing "Use from a site repo"; the Snapshot job and Back-merge sections point at the callers; "Layout" lists the new files)
- Modify: `tests/action-yml.test.sh` or `tests/workflows.test.sh` (actionlint over `examples/*.yml`)

**Interfaces:**
- Produces: the three callers a site copies verbatim. `examples/verify.yml`: `on: [pull_request]`, job `verify:` with `uses: netliferesearch/craft-ci/.github/workflows/verify.yml@v1` and `secrets: inherit`. `examples/snapshot.yml`: `on: schedule: cron "0 1 * * *"` and `workflow_dispatch`, job `snapshot:` calling the snapshot workflow with `secrets: inherit`. `examples/backmerge.yml`: `on: push: branches: [main]`, job `backmerge:` calling the back-merge workflow with `permissions: contents: write, pull-requests: write`. `examples/fleet.json`: the nch manifest from the spec, with the `$schema` line.

- [ ] **Step 1: Add the failing assertion**

```bash
test_examples_lint  # actionlint examples/*.yml → exit 0; and `jq -e '.slug' examples/fleet.json` → "nch"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/workflows.test.sh`
Expected: FAIL, `examples/fleet.json` missing

- [ ] **Step 3: Write the callers, the example manifest and the README section**

README "Site files": the four callers (preview's from craft-preview), the manifest with its defaults table copied from the spec, the required status check name `verify / verify`, and the line that a site with defaults commits `{}`. Keep the composite action documentation as the "direct use" alternative.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/workflows.test.sh && bash tests/manifest.test.sh && bash tests/backmerge.test.sh && bash tests/commit-project-config.test.sh`
Expected: all pass

- [ ] **Step 5: Commit, push, move the tag**

```bash
git add examples README.md tests
git commit -m "Thin callers and .netlife/fleet.json example; document site files"
git push origin main
git tag -f v1 && git push origin -f v1
```

Expected: `git ls-remote --tags origin v1` shows the new commit.

### Task 6: craft-preview reads `.netlife/fleet.json`

**Files (in `~/code/craft-preview`):**
- Modify: `src/config.ts`, `src/cli.ts` (new `config` command), `src/forge.ts` or wherever the domain mode is consumed (base domain and certificate id now come from inputs)
- Modify: `action.yml` (`config-path` default `.netlife/fleet.json`; new inputs `preview-base-domain` and `preview-certificate-id`, default `""`; a first step runs `node src/cli.ts config` and writes the JSON to `$RUNNER_TEMP/craft.json`; the presign step reads `.snapshot.key` from that file instead of `jq` on the raw manifest)
- Modify: `examples/client-repo/.github/workflows/preview.yml` (sparse checkout lists `.netlife/fleet.json`, `.craft-preview.json`, `composer.json`, `package.json`, `config/project/sites`; the two new inputs fed from `vars.PREVIEW_BASE_DOMAIN` and `vars.PREVIEW_CERTIFICATE_ID`)
- Rename: `examples/client-repo/.craft-preview.json` → `examples/client-repo/.netlife/fleet.json` (new shape)
- Copy: craft-ci `tests/fixtures/manifest-cases.json` → `tests/fixtures/manifest-cases.json`
- Test: `tests/config.test.ts`

**Interfaces:**
- Consumes: the `.netlife/fleet.json` shape from the spec: top-level `slug`, `snapshot.key`, `preview.*`.
- Produces: `loadConfig(dir: string, env: NodeJS.ProcessEnv): ResolvedManifest` (signature changes from a file path to a directory). Reads `<dir>/.netlife/fleet.json` when present, else `<dir>/.craft-preview.json` with `console.warn(".craft-preview.json is deprecated, rename to .netlife/fleet.json")`, else treats the manifest as `{}`. `ResolvedManifest` is the full manifest with every default applied: `slug` (from `GITHUB_REPOSITORY` with the spec's cleaning rule, validated against `^[a-z][a-z0-9]{1,11}$`, error "set slug" otherwise), `snapshot.key`, `preview.phpVersion` (from `<dir>/composer.json`: `config.platform.php`, else the lower bound of `require.php`; mapped to `php<major><minor>`; error "set preview.phpVersion" when nothing resolves or the result is outside `php82`..`php85`), `preview.buildCommand` (from `<dir>/package.json`), `preview.siteUrls` (env var names from `<dir>/config/project/sites/*.yaml` `baseUrl: $VAR` references, each `/`, merged under the manifest's own entries), `preview.domain` (`on-forge` default).
- Produces: CLI command `config` that prints `JSON.stringify(loadConfig(cwd, process.env))` and exits `1` with the error on stderr when resolution fails. The action runs it first; the presign step and the Node commands read its output.
- Produces: `CraftManifest` zod schema exported, `strictObject` at every level; `domain` is `z.enum(["on-forge","custom"])`. The action inputs `preview-base-domain` and `preview-certificate-id` replace the old `domain.baseDomain` and `domain.certificateId`, required by `up` only when `domain` is `custom`.

- [ ] **Step 1: Write the failing tests**

```ts
test("reads .netlife/fleet.json", ...)             // slug nch, snapshot.key snapshots/nch/latest.sql.gz, phpVersion php82
test("fixture cases agree with craft-ci", ...) // every entry in tests/fixtures/manifest-cases.json resolves to expect.slug and expect.snapshotKey, or throws when expect is "error"
test("falls back to .craft-preview.json with a warning", ...)
test("prefers .netlife/fleet.json when both exist", ...)
test("rejects top-level snapshotKey", ...) // old field at the new place → error names "snapshotKey"
test("rejects unknown preview key", ...)
test("rejects domain object", ...)         // {"preview":{"domain":{"mode":"custom"}}} → error; string "custom" accepted
test("phpVersion from platform", ...)      // config.platform.php "8.2.27" → php82
test("phpVersion from require", ...)       // require.php "^8.3" → php83; "~8.2.0" → php82; ">=8.4" → php84
test("phpVersion unresolvable fails", ...) // no composer.json php keys → error "set preview.phpVersion"; "^7.4" → same error
test("buildCommand from package.json", ...) // build script present → "npm ci && npm run build"; absent → undefined
test("siteUrls from project config", ...)  // sites/default.yaml baseUrl "$PRIMARY_SITE_URL", sites/en.yaml baseUrl "$EN_URL" → {PRIMARY_SITE_URL:"/", EN_URL:"/"}; manifest {EN_URL:"/en"} → EN_URL "/en"; literal baseUrl ignored
test("config command prints resolved JSON", ...) // spawn the CLI in a fixture dir, parse stdout, slug present
```

- [ ] **Step 2: Run to verify they fail**

Run: `npm test -- tests/config.test.ts`
Expected: FAIL, `loadConfig` takes a path and ignores `.netlife/fleet.json`

- [ ] **Step 3: Implement**

`CraftManifest = z.strictObject({ $schema: z.string().optional(), slug: ..., snapshot: z.strictObject({ source: z.enum([...]).default("production"), key: z.string().optional() }).default({}), verify: z.strictObject({...}).default({}), branches: z.strictObject({...}).default({}), preview: PreviewSection.default({}) })` where `PreviewSection` is today's `PreviewConfig` minus `slug` and `snapshotKey`, with `domain` as the string enum and `phpVersion` optional. Resolution (slug, key, phpVersion, buildCommand, siteUrls) lives in `src/config.ts` as `resolve(manifest, dir, env)`; `loadConfig` reads, parses and resolves. The `require.php` lower bound: strip `^`, `~`, `>=`, `*` and take the first two numeric components. Update `cli.ts` call sites for the directory argument and add the `config` command.

- [ ] **Step 4: Run to verify they pass**

Run: `npm test && npm run typecheck`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add src/config.ts src/cli.ts src/forge.ts action.yml examples tests/config.test.ts tests/fixtures/manifest-cases.json
git commit -m "Read the fleet manifest .netlife/fleet.json; keep .craft-preview.json as a deprecated fallback"
```

### Task 7: Switch nch over

**Files (in `~/code/nch`):**
- Create: `.netlife/fleet.json` (`{"$schema": "...", "slug": "nch", "verify": {"ignoreLogPattern": "ImageTransformException"}}`)
- Replace: `.github/workflows/verify.yml`, `.github/workflows/snapshot.yml`, `.github/workflows/backmerge.yml` with the callers from Task 5

**Interfaces:**
- Consumes: craft-ci `v1` from Task 5.

- [ ] **Step 1: Branch and PR**

```bash
git checkout -b ci/fleet-manifest
# write the four files
actionlint .github/workflows/*.yml
git add .netlife/fleet.json .github/workflows && git commit -m "Configure CI from .netlife/fleet.json with thin callers"
git push -u origin HEAD && gh pr create --fill
```

Expected: a check named `verify / verify` runs and is green; the project config step prints `changed=false`.

- [ ] **Step 2: Update the required status check**

```bash
gh api -X PATCH repos/Feedsystem/nch/branches/main/protection/required_status_checks \
  -f strict=true -f 'contexts[]=verify / verify'
```

Expected: `gh api repos/Feedsystem/nch/branches/main/protection --jq '.required_status_checks.contexts'` shows `["verify / verify"]`.

- [ ] **Step 3: Merge and watch**

```bash
gh pr merge --squash --auto
gh run list --repo Feedsystem/nch --workflow Back-merge -L1
gh workflow run snapshot.yml --repo Feedsystem/nch && gh run watch
```

Expected: back-merge green, snapshot green and `latest.sql.gz` rewritten (check the object's date in the bucket). Record the switch in the fleet design's Pilot log.
