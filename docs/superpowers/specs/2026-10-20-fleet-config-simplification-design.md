# Fleet config and onboarding simplification: design

Date: 2026-10-20. Status: for approval. Part of the Craft fleet update automation; the fleet-level
design lives in the Claude doc "Craft Fleet Update Automation". This document covers how a site is
configured and onboarded across the three shared repos (craft-ci, renovate, craft-preview), and how
that configuration is kept from drifting.

## Intent

Onboarding a site today means copying four workflow files, writing a manifest, setting a dozen
secrets, applying four repo settings by hand, editing a list in the renovate repo, and configuring
the Forge server. Every one of those is a place where a site can be set up slightly differently
from the next, or fall behind when the shared repos change. The goal is that a site carries one
small file, four five-line callers and only the secrets that are genuinely its own, that
registering a site is a single act, and that a nightly check tells us when any site has drifted.

## Goals

1. A site's own configuration is one file, `.netlife/fleet.json`, with defaults good enough that a typical
   site commits it with zero or one key.
2. The per-site workflow files are thin callers of reusable workflows. Changes to steps, inputs
   and fixes happen in the shared repos and reach every site without touching it.
3. A site is registered once, by a GitHub topic, and every shared tool derives the fleet list
   from that topic.
4. One idempotent script onboards a site and, re-run, repairs it.
5. A nightly audit reports every site whose configuration or state differs from the expected.
6. Verify reports Craft project config drift between production and the repo.
7. The Forge steps that the API supports are scripted.

## Non-goals

- Changing what verify checks, what Renovate updates or how previews work. Only how they are
  configured and wired per site.
- A web dashboard. The audit writes one issue.
- Migrating every existing site at once. nch moves first, as the test; others move as they onboard.

## Anti-goals

- A second manifest format. `.craft-preview.json` is folded into `.netlife/fleet.json`, not kept beside it.
- Fleet-level values in the per-site file (Forge org, server id, preview domain, bucket name,
  certificate id, retention). Those are org variables or defaults in the actions.
- Secrets in the manifest, ever. The manifest is committed and validated as such.

## Decided design

### One manifest: `.netlife/fleet.json`

Named for ownership and purpose (decided 2026-10-25). A bare `craft.json` would read as something Craft
itself ships; `.netlife/` says whose tooling it is, `fleet.json` says what it configures, and the
directory sits next to `.ddev/` and `.github/` as the other tooling directories do. The directory is
also the home for the few other per-site files our tooling may need, so none of them has to invent a
new top-level name:

| File | Holds | Status |
| --- | --- | --- |
| `.netlife/fleet.json` | this manifest. Haven does not read it today; if it ever gains a production hosting field, Haven can read that as a manifest-sourced hosting signal | phase 1 |
| `.netlife/scrub.sql` | site-specific anonymisation applied after the shared `scrub.sql` (replaces the `SCRUB_TRUNCATE` env var for anything beyond a table list) | phase 1, snapshot workflow |
| `.netlife/haven.json` | Haven's repo manifest (customer link, project type, `environments[]` with production and staging URLs), validated against Haven's `haven.schema.json`. Haven reads it at this path (moved from the repo root on 2026-10-25). Owned by the Haven project; nothing else writes it | Haven |

Read by every shared workflow and action. Validated against `fleet.schema.json`, published in
craft-ci, and mirrored by the zod schema in craft-preview (a test keeps the two in step).

```json
{
  "$schema": "https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json",
  "slug": "nch",
  "snapshot": { "source": "production", "key": "snapshots/nch/latest.sql.gz" },
  "verify": { "crawlLimit": 40, "ignoreLogPattern": "", "environment": "staging" },
  "branches": { "main": "main", "develop": "develop" },
  "preview": {
    "phpVersion": "php82",
    "webDirectory": "/web",
    "buildCommand": "npm ci && npm run build",
    "siteUrls": { "PRIMARY_SITE_URL": "/" },
    "env": {},
    "domain": "on-forge",
    "maxAgeDays": 14
  }
}
```

The preview design (craft-preview, `docs/superpowers/specs/2026-10-19-craft-preview-design.md`) and
its decisions stand: previews only on the `preview` label, Forge `on-forge.com` hostnames, one shared
Laravel VPS server, the snapshot read with craft-ci's read-only Spaces key through a 7-day presigned
URL, `.env` composed on the repo's `.env.example`. This document only moves its manifest fields into
`.netlife/fleet.json`.

Every key has a default, so the file above is what nch would get after `onboard.sh` fills in
what it detected; a site that matches the defaults commits `{}` or just the `slug`.

