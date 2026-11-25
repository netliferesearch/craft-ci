# Snapshot: schema-only cache table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the nightly nfi snapshot from timing out by never transferring or restoring the rows of Craft's `cache` table.

**Architecture:** `scripts/snapshot.sh` gains one environment variable, `SCHEMA_ONLY_TABLES` (default `cache`). For each listed table that exists in the source database, the production dump skips its rows (`--ignore-table`) and a second, `--no-data` dump appends its `CREATE TABLE`. The scratch restore and the shared scrub stay as they are: `DELETE FROM cache` in `scrub.sql` now runs on an empty table. No workflow input changes, so site callers and `v1` keep working unchanged; the fix reaches the fleet by moving the `v1` tag.

**Tech Stack:** bash, mysqldump/mysql 8 clients, the repo's shell test harness (`tests/lib.sh`), docker for `scrub-sql.test.sh`.

**Spec:** none. The problem statement is the Background section below; it comes from the 25 Nov 2026 craft-ci session (fleet memory `renovate-pilot-state`).

## Background

nfi's nightly `Snapshot` workflow has hit its 30-minute `timeout-minutes` on 16, 19 and every night 21 to 25 Nov 2026. The newest `snapshots/nfi/latest.sql.gz` is from 20 Nov, so every nfi verify ran against a stale database. Cancelled runs keep no logs. Evidence for the cause:

| Phase in the last good run (20 Nov) | Minutes |
| --- | --- |
| mysqldump production → `raw.sql` | 6 |
| restore `raw.sql` into scratch MySQL, run `scrub.sql` | 5 |
| dump scratch, gzip, upload | 1 |

- nfi's separate Daily Database Backup dumps the same database in 6 to 8 minutes every night, including 25 Nov. The production dump is not what grew.
- `scrub.sql` already notes that nfi's `cache` table (Craft's DbCache; Craft Cloud uses DbCache unless Valkey is enabled, and Yii's DbCache garbage-collects with probability 100 in 1,000,000 per write, so expired rows accumulate) was 2.4 GB of a 3 GB dump in October.
- The failure is bimodal, not a growth curve: successful runs on 14, 15, 17, 18 and 20 Nov took 9 to 12.5 minutes; 16, 19 and 21 to 25 Nov timed out. The backup's full-dump time is flat from 14 to 25 Nov, so the table has not grown enough to explain the jump by itself. Phase split from the good runs: 18 Nov dump 5:09, restore and scrub 3:01; 20 Nov dump 6:03, restore and scrub 5:31.
- The phase unique to the snapshot is restoring 2.4 GB of InnoDB rows into the service container's MySQL (default 128 MB buffer pool, 100 MB redo log) and then row-deleting them. Runner IO variance on that phase is the likely tipping point. nch, whose cache is small, takes 2 to 4 minutes.

Dumping the cache table schema-only removes that phase entirely, whatever tips it over. `DELETE FROM cache` stays in `scrub.sql` as a guard for a site that overrides `SCHEMA_ONLY_TABLES`. Task 0 confirms the table is still the dominant one before anything is built; Task 3 carries the fallback if a run still times out after the fix (then the stall is in the production dump itself, which has no client-side read timeout).

## Global Constraints

- `scripts/snapshot.sh` keeps `set -euo pipefail`; any failure of the new query or dump pass must fail the run, never silently produce a snapshot without a table.
- The source connection stays read-only (`SELECT` on the database, plus `information_schema`, which every user can read for its own tables). No new privileges.
- Table names are Craft's without prefix, like `scrub.sql` (README "Snapshot job").
- The `--no-data` pass uses the same connection and the same safety flags as the main dump: `--single-transaction --quick --no-tablespaces --skip-triggers --set-gtid-purged=OFF --lock-tables=false`.
- No change to `.github/workflows/snapshot.yml` inputs or secrets; `tests/workflows.test.sh` must still pass unchanged.
- Nothing is pushed and `v1` is not moved without Svale's go-ahead (Task 3 is Svale's).

## Review Focus

