#!/usr/bin/env bash
# Dump the production database through a read-only user, scrub a copy, upload snapshots/<slug>/latest.sql.gz.
# Needs: SLUG, DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, DO_SPACES_BUCKET, DO_SPACES_REGION,
#        AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, a local MySQL on 127.0.0.1:3307 (root, no password)
# Optional: DB_PORT (3306), SSH_HOST/SSH_USER/SSH_KEY to tunnel, SCRUB_TRUNCATE="formie_submissions other_table",
#           EXTRA_SCRUB_SQL=path to a per-site scrub file, applied after scrub.sql when the file exists,
#           SCHEMA_ONLY_TABLES="cache" (default): tables dumped without rows, so Craft's DbCache is never
#           transferred or restored (on nfi it was 2.4 GB of a 3 GB dump and pushed the job past its timeout)
set -euo pipefail

: "${SLUG:?}" "${DB_HOST:?}" "${DB_NAME:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"
: "${DO_SPACES_BUCKET:?}" "${DO_SPACES_REGION:?}"
DB_PORT="${DB_PORT:-3306}"
SCRATCH_PORT="${SCRATCH_PORT:-3307}"
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${tunnel_pid:-}" ] && kill "$tunnel_pid" 2>/dev/null || true' EXIT

host="$DB_HOST"; port="$DB_PORT"
if [ -n "${SSH_HOST:-}" ]; then
  keyfile="$work/key"; printf '%s\n' "$SSH_KEY" > "$keyfile"; chmod 600 "$keyfile"
  ssh -i "$keyfile" -o StrictHostKeyChecking=accept-new -N -L "3309:$DB_HOST:$DB_PORT" "$SSH_USER@$SSH_HOST" &
  tunnel_pid=$!
  sleep 3
  host=127.0.0.1; port=3309
fi

conn=(--host="$host" --port="$port" --protocol=TCP --user="$DB_USER" --password="$DB_PASSWORD")
dump_opts=(--single-transaction --quick --no-tablespaces --skip-triggers --set-gtid-purged=OFF --lock-tables=false)

# Tables whose rows never leave the source: their CREATE TABLE is dumped in a second pass so the
# snapshot still imports cleanly. A listed table that does not exist (no DbCache, a table prefix) is skipped.
SCHEMA_ONLY_TABLES="${SCHEMA_ONLY_TABLES-cache}"
schema_only=(); ignore=()
for t in ${SCHEMA_ONLY_TABLES}; do
  [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || { echo "bad table name: $t" >&2; exit 1; }
  n=$(mysql "${conn[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = '$t'")
  if [ "$n" = 1 ]; then schema_only+=("$t"); ignore+=("--ignore-table=$DB_NAME.$t"); fi
done
if [ "${#schema_only[@]}" -gt 0 ]; then echo "schema only: ${schema_only[*]}"; else echo "schema only: none"; fi

echo "dumping $DB_NAME from $DB_HOST"
mysqldump "${conn[@]}" "${dump_opts[@]}" "${ignore[@]+"${ignore[@]}"}" "$DB_NAME" > "$work/raw.sql"
if [ "${#schema_only[@]}" -gt 0 ]; then
  mysqldump "${conn[@]}" "${dump_opts[@]}" --no-data "$DB_NAME" "${schema_only[@]}" >> "$work/raw.sql"
fi

echo "restoring into scratch mysql and scrubbing"
scratch=(mysql --host=127.0.0.1 --port="$SCRATCH_PORT" --protocol=TCP --user=root)
"${scratch[@]}" -e "DROP DATABASE IF EXISTS scrub; CREATE DATABASE scrub CHARACTER SET utf8mb4;"
"${scratch[@]}" scrub < "$work/raw.sql"
"${scratch[@]}" scrub < "$(dirname "$0")/scrub.sql"
if [ -n "${EXTRA_SCRUB_SQL:-}" ] && [ -f "$EXTRA_SCRUB_SQL" ]; then
  "${scratch[@]}" scrub < "$EXTRA_SCRUB_SQL"
  echo "extra scrub applied: $EXTRA_SCRUB_SQL"
fi
for t in ${SCRUB_TRUNCATE:-}; do
  "${scratch[@]}" scrub -e "DELETE FROM \`$t\`;" && echo "emptied $t"
done

mysqldump --host=127.0.0.1 --port="$SCRATCH_PORT" --protocol=TCP --user=root \
  --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF scrub | gzip > "$work/latest.sql.gz"

echo "uploading"
aws s3 cp "$work/latest.sql.gz" "s3://$DO_SPACES_BUCKET/snapshots/$SLUG/latest.sql.gz" \
  --endpoint-url "https://$DO_SPACES_REGION.digitaloceanspaces.com"
aws s3 cp "$work/latest.sql.gz" "s3://$DO_SPACES_BUCKET/history/$SLUG/$(date -u +%Y-%m-%d).sql.gz" \
  --endpoint-url "https://$DO_SPACES_REGION.digitaloceanspaces.com"
echo "done: snapshots/$SLUG/latest.sql.gz"
