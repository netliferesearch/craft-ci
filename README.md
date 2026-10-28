# craft-ci

Shared verification for Netlife's Craft CMS sites. A composite GitHub Action that boots the
site in DDEV on the runner, seeds it with a scrubbed production snapshot, runs migrations and
project config, and crawls the sitemap. Used on every Renovate PR and on any feature PR.

Hosting-neutral: the same action verifies sites on Forge, Servebolt and Craft Cloud, because it
never touches the host. Only the snapshot job and the deploy step differ per host.

Sites do not copy the action's steps. They commit short callers that use the reusable workflows in
this repo (`verify.yml`, `snapshot.yml`, `backmerge.yml`) at `@v1`, plus a manifest in
`.netlife/fleet.json`; see "Site files" and "Onboarding a site" below.

## What the action does (v0, deliberately small)

1. `ddev start` from the repo's committed `.ddev/config.yaml`
2. `.env` from `.env.example.dev` or `.env.example`, plus DDEV's database variables. devMode is off and `CRAFT_ENVIRONMENT` is `staging` (input `environment`), so Twig and site configs behave as on the live site and nothing tries a Vite dev server; errors are read from `storage/logs`. Admin changes are allowed, because Craft and plugin update migrations write to project config and fail in read-only mode; the resulting YAML is what step 6 commits
3. `composer install`, and `npm ci && npm run build` when `package.json` has a `build` script
4. Snapshot import from the bucket when `snapshot-key` is set, otherwise a fresh install from project config. Through the reusable workflow, a manifest with `snapshot.source` set to `none` gives no key, so verify does a fresh install
5. `craft migrate/all`, `craft project-config/apply`, `craft clear-caches/all`
6. If `commit-project-config` is on and the migrations changed `config/project`, commit that change back to the PR branch with `push-token`, so a dependency update PR carries the project config it produced. Verify runs again on that commit
7. Crawl: every URL in `sitemap.xml` (capped by `crawl-limit`), fail on any non-2xx/3xx, then fail on new `[error]` lines in Craft's log

Inputs worth knowing: `environment` (default `staging`), `extra-env` (site secrets appended to `.env`,
e.g. read-only S3 credentials so image transforms work), `ignore-log-pattern` (regex for error lines
that are environmental in CI, such as `ImageTransformException` when no asset credentials are given),
`commit-project-config` (default `false`) with `push-token`. The push token must be one that triggers
workflows, a personal token or a GitHub App token, because a commit pushed with `GITHUB_TOKEN` gets no
check and branch protection would then block the merge. Without a token, a project config change prints
the diff and fails the check, so it is never merged silently. PRs from forks are never pushed to. The
commit is authored by `Craft CI <craft-ci@netlife.no>`; Renovate's preset lists that address in
`gitIgnoredAuthors` so the commit does not count as a human edit. Changes that only touch `dateModified`
lines are ignored, and if the branch already ends in such a commit and config changes again, the step
fails instead of pushing, so a site where Craft rewrites project config on every run cannot loop. The
step applies to every PR that runs verify, including human ones such as a `develop` to `main` release.

Not yet: screenshots, link check, control panel smoke test, the Claude Code fix job. They come
after the first pilot runs green.

## Site files

A site repo holds a `.netlife/` directory and a few small workflow files. Everything else lives here.

### The `.netlife/` directory

| File | Holds |
| --- | --- |
| `.netlife/fleet.json` | the manifest, described below |
| `.netlife/scrub.sql` | optional. Site-specific anonymisation, applied by the snapshot workflow after the shared `scrub.sql` |
| `.netlife/haven.json` | Haven's repo manifest. It lives here too but belongs to the Haven project, and nothing in craft-ci reads or writes it |

### The manifest

`.netlife/fleet.json` is validated against `fleet.schema.json` (add the `$schema` line from
`examples/fleet.json` for editor support). Every key has a default, resolved by `scripts/manifest.sh`,
so a site that matches the defaults commits `{}`. `examples/fleet.json` is the full manifest for nch.
The keys the workflows here use:

| Key | Default | Derived from |
| --- | --- | --- |
| `slug` | repository name, lowercased, characters outside `[a-z0-9]` removed, first 12; must then match `^[a-z][a-z0-9]{1,11}$` or resolution fails with "set slug" (it names a MySQL schema and a hostname label) | `GITHUB_REPOSITORY` |
| `snapshot.source` | `production` | `staging` only for a site with no production; `none` for a fresh install from project config; `forge-backup` reserved, the snapshot workflow fails on it for now |
| `snapshot.key` | `snapshots/<slug>/latest.sql.gz` | slug |
| `verify.crawlLimit` | `40` | |
| `verify.ignoreLogPattern` | `""` | |
| `verify.environment` | `staging` | passed to the action as `CRAFT_ENVIRONMENT` |
| `branches.main` | `main` | |
| `branches.develop` | `develop` if that branch exists on origin, else `null` (no back-merge) | `git ls-remote` |

