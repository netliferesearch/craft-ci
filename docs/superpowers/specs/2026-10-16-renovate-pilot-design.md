# Renovate pilot on nch: design

Date: 2026-10-17 (first draft 2026-10-16). Status: for approval. Part of the Craft fleet update
automation; the fleet-level design lives in the Claude doc "Craft Fleet Update Automation". This
document covers only the dependency-bump step, piloted on one site.

## Intent

Keep Netlife's Craft CMS sites continuously updated with as little human involvement as possible.
The verify action in this repo already proves on every PR that a site boots, migrates and serves its
sitemap. This pilot adds the thing that opens those PRs and merges the safe ones: a shared Renovate
setup, run against one site, Feedsystem/nch, until a patch update has gone from "Renovate opened it"
to "live on the site" without anyone touching it.

nch was chosen because verify already runs there from a nightly scrubbed production snapshot, all its
Composer packages come from Packagist and the public Craft Composer repository (no private plugins, no
token needed), and Forge push-to-deploy on `main` already runs composer install, the frontend build,
migrations and project config.

## Goals

1. A weekly grouped patch PR and a monthly grouped minor PR open on nch on their own. A PR for a
   package with a published vulnerability opens at once, outside the schedule.
2. The patch PR and the vulnerability PR merge on their own when verify is green, and Forge deploys.
3. The minor PR waits for a developer. Majors never open.
4. `develop` is kept in sync with `main` automatically after every merge.
5. The shared parts live in one repo that every later site can adopt with one line.

## Non-goals (this pilot)

- Other sites. The runner is pointed at nch only.
- npm dependencies. Composer only, until the composer loop has merged unattended a few times.
- Previews, the Claude Code fix job, Craft major upgrades, lock file maintenance.
- The GitHub App. The pilot runs on a personal fine-grained token and swaps to the App when the org
  admins have created it (planned for the week of 2026-10-19).
- A post-deploy check of our own. Forge's deployment notifications and health check cover it.

## Anti-goals

- A merge bot or workflow of our own that decides when to merge. GitHub's branch protection and
  Renovate's platform automerge are the only gates.
- Anything that lets a red or unverified PR reach `main`. If branch protection cannot require the
  verify check, automerge stays off.
- Per-site Renovate configuration beyond the one-line extends. Policy lives in the preset.

## Constraints

- Svale is a member, not an admin, in both GitHub organizations (netliferesearch and Feedsystem), but
  has admin on the Feedsystem/nch repository. Repo settings on nch are in reach; org settings are not.
- The site repo is in the Feedsystem org; the shared repos are in netliferesearch. The runner's token
  and the preset must work across that boundary.
- nch pins most packages exactly (`"verbb/formie": "3.1.47"`) and a few with a caret. Renovate must
  update `composer.json` and `composer.lock` together so a pinned package actually moves.
- nch's `composer.json` allows the `craftcms/plugin-installer` and `yiisoft/yii2-composer` plugins and
  sets `platform.php` to 8.2. Renovate's Composer manager must be allowed to run plugins and scripts,
  otherwise the lock update fails.
- PRs opened with the default Actions token do not trigger other workflows. PRs opened with a personal
  token or a GitHub App do. Verify must run on every Renovate PR, so the runner never uses the default
  token. The same applies to any commit pushed onto a Renovate branch by CI.
- The verify check on nch is the job named `verify` in `.github/workflows/verify.yml`, triggered on
  `pull_request`. It takes about three minutes.
- nch has a long-lived `develop` branch. Today it is behind `main` with nothing of its own, but the
  team has worked on it and released by PR from `develop` to `main`.
- Forge deploys are limited to 10 minutes and the nch site uses the standard (in-place) strategy, so a
  deploy that fails midway leaves the site on a half-updated tree.

## Decided design

### Branch flow

Agreed with Svale on 2026-10-17:

1. Renovate works in its own update branch off `main` and opens a PR against `main`.
2. CI does the full update on that branch: verify boots the site from the snapshot, runs `craft up`
   (migrations and project config), crawls the sitemap. If `craft up` changed anything under
   `config/project/`, CI commits that change back onto the Renovate branch, so the PR carries the
   project config the update produced.
3. The `verify` status passes. Renovate's platform automerge merges the PR to `main`.
4. The merge to `main` triggers the Forge push-to-deploy.
5. A workflow on push to `main` back-merges `main` into `develop`, so the two never drift. This runs
   for every merge to `main`, including vulnerability PRs and human releases.

Developers keep working on `develop` or on short branches, and release to `main` by PR. Those release
PRs pass through the same verify gate. Direct pushes to `main` stop, because branch protection
requires the check.

### Repo: `netliferesearch/renovate`

Public, like craft-ci, so the preset resolves from both organizations without access settings and the
runner's token only needs access to site repos. It holds no secrets in files. (Svale's call. A
private repo works too if the token is also granted read access to it.)

