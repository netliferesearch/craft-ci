# Fleet phase 2: onboarding script, tested on nfi (Craft Cloud): design

Date: 2026-10-28. Builds on `2026-10-20-fleet-config-simplification-design.md` (the phase 2 row of its
build order, and its "Onboarding script" and "One registration" sections). Where this document
differs from that spec, this one wins.

## Intent

Onboarding a site into the fleet should take the smallest possible amount of setup and ongoing
management per project, credentials included. Phase 2 builds the onboarding script and proves it
on a real second site: Feedsystem/nfi (nfi.no), which runs on Craft Cloud. nfi is the first site
on a host other than Forge, so it also tests the Craft Cloud paths in verify and snapshot.

Done when: nfi is onboarded by `scripts/onboard.sh` plus the list of manual steps it prints, a
Renovate PR on nfi gets a green `verify / verify`, the nightly snapshot for nfi uploads
`snapshots/nfi/latest.sql.gz`, and re-running the script on nch and nfi reports no drift.

## Goals

- `scripts/onboard.sh` in craft-ci: dry run by default, `--apply` to change things, re-run as the
  drift check for one site.
- The `netlife-fleet` GitHub topic on every fleet repo, set by the script.
- nfi onboarded with Renovate, verify (required check), nightly snapshot and back-merge.
- No new database credentials for Craft Cloud sites that already run the backup template.
- Verify on Craft Cloud renders images through Craft Cloud's CDN, without an ignore pattern.

## Non-goals (this round)

- Setting secrets from 1Password with the `op` CLI. On the backlog.
- Renovate autodiscover by topic. Needs an App installation token per organization; nfi is added
  to `repositories` in netliferesearch/renovate's `config.js` by hand, like nch. Switching to
  `autodiscover` with `autodiscoverTopics: ["netlife-fleet"]` is a follow-up once the App is
  installed.
- Previews for nfi. craft-preview runs on our Forge server; nfi's preview caller is not written.
  The manifest may omit the `preview` block.
- The fleet audit (phase 3), project config drift (phase 4), Forge automation (phase 5).
- The `forge-backup` snapshot source. Stays on the roadmap.
- Replacing or changing nfi's existing backup workflow (`backup-database.yml`, `scripts/backup.sh`,
  `scripts/cleanup.sh`). It keeps running as is.

## Anti-goals

- The script must never write, overwrite or delete a secret value. It reads secret names only.
- Onboarding a Craft Cloud site must not require creating database credentials the site already has.
- Nothing in phase 2 writes to a production database or touches the production deploy settings.

## Decisions (Svale, 2026-10-28)

1. **Snapshot reuses the backup's database secrets.** Craft Cloud sites set up with the
   netliferesearch/craft-cloud-remote-backups template already hold `DB_HOST`, `DB_NAME`, `DB_USER`,
   `DB_PASSWORD` as repo secrets, and the backup dumps production with them every night (green
   since May on nfi). The snapshot caller maps those names onto the reusable workflow's
   `SOURCE_DB_*` secrets. Production is dumped twice a night (backup at 02:00 UTC, snapshot on its
   own schedule); that is accepted. The snapshot does not read the backup file.
2. **Full-access database user is acceptable on Craft Cloud.** The pilot spec asks for a
   SELECT-only user; Craft Cloud appears to offer one user only. The snapshot uses the same user as
   the backup. Forge and Servebolt sites keep the read-only user.
3. **The script checks secrets, it does not set them.** It lists the secret names a site needs for
   its host, compares them with what the repo (and its org, where readable) has, and prints the
   missing ones as manual steps. This replaces step 2 of the onboarding script in the
   simplification spec.