The `preview.*` keys are read by craft-preview, not by the workflows here, and have their own
defaults there.

### The callers

Three callers are copied verbatim from `examples/`; each is a few lines that call a reusable workflow
in this repo at `@v1`. The fourth, preview, comes from craft-preview. Craft Cloud sites use
`examples/verify-cloud.yml` and `examples/snapshot-cloud-backup.yml` in place of `verify.yml` and
`snapshot.yml` (see the hosting table under "Snapshot job").

| Site file | Example | Calls |
| --- | --- | --- |
| `.github/workflows/verify.yml` | `examples/verify.yml` | `verify.yml`, on every pull request |
| `.github/workflows/snapshot.yml` | `examples/snapshot.yml` | `snapshot.yml`, nightly at 01:00 UTC and on demand. The schedule sits in the caller |
| `.github/workflows/backmerge.yml` | `examples/backmerge.yml` | `backmerge.yml`, on every push to `main`. Only for sites with a `develop` branch. The example triggers on `main`; if the site's `branches.main` is another name, edit the `branches:` line in the caller to match |
| `.github/workflows/preview.yml` | | comes from `netliferesearch/craft-preview`; see its README |

The required status check for branch protection is `verify / verify`: the caller's job id `verify`
plus the called workflow's job `verify`.

### Secrets

The callers pass secrets by name, because GitHub honours `secrets: inherit` only when caller and called
workflow are in the same organization, and the fleet spans netliferesearch and Feedsystem. Set the shared
ones as organization secrets scoped to the right repos.

| Workflow | Reads |
| --- | --- |
| verify | `SNAPSHOT_READ_KEY`, `SNAPSHOT_READ_SECRET`. Craft Cloud sites also `CRAFT_CLOUD_PROJECT_ID`, `CRAFT_CLOUD_ENVIRONMENT_ID`, `CRAFT_CLOUD_USE_ASSET_CDN`, `CRAFT_CLOUD_SIGNING_KEY`. To push project config changes: `RENOVATE_APP_PRIVATE_KEY` with the `app-client-id` input, filled from the variable `RENOVATE_APP_CLIENT_ID` (an app token is minted when it is set), otherwise `RENOVATE_PUSH_TOKEN` |
| snapshot | `SNAPSHOT_WRITE_KEY`, `SNAPSHOT_WRITE_SECRET`, `SOURCE_DB_HOST`, `SOURCE_DB_NAME`, `SOURCE_DB_USER`, `SOURCE_DB_PASSWORD`, and for Forge and Servebolt `SOURCE_SSH_HOST`, `SOURCE_SSH_USER`, `SOURCE_SSH_KEY` |
| back-merge | none, it uses the workflow's own `GITHUB_TOKEN` |

The reusable verify workflow has three inputs a caller can set with `with:`: `extra-env` (lines appended
to `.env`, for site secrets such as read-only S3 credentials), `project-config-commit` (default
`true`) and `app-client-id` (pass the variable `RENOVATE_APP_CLIENT_ID`; empty means `RENOVATE_PUSH_TOKEN` is used). The snapshot workflow has `scrub-truncate`, a space-separated list of tables to empty after the
scrub. Back-merge has `source-branch` and `target-branch`; empty means the manifest's branches.

### Using the action directly

A site that needs something the manifest does not express can call the composite action itself
instead of the reusable verify workflow:

```yaml
# .github/workflows/verify.yml
name: Verify
on: [pull_request]
jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - uses: netliferesearch/craft-ci@v1
        with:
          snapshot-key: snapshots/<slug>/latest.sql.gz
          spaces-key: ${{ secrets.SNAPSHOT_READ_KEY }}
          spaces-secret: ${{ secrets.SNAPSHOT_READ_SECRET }}
```

This repo is public on purpose: it holds generic workflows, an action and scripts, no secrets and no
client data, so site repos in both GitHub organizations can use it without any access settings.

## Bucket and keys

One DigitalOcean Spaces bucket, `netlife-craft-snapshots` in `fra1`, standard storage, private,
no CDN. Layout:

```
snapshots/<slug>/latest.sql.gz      what verify and previews read; rewritten nightly
history/<slug>/YYYY-MM-DD.sql.gz    dated copies, expired after 14 days by a lifecycle rule
```

The control panel has no lifecycle settings; set the rule once over the S3 API with the write key:

```bash
cat > lifecycle.json <<'JSON'
{"Rules":[{"ID":"expire-history","Status":"Enabled","Filter":{"Prefix":"history/"},"Expiration":{"Days":14}}]}
JSON
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws s3api put-bucket-lifecycle-configuration \
  --bucket netlife-craft-snapshots --lifecycle-configuration file://lifecycle.json \
  --endpoint-url https://fra1.digitaloceanspaces.com
aws s3api get-bucket-lifecycle-configuration --bucket netlife-craft-snapshots \
  --endpoint-url https://fra1.digitaloceanspaces.com
```

