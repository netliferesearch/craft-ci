#!/usr/bin/env bash
# Dump a staging database, scrub a copy, upload snapshots/<slug>/latest.sql.gz.
# Needs: SLUG, DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, DO_SPACES_BUCKET, DO_SPACES_REGION,
#        AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, a local MySQL on 127.0.0.1:3307 (root, no password)
# Optional: DB_PORT (3306), SSH_HOST/SSH_USER/SSH_KEY to tunnel, SCRUB_TRUNCATE="formie_submissions other_table"
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

echo "dumping $DB_NAME from $DB_HOST"
mysqldump --host="$host" --port="$port" --protocol=TCP --user="$DB_USER" --password="$DB_PASSWORD" \
  --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF --lock-tables=false \
  "$DB_NAME" > "$work/raw.sql"

echo "restoring into scratch mysql and scrubbing"
scratch=(mysql --host=127.0.0.1 --port="$SCRATCH_PORT" --protocol=TCP --user=root)
"${scratch[@]}" -e "DROP DATABASE IF EXISTS scrub; CREATE DATABASE scrub CHARACTER SET utf8mb4;"
"${scratch[@]}" scrub < "$work/raw.sql"
"${scratch[@]}" scrub < "$(dirname "$0")/scrub.sql"
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