| Key | Default | Derived from |
| --- | --- | --- |
| `slug` | repository name, lowercased, characters outside `[a-z0-9]` removed, first 12; must then match `^[a-z][a-z0-9]{1,11}$` or resolution fails with "set slug" (it names a MySQL schema and a hostname label) | `GITHUB_REPOSITORY` |
| `snapshot.source` | `production` | `staging` only for a site with no production; `none` for a fresh install from project config; `forge-backup` reserved (see fleet design) |
| `snapshot.key` | `snapshots/<slug>/latest.sql.gz` | slug |
| `verify.crawlLimit` | `40` | |
| `verify.ignoreLogPattern` | `""` | |
| `verify.environment` | `staging` | |
| `branches.main` | `main` | |
| `branches.develop` | `develop` if that branch exists on origin, else `null` (no back-merge) | `git ls-remote` |
| `preview.phpVersion` | `config.platform.php` in `composer.json`, else the lower bound of `require.php` (`^8.2`, `>=8.2`, `~8.2.0`, `8.2.*` all give 8.2); major.minor mapped to Forge's names `php82`.. `php85`. Nothing resolvable, or a version outside that set, fails with "set preview.phpVersion": the preview server only has the versions we installed, so a silent default would be wrong | composer.json |
| `preview.webDirectory` | `/web` | |
| `preview.buildCommand` | `npm ci && npm run build` when `package.json` has a `build` script, else none | package.json |
| `preview.siteUrls` | one entry per `config/project/sites/*.yaml` whose `baseUrl` is an env reference (`$PRIMARY_SITE_URL` style): that env var name with path `/`. A manifest value merges over it (`{"EN_URL": "/en"}`), which is the only way a non-root path gets in. Sites with a literal `baseUrl` yield nothing | project config |
| `preview.domain` | `"on-forge"` (string enum `on-forge` or `custom`) | the base domain and certificate id for `custom` are fleet-level: action inputs fed from org variables, never in the manifest |
| `preview.env`, `preview.maxAgeDays`, `preview.language` | as in craft-preview today | |

Defaults are resolved by code, since a JSON Schema does not apply them: `scripts/manifest.sh` in
craft-ci (bash and jq) resolves the keys verify, snapshot and back-merge need and prints them as
`KEY=VALUE` lines; craft-preview's CLI gets a `config` command that prints the fully resolved manifest
as JSON, which the action runs first so its bash steps (the snapshot presign) and its Node code read
one result. The two implementations overlap on `slug` and `snapshot.key` only. That overlap is pinned
by a shared fixture, `tests/fixtures/manifest-cases.json` in craft-ci (input manifest and
`GITHUB_REPOSITORY` to expected slug and key), which craft-preview copies into its tests, so the two
cannot disagree without a test failing. The schema is the contract for shape; the fixture is the
contract for derivation.

### Thin callers

Reusable workflows (`workflow_call`) in the shared repos, called with the secrets mapped by name
(GitHub honours `secrets: inherit` only inside one organization, and the fleet spans two; found on
the first live run, 2026-10-25):

| Site file | Calls | Lines in the site repo |
| --- | --- | --- |
| `.github/workflows/verify.yml` | `netliferesearch/craft-ci/.github/workflows/verify.yml@v1` | 8 |
| `.github/workflows/snapshot.yml` | `netliferesearch/craft-ci/.github/workflows/snapshot.yml@v1` | 10 (the schedule must sit in the caller) |
| `.github/workflows/backmerge.yml` | `netliferesearch/craft-ci/.github/workflows/backmerge.yml@v1` (exists) | 8 |
| `.github/workflows/preview.yml` | `netliferesearch/craft-preview/.github/workflows/preview.yml@v1` | 12 (the label gate stays in the caller) |

The reusable workflows read `.netlife/fleet.json`, resolve defaults, and call the composite actions with
the resolved values. The snapshot workflow also passes `.netlife/scrub.sql` to the snapshot script when the
file exists; the script applies it to the throwaway copy after the shared scrub. The composite actions keep their inputs, so a site that needs something the
manifest does not express can still call the action directly. The caller lists the secret names it maps, never values, so a site file still carries nothing
site-specific. The Spaces and App secrets should be org secrets scoped to the right repos (the admin
round in the onboarding note).

The push token for the project config commit is minted inside the reusable verify workflow with
`actions/create-github-app-token` from `RENOVATE_APP_CLIENT_ID` and `RENOVATE_APP_PRIVATE_KEY`, so
no site holds a push token of its own.

### One registration: the `netlife-fleet` topic

A repository is in the fleet when it carries the GitHub topic `netlife-fleet`. Consumers:

- Renovate: `autodiscover: true`, `autodiscoverTopics: ["netlife-fleet"]` in `config.js`, one runner
  job per organization (an installation token covers one org), replacing the `repositories` list.
- The fleet audit and any later tooling: `gh search repos --topic netlife-fleet --owner <org>`.
- The GitHub App installation still has to include the repo; the onboarding script reports when
  it does not, and the audit catches it later.

### Onboarding script