Two access keys, both scoped to that bucket:

| Key | Scope | GitHub secrets (in both orgs) | Used by |
| --- | --- | --- | --- |
| read | read-only | `SNAPSHOT_READ_KEY`, `SNAPSHOT_READ_SECRET`, all repos | the verify action on every PR |
| write | read/write | `SNAPSHOT_WRITE_KEY`, `SNAPSHOT_WRITE_SECRET`, restricted to the site repos that run the snapshot job | the nightly snapshot workflow |

## Snapshot job

`scripts/snapshot.sh` dumps the production database through a read-only user, restores it into a
throwaway MySQL, applies `scripts/scrub.sql`, dumps again and uploads
`snapshots/<slug>/latest.sql.gz`. A site runs it nightly through the reusable workflow
`.github/workflows/snapshot.yml`, called from `.github/workflows/snapshot.yml` in the site repo
(`examples/snapshot.yml`), with the database credentials as that repo's secrets, the same pattern as
craft-cloud-remote-backups. Logs and credentials stay in the private site repo; this repo provides the
workflow and the script. The slug and the snapshot source come from the manifest: with `snapshot.source`
set to `none` the run ends with a notice and uploads nothing.

The shared `scrub.sql` anonymises users and empties sessions, tokens, the queue and announcements. It also
clears core Craft tables that hold credentials or personal data when they exist (`webauthn`,
`authenticator`, `recoverycodes`, `sso_identities`, `elementactivity`, `craftidtokens`, the user rows of
`searchindex`, draft notes, the personal columns of user-owned `addresses`) and replaces GraphQL access
tokens except the `__PUBLIC__` one. Each guarded statement checks `information_schema` first, so the
file runs on Craft 4 and 5 sites alike. `tests/scrub-sql.test.sh` runs it against MySQL 8.0 in docker.

For anonymisation beyond the shared `scrub.sql`, commit `.netlife/scrub.sql` in the site repo. The
workflow applies it to the throwaway copy right after the shared scrub, when the file exists. For a plain
list of tables to empty, the `scrub-truncate` input is enough.

Production is the source on purpose. Verify is a rehearsal of the deploy: a PR is cut from `main`
and, when it merges, its migrations and `project-config/apply` run against the production database.
Only a copy of production makes verify exercise that same path. A staging database can be ahead of
`main` (schema newer than the code, Craft refuses to boot) or behind it (verify is green on a path
production never takes). Use staging only for a site that has no production yet. What protects
personal data is the scrub, so reviewing `scrub.sql` against the site's own tables is a required
onboarding step, not an optional one.

For Forge sites, Forge's own scheduled database backups (a Business-plan feature, written to an
S3-compatible bucket such as Spaces) are an alternative source that keeps CI away from the production server entirely: the
snapshot job would download the newest backup file instead of dumping over SSH. Not built yet; see
the fleet design.

Per-site secrets (passed by name from the caller): `SOURCE_DB_HOST`, `SOURCE_DB_NAME`, `SOURCE_DB_USER`, `SOURCE_DB_PASSWORD`,
and for Forge and Servebolt sites `SOURCE_SSH_HOST`, `SOURCE_SSH_USER`, `SOURCE_SSH_KEY`.

Give the job its own MySQL user with `SELECT` only. The dump runs with
`--single-transaction --lock-tables=false --skip-triggers`, so that is all it needs, and nothing the
job does can write to the source. The dump does not lock tables; for a large database, keep the
schedule at night and look at the server's IO once.

```sql
CREATE USER 'snapshot'@'127.0.0.1' IDENTIFIED BY '<password>';
GRANT SELECT ON <database>.* TO 'snapshot'@'127.0.0.1';
```

How it reaches the production database depends on the host:

| Host | Reach the database by |
| --- | --- |
| Craft Cloud | a direct connection to the public RDS endpoint with read-only credentials from the Cloud console. The backup template (craft-cloud-remote-backups) already holds `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` in the repo, and `examples/snapshot-cloud-backup.yml` maps them onto `SOURCE_DB_*`, so there are no `SOURCE_SSH_*` secrets. Verify takes the four `CRAFT_CLOUD_*` values from the project's Cloud settings through `examples/verify-cloud.yml` |
| Forge | an SSH tunnel to the server (`SOURCE_SSH_HOST`, `SOURCE_SSH_USER`, `SOURCE_SSH_KEY`), database on localhost |
| Servebolt | an SSH tunnel the same way (`SOURCE_SSH_*`) |

