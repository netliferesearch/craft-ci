# craft-ci

Shared verification for Netlife's Craft CMS sites. A composite GitHub Action that boots the
site in DDEV on the runner, seeds it with a scrubbed staging snapshot, runs migrations and
project config, and crawls the sitemap. Used on every Renovate PR and on any feature PR.

Hosting-neutral: the same action verifies sites on Forge, Servebolt and Craft Cloud, because it
never touches the host. Only the snapshot job and the deploy step differ per host.

## What the action does (v0, deliberately small)

1. `ddev start` from the repo's committed `.ddev/config.yaml`
2. `.env` from `.env.example.dev` or `.env.example`, plus DDEV's database variables. devMode is off and `CRAFT_ENVIRONMENT` is `staging` (input `environment`), so Twig and site configs behave as on the live site and nothing tries a Vite dev server; errors are read from `storage/logs`. Admin changes are allowed, because Craft and plugin update migrations write to project config and fail in read-only mode; the resulting YAML is what step 6 commits
3. `composer install`, and `npm ci && npm run build` when `package.json` has a `build` script
4. Snapshot import from the bucket when `snapshot-key` is set, otherwise a fresh install from project config
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

## Use from a site repo

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

This repo is public on purpose: it holds a generic action and scripts, no secrets and no client
data, so site repos in both GitHub organizations can use it without any access settings.

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

`scripts/snapshot.sh` dumps the source database (staging where one exists, otherwise production
through a read-only user), restores it into a throwaway MySQL, applies
`scripts/scrub.sql`, dumps again and uploads `snapshots/<slug>/latest.sql.gz`. It runs as a
nightly GitHub Actions workflow in each site repo (`examples/snapshot.yml`), with the staging
credentials as that repo's secrets, the same pattern as craft-cloud-remote-backups. Logs and
credentials stay in the private site repo; this repo only provides the script.

Per-site secrets: `SOURCE_DB_HOST`, `SOURCE_DB_NAME`, `SOURCE_DB_USER`, `SOURCE_DB_PASSWORD`,
and for Forge and Servebolt sites `SOURCE_SSH_HOST`, `SOURCE_SSH_USER`, `SOURCE_SSH_KEY`.

When the source is production, give the job its own MySQL user with `SELECT` only. The dump runs
with `--single-transaction --lock-tables=false --skip-triggers`, so that is all it needs, and
nothing the job does can write to the source:

```sql
CREATE USER 'snapshot'@'127.0.0.1' IDENTIFIED BY '<password>';
GRANT SELECT ON <database>.* TO 'snapshot'@'127.0.0.1';
```

How it reaches the staging database depends on the host:

| Host | Reach the database by |
| --- | --- |
| Craft Cloud | the public RDS endpoint and the credentials from the Cloud console (same as craft-cloud-remote-backups) |
| Forge | an SSH tunnel to the server (`SSH_HOST`, `SSH_USER`, `SSH_KEY`), database on localhost |
| Servebolt | an SSH tunnel the same way |

Set `SSH_HOST` and the script opens the tunnel; leave it empty and it connects directly.

## Back-merge to develop

Sites that keep a long-lived `develop` branch next to `main` call the reusable workflow
`.github/workflows/backmerge.yml` on every push to `main`. It merges `main` into `develop` and pushes:
a fast-forward when `develop` has nothing of its own, a merge commit otherwise, nothing when `develop`
already contains `main`. On a conflict it aborts, opens one PR "Back-merge main" from `main` into
`develop` (never a second one while that is open) and fails the run so someone resolves it, locally
on a branch off `develop` since `main` is protected. If the target branch does not exist the run fails
with that message and opens nothing. Opening the PR needs "Allow GitHub Actions to create and approve
pull requests" in the repository's Actions settings; without it the run says so and the PR must be
opened by hand.

```yaml
# .github/workflows/backmerge.yml
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

Inputs `source-branch` (default `main`) and `target-branch` (default `develop`). The merge commit is
authored by `Craft CI <craft-ci@netlife.no>`.

## Layout

```
action.yml              the composite action
scripts/crawl.sh        sitemap crawl with status and log checks
scripts/backmerge.sh    merge main into develop and push, used by the reusable workflow
scripts/commit-project-config.sh  commit config/project changes back to the PR branch
scripts/snapshot.sh     dump, scrub, upload
scripts/scrub.sql       anonymization applied to the throwaway copy, never to staging
examples/verify.yml     caller for a site repo
examples/snapshot.yml   nightly snapshot workflow for a site repo
.github/workflows/backmerge.yml  reusable back-merge workflow for site repos
tests/                  shell tests, run with bash tests/<name>.test.sh
```