Three files:

| File | What it is |
| --- | --- |
| `default.json` | The preset. Every site extends it with `"extends": ["github>netliferesearch/renovate"]`. |
| `config.js` | Runner configuration: platform, the list of repositories, onboarding, Composer plugin and script permissions. |
| `.github/workflows/renovate.yml` | Scheduled workflow that runs Renovate with the token. |

Plus a short README saying what the repo is and how a site adopts it.

Protection of the token (my call, from the builder review): the `RENOVATE_TOKEN` secret lives in an
Actions environment on the renovate repo whose deployment branch rule allows only `main`, and `main`
on that repo is protected so changes arrive by PR. A PR run then has no token, and nobody with write
can push a workflow to `main` that prints it. Collaborators on the repo stay at Svale until the App
replaces the token.

### The preset (`default.json`)

Policy for every Craft site. For the pilot it is written for Composer only.

- Managers: Composer only. npm and GitHub Actions managers off for now.
- All Composer dependencies are treated alike. There is no separate group for Craft itself versus
  plugins versus other PHP packages; one site does not justify the distinction. (Svale's call.)
- Patch updates: one group named "Craft patches", scheduled weekly, early Monday morning.
- Minor updates: one group named "Craft minors", scheduled monthly, early in the month.
- Major updates: disabled.
- Vulnerability alerts on: a package with a published advisory gets its own PR immediately, outside
  any schedule, with automerge when the fix is a patch. Minor or major fixes open immediately but wait
  for a developer. This uses GitHub's Dependabot alerts on the repo (see "Gates on nch"); OSV is the
  fallback if alerts cannot be enabled.
- Automerge: enabled on the patch group and on patch-level vulnerability PRs only, `automergeType:
  pr`, platform automerge on. Minors never automerge.
- Range strategy such that exact pins are bumped in `composer.json` and caret ranges are left as
  ranges with the lock updated. The builder picks the Renovate setting that achieves this.
- Dependency dashboard on, so each site gets one issue listing pending and blocked updates.
- PRs labelled `renovate`. PR limit low (two or three open at once) so the groups do not pile up.
- Schedules use Europe/Oslo.

Automerge is written into the preset but the first grouped PR on nch is merged by hand (see rollout).
Until then the preset ships with automerge off, and the switch to on is a one-line PR in the renovate
repo.

### The runner (`config.js` and the workflow)

- The workflow runs on a schedule once a day, early morning Oslo time, and on `workflow_dispatch`.
  Renovate itself decides from the preset's schedules whether anything opens that day. Vulnerability
  PRs open on whichever daily run first sees the alert.
- It uses the official `renovatebot/github-action`, pinned to a release, with the token from the
  secret `RENOVATE_TOKEN`. The builder checks at step 1 of the rollout that netliferesearch's Actions
  policy allows that action; if not, the fallback is running the Renovate Docker image directly in a
  `container` job.
- `config.js` sets the GitHub platform, `repositories: ["Feedsystem/nch"]`, onboarding on so the first
  run opens an onboarding PR with the one-line `renovate.json`, and allows Composer plugins and
  scripts. Autodiscovery stays off during the pilot; adding a site means adding a line here.
- Renovate's own log level is info, visible in the Actions run. Nothing else is stored.
- The first run is a dry run (`dryRun: full`) dispatched by hand, so the plan is visible before any
  PR opens.

### Token

A fine-grained personal access token of Svale's, resource owner Feedsystem, repository access limited
to nch, with these permissions: Contents read and write, Pull requests read and write, Issues read and
write (for the dependency dashboard), Workflows read and write (Renovate may touch workflow files
later; without it Renovate refuses to push branches that contain them), Metadata read, and
Dependabot alerts read (for the vulnerability PRs). Expiry 90 days. Stored only as the
`RENOVATE_TOKEN` secret described above.

PRs will appear authored by Svale. That is acceptable for the pilot and goes away with the App.

If the Feedsystem org has fine-grained tokens disabled or requires approval that cannot be had this
week, fall back to a classic token with `repo` and `workflow` scopes, same storage, same expiry.

### Project config commit in CI

New, optional behaviour in the craft-ci verify action, off by default:

- Input `commit-project-config` (default `false`) and input `push-token` (default empty).
- After `craft up`, if `git status --porcelain config/project` is non-empty, commit those files with a
  fixed message ("Update project config after dependency update") and push to the PR's head branch
  using `push-token`.
- Push only when the PR comes from the same repository, never from a fork.
- The push must use a token that triggers workflows, so verify runs again on the new commit. During
  the pilot that is the same personal token as the runner, stored on nch as a repo secret. With the
  App it becomes an App installation token. If `push-token` is empty, the step prints the diff and
  fails the check instead, so an uncommitted project config change is never silently merged.
- Renovate treats a branch as "modified by someone else" by comparing commit authors. The builder
  confirms that commits made with the runner's own token are not treated that way, so Renovate keeps
  rebasing its branch. If they are, set Renovate's git author to match.

Note that verify runs with `allowAdminChanges=false`. Migrations still update project config (that is
allowed), so schema version bumps after a Craft or plugin update are what this step catches.

### Back-merge to develop

A reusable workflow in craft-ci, `.github/workflows/backmerge.yml`, called by a six-line workflow in
nch on `push` to `main`:

- Fetch `develop`, merge `main` into it, push. Fast-forward when possible, a merge commit otherwise.
- On a conflict: do not force anything. Open a PR from `main` into `develop` titled "Back-merge main"
  and fail the run so it shows up. A developer resolves it.
- Uses the default Actions token. Nothing needs to run on `develop` after the push, so the fact that
  this token does not trigger workflows is fine.
- Input `target-branch`, default `develop`, so sites with a different name can reuse it.

### Gates on nch

Repository settings, all within Svale's admin rights on nch and done on day one of the rollout:

- Branch protection on `main`: require status checks to pass before merging, with `verify` as a
  required check; require branches to be up to date before merging. Do not require pull request
  reviews. Renovate cannot approve its own PR, and a review requirement would make automerge
  impossible.
- Enable "Allow auto-merge" in the repository settings. It is off today.
- Squash merge stays enabled as the method Renovate uses. Issues stay enabled for the dashboard.
- Enable Dependabot alerts (Security settings). They are off today. Dependabot's own update PRs stay
  off; Renovate opens the PRs.

Renovate's platform automerge then merges when the check is green.

### Deploy and noticing failure

Forge push-to-deploy on `main` already runs: git pull, composer install, npm install and build,
clear caches, migrate, project-config apply. Changes recommended before automerge goes on, Svale's
call because they touch Forge:

- `set -e` at the top of the deploy script, so a failing command stops the deploy and Forge marks it
  failed. Today a failed migration does not stop the lines after it.
- `php craft db/backup` before `migrate/all`, so an unattended deploy always has a restore point.
- Deployment notifications to Slack on the nch site (site dashboard, Notifications tab). Forge also
  emails the site's failure recipients by default; make sure that list has someone on it.
- Forge's post-deploy health check on the site, pointed at the front page. Forge pings it from three
  regions after each deploy and notifies on failure.

Forge's API also exposes deployment history with status and output per deployment, and a deploy
webhook that posts the status and commit to a URL after each deploy. Neither is needed for the pilot.
They become relevant when CI wants to wait for a deploy or when previews need deploy status, and they
are noted in the fleet design for that work.

### Site files on nch

Two files:

`renovate.json` at the repo root, proposed by Renovate's onboarding PR:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>netliferesearch/renovate"]
}
```

`.github/workflows/backmerge.yml`, calling the reusable workflow in craft-ci on push to `main`.

And one change to the existing `verify.yml`: `commit-project-config: true` with `push-token` from a
repo secret.

## Rollout

1. Repo settings on nch as listed under "Gates on nch". Create the renovate repo with the three files
   and README, token in its environment. Dispatch a dry run against nch and read the log: which
   packages, which groups, which schedule.
2. Ship the back-merge workflow and the project-config-commit option in craft-ci (new tag), and the
   caller plus `verify.yml` change on nch. Confirm a push to `main` lands on `develop`.
3. Let the real run open the onboarding PR on nch. Merge it.
4. The next scheduled window opens "Craft patches". Verify runs. A developer reads the PR and merges
   it by hand. Forge deploys. Check the site and the back-merge.
5. Forge changes from "Deploy and noticing failure". Switch automerge on in the preset.
6. Done when the following patch group merges, deploys and back-merges with nobody involved, and the
   dependency dashboard issue on nch reflects it.

Nothing in this list needs the org admins.

## Left to the builder

- Exact Renovate option names and values for grouping, schedules, vulnerability alerts, range
  strategy, automerge and the dashboard. Verify against current Renovate docs, not memory; Renovate
  renames options.
- Which release of `renovatebot/github-action` to pin, and how `config.js` and `default.json` split
  responsibilities (runner-only settings in `config.js`, policy in `default.json`).
- Handling of nch's PHP 8.2 platform constraint when Renovate resolves the lock.
- Git identity for the CI project-config commit and for the back-merge commit.
- README wording.

## Open questions for Svale

None blocking. Items marked "Svale's call" above are decided unless Svale says otherwise when reading.

## Later, not now

- GitHub App replaces the token; `config.js` and the nch push secret switch to app credentials.
- Autodiscovery across both orgs once the preset has proven itself on nch.
- npm manager on, with its own groups.
- The Claude Code fix job on red PRs, and previews for minor groups, as in the fleet design. The
  Forge API makes a preview on demand feasible: a workflow that runs when a reviewer is requested or a
  label is added, provisions the preview and comments the URL on the PR.