The workflow hands the three SSH secrets to the script as `SSH_HOST`, `SSH_USER` and `SSH_KEY`. When
`SSH_HOST` is set the script opens the tunnel; when it is empty (Craft Cloud) it connects directly.

## Onboarding a site

`scripts/onboard.sh <owner>/<repo>` brings one site into the fleet and later reports drift. It needs
`gh` logged in with access to the repo.

```bash
scripts/onboard.sh Feedsystem/nch                          # dry run: reads, changes nothing
scripts/onboard.sh Feedsystem/nch --host cloud --apply     # apply the fixes
```

Options: `--slug S` (when the derived slug is not valid), `--develop B|none` (name the integration
branch without probing, or say there is none), `--host forge|servebolt|cloud` (when it cannot be
determined from the repo), `--apply`. With `--apply` it sets the repo topic and auto-merge, merges
branch protection on `main` with the existing rules (adds the required check `verify / verify`, strict
status checks, and removes required reviews, keeping everything else), enables Dependabot alerts and
Actions-created PRs, and writes `.netlife/fleet.json` and the callers on the branch
`netlife/fleet-onboarding`, opening the PR "Adopt craft-ci fleet configuration" (or pushing to the open
one). The local file checks live in `scripts/onboard-files.sh`. Secrets and variables are only checked,
never set.

Every output line starts with a prefix:

| Prefix | Meaning |
| --- | --- |
| `ok` | the check passes (or was just fixed with `--apply`) |
| `diff` | the repo differs from the fleet standard; `--apply` fixes it where it can |
| `todo` | something to do by hand, or a state that could not be read |
| `note` | a reminder to confirm; never changes the exit code |

Exit 0: no `diff` or `todo`. Exit 1: some `diff` or `todo`. Exit 2: usage error, the repo cannot be
cloned, or the host cannot be determined. Run it without `--apply` again after the work below; a clean
exit 0 means the site matches.

Stays manual:

- Secrets: set them as repo or organization secrets (the script lists what is missing).
- Renovate: add the repo to `repositories` in `netliferesearch/renovate` `config.js`.
- The GitHub App installation must include the repo.
- Review `scripts/scrub.sql` against the site's own tables, and add `.netlife/scrub.sql` for site-specific
  ones, before the first snapshot runs.
- Confirm the host deploys from `main` (Craft Cloud, Forge or Servebolt side).

## Back-merge to develop

Sites that keep a long-lived `develop` branch next to `main` call the reusable workflow
`.github/workflows/backmerge.yml` on every push to `main` (`examples/backmerge.yml`). It merges `main`
into `develop` and pushes: a fast-forward when `develop` has nothing of its own, a merge commit
otherwise, nothing when `develop` already contains `main`. On a conflict it aborts, opens one PR
"Back-merge main" from `main` into `develop` (never a second one while that is open) and fails the run
so someone resolves it, locally on a branch off `develop` since `main` is protected. Opening the PR
needs "Allow GitHub Actions to create and approve pull requests" in the repository's Actions settings;
without it the run says so and the PR must be opened by hand.

The branch names come from `branches.main` and `branches.develop` in `.netlife/fleet.json`. A site with
no `develop` branch on origin gets a notice and a clean skip, so the caller is safe to commit anyway. The
inputs `source-branch` and `target-branch` override the manifest. If the configured target branch (from
the manifest or the input) does not exist on origin, the run fails with "target branch ... not found on
origin" and opens nothing. The merge commit is authored by
`Craft CI <craft-ci@netlife.no>`.

## Layout

```
action.yml              the composite action
scripts/crawl.sh        sitemap crawl with status and log checks
scripts/backmerge.sh    merge main into develop and push, used by the reusable workflow
scripts/commit-project-config.sh  commit config/project changes back to the PR branch
scripts/snapshot.sh     dump, scrub, upload
scripts/scrub.sql       anonymization applied to the throwaway copy, never to the source
scripts/onboard.sh      onboard a site or report its drift (dry run by default)
scripts/onboard-files.sh  local file checks for onboard.sh
scripts/manifest.sh     resolve .netlife/fleet.json with defaults into KEY=value lines
fleet.schema.json       JSON Schema for .netlife/fleet.json
.github/workflows/verify.yml     reusable verify workflow for site repos
.github/workflows/snapshot.yml   reusable nightly snapshot workflow for site repos
.github/workflows/backmerge.yml  reusable back-merge workflow for site repos
examples/verify.yml     caller for verify
examples/snapshot.yml   caller for the nightly snapshot
examples/verify-cloud.yml            verify caller for Craft Cloud sites
examples/snapshot-cloud-backup.yml   snapshot caller for Craft Cloud sites
examples/backmerge.yml  caller for the back-merge
examples/fleet.json     the nch manifest, as a full example
tests/                  shell tests, run with bash tests/<name>.test.sh
```
