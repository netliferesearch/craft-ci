# craft-ci

Shared verification for Netlife's Craft CMS sites. A composite GitHub Action that boots the
site in DDEV on the runner, seeds it with a scrubbed staging snapshot, runs migrations and
project config, and crawls the sitemap. Used on every Renovate PR and on any feature PR.

Hosting-neutral: the same action verifies sites on Forge, Servebolt and Craft Cloud, because it
never touches the host. Only the snapshot job and the deploy step differ per host.

## What the action does (v0, deliberately small)

1. `ddev start` from the repo's committed `.ddev/config.yaml`
2. `.env` from `.env.example.dev` or `.env.example`, plus DDEV's database variables
3. `composer install`, and `npm ci && npm run build` when `package.json` has a `build` script
4. Snapshot import from the bucket when `snapshot-key` is set, otherwise a fresh install from project config
5. `craft migrate/all`, `craft project-config/apply`, `craft clear-caches/all`
6. Crawl: every URL in `sitemap.xml` (capped by `crawl-limit`), fail on any non-2xx/3xx, then fail on new `[error]` lines in Craft's log

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

One DigitalOcean Spaces bucket, `netlife-craft-snapshots` in `fra1`, private, no CDN, with a
lifecycle rule that deletes the dated copies after 14 days (`latest.sql.gz` is rewritten nightly).
Two access keys, both scoped to that bucket:

| Key | Scope | GitHub secrets (in both orgs) | Used by |
| --- | --- | --- | --- |
| read | read-only | `SNAPSHOT_READ_KEY`, `SNAPSHOT_READ_SECRET`, all repos | the verify action on every PR |
| write | read/write | `SNAPSHOT_WRITE_KEY`, `SNAPSHOT_WRITE_SECRET`, restricted to the site repos that run the snapshot job | the nightly snapshot workflow |

## Snapshot job

`scripts/snapshot.sh` dumps a staging database, restores it into a throwaway MySQL, applies
`scripts/scrub.sql`, dumps again and uploads `snapshots/<slug>/latest.sql.gz`. It runs as a
nightly GitHub Actions workflow in each site repo (`examples/snapshot.yml`), with the staging
credentials as that repo's secrets, the same pattern as craft-cloud-remote-backups. Logs and
credentials stay in the private site repo; this repo only provides the script.

Per-site secrets: `STAGING_DB_HOST`, `STAGING_DB_NAME`, `STAGING_DB_USER`, `STAGING_DB_PASSWORD`,
and for Forge and Servebolt sites `STAGING_SSH_HOST`, `STAGING_SSH_USER`, `STAGING_SSH_KEY`.

How it reaches the staging database depends on the host:

| Host | Reach the database by |
| --- | --- |
| Craft Cloud | the public RDS endpoint and the credentials from the Cloud console (same as craft-cloud-remote-backups) |
| Forge | an SSH tunnel to the server (`SSH_HOST`, `SSH_USER`, `SSH_KEY`), database on localhost |
| Servebolt | an SSH tunnel the same way |

Set `SSH_HOST` and the script opens the tunnel; leave it empty and it connects directly.

## Layout

```
action.yml              the composite action
scripts/crawl.sh        sitemap crawl with status and log checks
scripts/snapshot.sh     dump, scrub, upload
scripts/scrub.sql       anonymization applied to the throwaway copy, never to staging
examples/verify.yml     caller for a site repo
examples/snapshot.yml   nightly snapshot workflow for a site repo
```