1. **Cache table absent** (a site without DbCache): no `--ignore-table`, no second dump pass, run succeeds. Pinned in Task 1 (`test_schema_only_skipped_when_table_absent`).
2. **Existence query fails** (wrong credentials, host down): the script exits non-zero before dumping, instead of treating the table as absent. Pinned in Task 1 (`test_existence_query_failure_aborts`).
3. **SSH-tunnel sites** (Forge, Servebolt): the existence query must use the tunnel's `host`/`port`, which are only set after the tunnel is up. Pinned in Task 1 by asserting the query's `--host=127.0.0.1 --port=3309` when `SSH_HOST` is set (`test_existence_query_uses_tunnel`).
4. **Table prefix sites** (`craft_cache`): the default does not match and the run behaves as case 1, slow but correct. Out of scope; noted in the README line Task 2 adds, as it is for the rest of `scrub.sql`.
5. **`SCHEMA_ONLY_TABLES` set empty by a caller**: no table is treated schema-only, identical to today's behaviour. Pinned in Task 1 (`test_schema_only_empty_is_noop`).

---

### Task 0 (Svale): confirm the cache table is still the dominant one

Read-only, one minute, no push. Either command settles it.

- [ ] **Step 1: Daily backup sizes** (with the nfi backup bucket's credentials from 1Password, piped)

```bash
aws s3 ls s3://nfi-db-backups/nfi-prod/db/ --human-readable --endpoint-url https://fra1.digitaloceanspaces.com | tail -12
```

Expected: sizes flat from 14 to 25 Nov (no growth; the restore phase is the problem regardless).

- [ ] **Step 2: Table sizes on production** (with the read-only nfi DB credentials)

```sql
SELECT table_name, table_rows, ROUND((data_length + index_length) / 1e9, 2) AS gb
FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY data_length DESC LIMIT 5;
```

Expected: `cache` first by a wide margin. If it is not, stop: this plan fixes the wrong table, and the next largest table is the one to look at.

### Task 1: schema-only tables in `scripts/snapshot.sh`

**Files:**
- Modify: `scripts/snapshot.sh:5-6` (header comment), `scripts/snapshot.sh:25-28` (dump)
- Test: `tests/snapshot-scrub.test.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: env `SCHEMA_ONLY_TABLES` (space-separated, default `cache`); log lines `schema only: <table>` per table that exists, and `schema only: none` when no listed table exists.

- [ ] **Step 1: Extend the shims so the `mysql` shim can answer the existence query**

In `make_shims` in `tests/snapshot-scrub.test.sh`, replace the `mysql` shim body with one that prints `$SHIM_TABLE_EXISTS` (default `1`) and exits `$SHIM_QUERY_EXIT` (default `0`) when its arguments contain `information_schema`, and otherwise logs as today:

```bash
#!/usr/bin/env bash
if [[ "$*" == *information_schema* ]]; then echo "QUERY $*" >> "$SHIM_LOG"; echo "${SHIM_TABLE_EXISTS:-1}"; exit "${SHIM_QUERY_EXIT:-0}"; fi
{ echo "CALL $*"; [ -t 0 ] || cat; } >> "$SHIM_LOG"
```

Replace the `mysqldump` shim with one that logs its arguments too: `echo "DUMP $*" >> "$SHIM_LOG"; echo "-- dump $*"`.

- [ ] **Step 2: Write the failing tests**

Add to `tests/snapshot-scrub.test.sh`, before `run_tests`:

```bash
test_schema_only_cache_by_default() {
  make_shims
  run_script
  assert_eq 0 "$CODE" "exit code"
  grep -q 'DUMP .*--ignore-table=n\.cache n$' "$T/log"; assert_eq 0 $? "main dump ignores n.cache"
  grep -q 'DUMP .*--no-data n cache$' "$T/log"; assert_eq 0 $? "second pass dumps cache schema"
  grep -q '^schema only: cache$' "$T/out"; assert_eq 0 $? "prints the schema-only table"
  local main nodata
  main="$(grep -n 'DUMP .*--ignore-table' "$T/log" | head -1 | cut -d: -f1)"
  nodata="$(grep -n 'DUMP .*--no-data' "$T/log" | head -1 | cut -d: -f1)"
  [ -n "$main" ] && [ -n "$nodata" ] && [ "$main" -lt "$nodata" ]
  assert_eq 0 $? "schema pass runs after the data dump (lines '$main' '$nodata')"
}

test_schema_only_skipped_when_table_absent() {
  make_shims
  run_script SHIM_TABLE_EXISTS=0
  assert_eq 0 "$CODE" "exit code"
  grep -q 'ignore-table' "$T/log"; assert_eq 1 $? "no --ignore-table"
  grep -q 'no-data' "$T/log"; assert_eq 1 $? "no --no-data pass"
  grep -q '^schema only: none$' "$T/out"; assert_eq 0 $? "prints none"
}

test_schema_only_empty_is_noop() {
  make_shims
  run_script SCHEMA_ONLY_TABLES=
  assert_eq 0 "$CODE" "exit code"
  grep -q 'QUERY ' "$T/log"; assert_eq 1 $? "no existence query"
  grep -q 'ignore-table\|no-data' "$T/log"; assert_eq 1 $? "plain dump"
}

test_existence_query_failure_aborts() {
  make_shims
  run_script SHIM_QUERY_EXIT=1
  [ "$CODE" -ne 0 ]; assert_eq 0 $? "non-zero exit (got $CODE)"
  grep -q 'DUMP ' "$T/log"; assert_eq 1 $? "nothing dumped"
}

test_existence_query_uses_tunnel() {
  make_shims
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
  run_script SSH_HOST=bastion SSH_USER=u SSH_KEY=k
  assert_eq 0 "$CODE" "exit code"
  grep -q 'QUERY .*--host=127.0.0.1 .*--port=3309 ' "$T/log"; assert_eq 0 $? "query goes through the tunnel"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/snapshot-scrub.test.sh`
Expected: the two existing tests pass; four of the five new ones fail (no `--ignore-table`, no `schema only:` line, exit 0 where non-zero is expected). `test_schema_only_empty_is_noop` passes by construction against the unchanged script; it is a regression guard, not a red test.

- [ ] **Step 4: Implement in `scripts/snapshot.sh`**

Between the tunnel block and `echo "dumping ..."`:

- `SCHEMA_ONLY_TABLES="${SCHEMA_ONLY_TABLES-cache}"` (the `-` form, so an explicitly empty value stays empty).
- `src=(mysql --host="$host" --port="$port" --protocol=TCP --user="$DB_USER" --password="$DB_PASSWORD")` and `dump_opts=(--single-transaction --quick --no-tablespaces --skip-triggers --set-gtid-purged=OFF --lock-tables=false)`.
- Loop over `$SCHEMA_ONLY_TABLES`; for each, first `[[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || { echo "bad table name: $t" >&2; exit 1; }`, then `n=$("${src[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = '$t'")`, and when `n` is `1` append the name to `schema_only=()` and `--ignore-table=$DB_NAME.$t` to `ignore=()`.
- Branch on `[ "${#schema_only[@]}" -gt 0 ]` (safe under `set -u` in every bash, including 3.2 on macOS) for both the log line and the second dump: inside it print `schema only: ${schema_only[*]}`, else print `schema only: none`. Do not expand `${schema_only[*]}` outside that branch.

Then the dump, replacing lines 26 to 28: `mysqldump "${src[@]:1}" "${dump_opts[@]}" "${ignore[@]}" "$DB_NAME" > "$work/raw.sql"` (write the host/port/user/password flags out explicitly rather than slicing `src`, if that reads better), followed by, only when `schema_only` is non-empty, `mysqldump <same flags> "${dump_opts[@]}" --no-data "$DB_NAME" "${schema_only[@]}" >> "$work/raw.sql"`.

Under `set -u`, expand `ignore` as `"${ignore[@]+"${ignore[@]}"}"` so an empty array does not abort on bash 3.2 (macOS). mysqldump facts the implementer can rely on (verified against mysql:8.0 with a SELECT-only user): `--ignore-table` takes `db.table` unquoted (a backticked name is silently not ignored) and exits 0 for a missing table; `--no-data db table` exits 6 for a missing table, which is why the existence query gates it; the appended `--no-data` output is a complete second dump (own header, `DROP TABLE IF EXISTS`, `CREATE TABLE`, footer) and the concatenation restores cleanly with `cache` empty.

Update the header comment (lines 5 to 6): `SCHEMA_ONLY_TABLES="cache"` (default) lists tables dumped without rows, so Craft's DbCache is never transferred or restored.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/snapshot-scrub.test.sh`
Expected: `7 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/snapshot.sh tests/snapshot-scrub.test.sh
git commit -m "Snapshot: dump SCHEMA_ONLY_TABLES (default cache) without rows"
```

### Task 2: document the behaviour

**Files:**
- Modify: `README.md:162-174` ("Snapshot job", first two paragraphs)
- Modify: `scripts/scrub.sql:31-32` (cache comment)

**Interfaces:**
- Consumes: the `SCHEMA_ONLY_TABLES` name and `schema only:` log line from Task 1.

- [ ] **Step 1: README**

After the first paragraph of "Snapshot job" add one paragraph: the production dump leaves out the rows of the tables in `SCHEMA_ONLY_TABLES` (default `cache`, Craft's DbCache, which on nfi was 2.4 GB of a 3 GB dump and made the restore exceed the 30-minute job timeout); their `CREATE TABLE` is still dumped, so the snapshot imports cleanly and Craft rebuilds the cache on demand. Craft Cloud sites use DbCache unless Valkey is enabled; a Forge or Servebolt site on file or Redis cache has no `cache` table and gets the plain dump, as does a site with a table prefix (like the rest of the scrub) or a dump user without `SELECT` on the table, which the existence query then reports as absent. The variable is set in `scripts/snapshot.sh`, not a workflow input. The log shows `schema only: cache` or `schema only: none`.

- [ ] **Step 2: `scrub.sql` comment**

Change lines 31 to 32 to say the table is normally already empty, because `snapshot.sh` dumps it schema-only, and that the `DELETE` stays as a guard.

- [ ] **Step 3: Confirm nothing else references the old wording**

Run: `grep -rn "2.4 GB" README.md scripts docs/superpowers/specs | grep -v plans`
Expected: only the README paragraph and the `scrub.sql` comment from this task.

- [ ] **Step 4: Commit**

```bash
git add README.md scripts/scrub.sql
git commit -m "Docs: schema-only cache table in the snapshot"
```

### Task 3 (Svale): release and confirm on nfi

**Files:** none in this repo beyond the tag.

- [ ] **Step 1: Push `main` and move `v1`** (after reviewing the two commits)

```bash
git push origin main && git tag -f v1 && git push -f origin v1
```

- [ ] **Step 2: Dispatch the nfi snapshot**

```bash
gh workflow run snapshot.yml --repo Feedsystem/nfi && sleep 30 && gh run watch --repo Feedsystem/nfi --exit-status
```

Expected: green in about 5 to 8 minutes (a 14-minute run is a signal, not a pass); the log shows `schema only: cache` and the `restoring into scratch mysql and scrubbing` phase takes under 2 minutes.

If the run still times out: the stall is in the production dump itself, not the restore. The dump has no client-side read timeout, so a dead connection hangs until the job timeout. Next step is then diagnosing the dump (compare with the backup's `backup.sh`, add a `net_read_timeout`-style guard), not more scrub work.

- [ ] **Step 3: Confirm the uploaded snapshot has the cache schema and no cache rows**

With the `SNAPSHOT_READ_*` credentials (from 1Password, piped, not pasted):

```bash
aws s3 cp s3://netlife-craft-snapshots/snapshots/nfi/latest.sql.gz - --endpoint-url https://fra1.digitaloceanspaces.com \
  | gunzip | grep -cE '^(CREATE TABLE|INSERT INTO) `cache`'
```

Expected: `1` (the `CREATE TABLE` line only).

- [ ] **Step 4: Confirm a verify still imports it**

Re-run the latest verify on nfi `main` (or wait for the next PR). Expected: green, no `cache` error in the import step.

- [ ] **Step 5: Record**

Pilot log row in the Obsidian fleet note; tick the ClickUp item; memory `renovate-pilot-state` gets the outcome.

## Not in this plan

- Switching the whole-table `DELETE`s in `scrub.sql` to `TRUNCATE`: with the cache rows gone, the remaining emptied tables are small on every fleet site, and `TRUNCATE` fails on a table that another table references by foreign key, which `DELETE` does not. Revisit if a second large table shows up.
- Raising `timeout-minutes`: it would hide the next growth instead of surfacing it.
- A workflow input for `SCHEMA_ONLY_TABLES`: no site needs a different list today (fleet design principle: least per-site setup).
- A client-side timeout on the production dump (a stalled connection hangs until `timeout-minutes`): on record as the next suspect if Task 3's fallback triggers.