4. **Craft Cloud asset access in verify** uses four non-expiring values from Craft Cloud:
   `CRAFT_CLOUD_PROJECT_ID`, `CRAFT_CLOUD_ENVIRONMENT_ID`, `CRAFT_CLOUD_USE_ASSET_CDN`,
   `CRAFT_CLOUD_SIGNING_KEY` (production environment). They are read by the `craftcms/cloud`
   extension so asset and transform URLs point at Craft Cloud's CDN. They replace the
   `ImageTransformException` ignore pattern for Craft Cloud sites. (The 1-hour STS credentials used
   by nfi's local asset backup are a different thing and are not used here.)
5. **Order:** build the script now, before the GitHub App and org secrets exist. The script works
   in both states: shared secrets count as present whether they are repo or org secrets, and the
   verify workflow already falls back from the App to `RENOVATE_PUSH_TOKEN`.
6. **nfi's DDEV switches to MySQL 8.0** in the onboarding PR (`database: type: mysql, version:
   "8.0"`), so local development, verify and Craft Cloud run the same database and snapshots load
   locally. The nfi team needs a fresh database import after pulling it; the PR description says so.
   The script checks every site's `.ddev/config.yaml` and prints a manual step when the database is
   not MySQL 8.0 (it does not edit `.ddev/` itself).
7. **nfi's onboarding PR includes a reviewed `.netlife/scrub.sql`** before the snapshot caller is
   merged, so the first nightly snapshot never uploads unscrubbed personal data. The builder drafts
   it from nfi's schema (Formie submissions, social login tables, the custom auth and gamekey
   modules' tables, and any other table holding personal data) and Svale reviews it in the PR. For
   later sites the script prints the scrub review as a step that blocks merging the PR.

## The onboarding script

`scripts/onboard.sh <owner>/<repo> [--slug <slug>] [--develop <branch>|none] [--host forge|servebolt|cloud] [--apply]`

The host is detected when not given: `craft-cloud.yaml` in the repo root means `cloud`. Otherwise
the flag is required (Forge and Servebolt cannot be told apart from the repo).

Without `--apply`, it prints every check with its state and exits non-zero if anything differs.
With `--apply`, it:

1. Adds the `netlife-fleet` topic. Applies the repo settings as in the simplification spec: branch
   protection on `main` requiring `verify / verify` with strict status checks and no required
   reviews, auto-merge allowed, Dependabot alerts on, Actions allowed to create pull requests.
   Repo admin is enough for all of it.
2. Clones the repo into a temp directory on a branch, writes `.netlife/fleet.json` and the three
   callers (verify, snapshot, back-merge), removes `.craft-preview.json` if present,
   pushes the branch and opens a PR titled "Adopt craft-ci fleet configuration". An existing open
   PR with that title is updated, not duplicated.
3. Checks secret names (below) and prints what is missing.
4. Prints the remaining manual steps: App installation (if the repo is not in it), adding the repo
   to Renovate's `config.js`, missing secrets with where to find each value, scrub review
   (`.netlife/scrub.sql` for site-specific personal data), the deploy branch check on the host,
   and merging the PR once verify is green.

**Manifest content (builder's call, recorded here).** The script writes only keys whose value
differs from what `manifest.sh` would resolve without them (for nfi: probably `slug` only, plus
anything detection cannot get right). It never writes `preview` or a PHP version for a site
without previews. An existing manifest is kept as is and judged by its resolved values: drift means
`manifest.sh` output differs from what the script would resolve, not that the file text differs.
This keeps nch's minimal hand-written file valid.

**Previews are outside phase 2 (builder's call).** The script neither writes nor checks
`.github/workflows/preview.yml`; craft-preview has no reusable workflow yet, and nch's
full-length preview workflow stays as is.

**App detection (builder's call).** Svale's token cannot read App installations. The script uses
a proxy: when the repo has the variable `RENOVATE_APP_CLIENT_ID` and the secret
`RENOVATE_APP_PRIVATE_KEY` (repo or org), it treats the App as configured and `RENOVATE_PUSH_TOKEN`
as optional; otherwise `RENOVATE_PUSH_TOKEN` is required. The manual step "confirm the App
installation includes this repo" is always printed until phase 3's audit can check it.

Re-running is idempotent. On nch it must report no drift (nch's callers were written by hand in
phase 1; if they differ only in comments or ordering, the script's templates should be adjusted to
match nch rather than nch being rewritten).

### Secrets the script expects, by host

| Secret | forge, servebolt | cloud |
| --- | --- | --- |
| `SOURCE_DB_HOST`, `_NAME`, `_USER`, `_PASSWORD` | required | not used when the backup template's `DB_*` exist; required otherwise |
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | not used | required when `.github/workflows/backup-database.yml` exists |
| `SOURCE_SSH_HOST`, `_USER`, `_KEY` | required | not used |
| `CRAFT_CLOUD_PROJECT_ID`, `_ENVIRONMENT_ID`, `_USE_ASSET_CDN`, `_SIGNING_KEY` | not used | required |
| `SNAPSHOT_WRITE_KEY`, `_SECRET`, `SNAPSHOT_READ_KEY`, `_SECRET` | required (repo or org) | required (repo or org) |
| `RENOVATE_PUSH_TOKEN` | required unless the App is configured (see App detection) | same |
| `RENOVATE_APP_PRIVATE_KEY` secret, `RENOVATE_APP_CLIENT_ID` variable | checked, never required | same |

The snapshot caller the script writes for a cloud site with the backup template maps
`SOURCE_DB_HOST: ${{ secrets.DB_HOST }}` (and so on) and leaves out the SSH lines. All other
callers match `examples/`.

## Changes in craft-ci outside the script

- `verify.yml` (reusable) declares the four `CRAFT_CLOUD_*` values as optional secrets and appends
  the ones that are set to `.env` before Craft boots. A calling workflow cannot pass secrets
  through `with:` inputs, so `extra-env` cannot carry the signing key. The verify example and the
  script's template for cloud sites map them by name.
- A second example caller, or a commented block in `examples/snapshot.yml`, for the backup-template
  mapping.
- README: the hosting table gets the Craft Cloud row as built (direct connection, backup secrets
  reused, asset values), and the onboarding section points at the script.
- The phase 1 review follow-ups that touch onboarding docs are fixed in the same pass: README says
  four callers, the hosting table uses the `SOURCE_SSH_*` names, the README says verify does a fresh
  install when `snapshot.source` is `none`, and the schema's `default` annotations match the
  resolver.

## nfi facts the builder can rely on (checked 2026-10-28)

- Repo `Feedsystem/nfi`, private, default branch `main`, integration branch `develop`; `main` is
  unprotected, auto-merge off, Dependabot alerts off. Svale is repo admin.
- `craft-cloud.yaml`: PHP 8.2. `composer.json` platform PHP 8.2. Requires `craftcms/cloud ^3`,
  `spacecatninja/imager-x` with the Craft Cloud transformer, `cweagans/composer-patches` (a
  `patches/` directory exists). About half the requirements use `^` ranges (lockfile-only
  updates under the preset's `update-lockfile` strategy); the rest are pinned exactly (for example
  `spacecatninja/imager-x 6.0.0`, `nystudio107/craft-seomatic 5.1.21`), so their updates change
  `composer.json` too, as on nch.
- nfi's `.ddev/config.yaml` uses MariaDB 10.11. Craft Cloud runs MySQL 8, the snapshot job restores
  and dumps through MySQL 8.0, and verify boots DDEV from the site's own `.ddev/config.yaml`, so
  today verify on nfi would import a MySQL 8 dump into MariaDB. Decision 6 fixes this.
- Existing secrets: `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DO_SPACES_KEY`,
  `DO_SPACES_SECRET`; variables `DO_SPACES_BUCKET` (`nfi-db-backups`), `DO_SPACES_REGION` (`ams3`).
  The backup workflow runs daily at 02:00 UTC and takes 6 to 8 minutes.
- The `CRAFT_CLOUD_*` values are not yet repo secrets; Svale adds them when the script lists them.

## Left to the builder

- The script's language (bash with `gh` and `jq` like the rest of craft-ci is the default) and how
  it is tested (local tests with a stubbed `gh`, as for the existing scripts).
- Detecting org secrets: the API lists org secrets only for org admins. When it cannot read them,
  the script reports a shared secret as "missing on repo, may exist at org level" without failing.
- The snapshot cron for nfi (any time that does not overlap 02:00 to 02:15 UTC is fine).
- Verify's timeout for nfi if its snapshot is much larger than nch's; raise it in the manifest if
  the schema allows, otherwise in the reusable workflow.
- Whether `CRAFT_CLOUD_PROJECT_ID`, `_ENVIRONMENT_ID` and `_USE_ASSET_CDN` are better as repo
  variables than secrets. Secrets are the default (one place to look).