`scripts/onboard.sh <owner>/<repo> [--slug <slug>] [--develop <branch>|none] [--apply]` in craft-ci.
Without `--apply` it prints what it would change and exits non-zero if anything differs. With
`--apply` it:

1. Adds the topic. Applies the repo settings: branch protection on `main` requiring `verify` with
   strict status checks and no required reviews, auto-merge allowed, Dependabot alerts on, Actions
   allowed to create pull requests.
2. Sets the per-site secrets it is given on the command line or from 1Password through the `op`
   CLI (`SOURCE_DB_*`, `SOURCE_SSH_*`), and the shared ones only where no org secret exists.
3. Clones the repo, writes `.netlife/fleet.json` with detected values and the four callers, removes
   `.craft-preview.json` if present, opens a PR titled "Adopt craft-ci fleet configuration".
4. Prints what still needs a human: App installation, Forge steps, scrub review.

Re-running on an onboarded site is the drift check for that site; the audit runs the same checks
for all of them.

### Fleet audit

`.github/workflows/fleet-audit.yml` in craft-ci, nightly after the snapshot and Renovate windows,
running `scripts/fleet-audit.sh`. For every repo with the topic, in both orgs:

| Check | Expected |
| --- | --- |
| callers | the four files exist and reference `@v1` |
| manifest | validates against `fleet.schema.json` |
| settings | the four repo settings as the onboarding script applies them |
| secrets | the required secret names exist (names only, through the API) |
| snapshot | `latest.sql.gz` for the slug is younger than 36 hours |
| verify | the last verify run on a PR was green, or no PR in 14 days |
| Renovate | the Dependency Dashboard issue exists and has no "blocked" or "edited" entries |
| App | the repo is in the installation |

Output: one issue in craft-ci titled "Fleet audit", body replaced on every run with a table (repo,
check, state, detail), closed when everything passes and reopened when not. Slack later, through
the issue's notifications.

### Craft project config drift

A step in the verify action after the snapshot import and before `project-config/apply`:
`craft project-config/diff`. A non-empty diff means production's stored config differs from the
repo's YAML, usually because someone changed something in the production control panel. Input
`project-config-drift` with values `warn` (default: a `::warning::` annotation with the first 40
lines), `fail`, `ignore`. The audit counts warnings per site so the default can be revisited.

### Forge automation

The Forge steps a production site needs: a `SELECT`-only MySQL user, an SSH key restricted to a
tunnel in `authorized_keys`, `set -euo pipefail` in the deploy script, Slack notifications, the
health check at `/actions/app/health-check`. craft-preview already has a tested Forge API v2 client;
the production-side automation goes in the same repo as a separate CLI command so the client is
shared. Known from that work: site show is org-scoped (`GET /orgs/{org}/sites/{id}`, no
server-scoped GET), list endpoints take `filter[name]`, and the limit is 60 requests a minute. Which
of the steps the API supports is unknown and marked `VERIFY`, in the same list the preview endpoints
are on: database users with read-only grants, SSH keys with `command=` options (recipes run as root
are the fallback), deploy script update, notification and health check settings. Laravel VPS servers
block SMTP ports, which matters if onboarding ever configures mail. Built after the preview's own API
verification, since it is the same work.

## Build order

| Phase | Builds | Done when |
| --- | --- | --- |
| 1 | `.netlife/fleet.json` schema and resolver, reusable verify and snapshot workflows, backmerge reading the manifest, craft-preview reading `.netlife/fleet.json`, nch switched over | nch runs all four callers from the manifest with no per-site values in the workflow files |
| 2 | onboarding script, topic, Renovate autodiscover per org | a second site is onboarded by the script alone, plus the human list it prints |
| 3 | fleet audit | the audit issue is green for both sites and goes red when a caller is edited by hand |
| 4 | project config drift step | a control panel change on nch shows up as a warning on the next PR |
| 5 | Forge automation | the onboarding script's human list no longer contains Forge steps the API can do |

Phase 4 is small and independent; it can go whenever someone touches the action. Phase 1 has an
implementation plan: `docs/superpowers/plans/2026-10-20-fleet-config-phase-1.md`. Later phases get
plans when their turn comes.

## Left to the builder

- Exact mapping from `platform.php` values (`8.2`, `8.3.0`) to Forge PHP version names.
- How `siteUrls` is derived when a site's `baseUrl` is a literal URL rather than an env var.
- Whether the reusable snapshot workflow can declare the MySQL service container itself (it can;
  services are allowed in reusable workflow jobs) and how the caller passes the schedule.
- `gh search repos` paging and rate limits for the audit, and the 1Password item naming.

## Open questions for Svale

- Does any current site deploy from `develop` to a staging environment that should also be
  verified? If so, `branches` grows a `staging` key and the verify caller runs on PRs to it. Not
  assumed in phase 1.
- The audit issue in craft-ci is public. If repo names of client sites should not be, the issue
  moves to a private repo (the renovate repo is also public), or the audit posts to Slack only.
