#!/usr/bin/env bash
# Tests for the EXTRA_SCRUB_SQL hook and SCHEMA_ONLY_TABLES in scripts/snapshot.sh, with mysqldump/mysql/gzip/aws shimmed on PATH
# so the script runs end to end without a database or network. The mysql shim logs each call's args and stdin.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/snapshot.sh"

make_shims() {
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/mysql" <<'S'
#!/usr/bin/env bash
if [[ "$*" == *information_schema* ]]; then echo "QUERY $*" >> "$SHIM_LOG"; echo "${SHIM_TABLE_EXISTS:-1}"; exit "${SHIM_QUERY_EXIT:-0}"; fi
{ echo "CALL $*"; [ -t 0 ] || cat; } >> "$SHIM_LOG"
S
  printf '#!/usr/bin/env bash\necho "DUMP $*" >> "$SHIM_LOG"; echo "-- dump $*"\n' > "$T/bin/mysqldump"
  printf '#!/usr/bin/env bash\ncat\n' > "$T/bin/gzip"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/aws"
  chmod +x "$T/bin"/*
  echo "DELETE FROM x;" > "$T/extra.sql"
}

run_script() { # extra env assignments...
  CODE=0
  env PATH="$T/bin:$PATH" SHIM_LOG="$T/log" SLUG=s DB_HOST=h DB_NAME=n DB_USER=u DB_PASSWORD=p \
    DO_SPACES_BUCKET=b DO_SPACES_REGION=r "$@" bash "$SCRIPT" > "$T/out" 2>&1 < /dev/null || CODE=$?
}

test_extra_scrub_applied_after_shared() {
  make_shims
  run_script EXTRA_SCRUB_SQL="$T/extra.sql"
  assert_eq 0 "$CODE" "exit code"
  local shared extra
  shared="$(grep -n 'UPDATE users' "$T/log" | head -1 | cut -d: -f1)"
  extra="$(grep -n 'DELETE FROM x;' "$T/log" | head -1 | cut -d: -f1)"
  [ -n "$shared" ] && [ -n "$extra" ] && [ "$shared" -lt "$extra" ]
  assert_eq 0 $? "shared scrub.sql fed before the extra file (lines '$shared' '$extra')"
  grep -q "extra scrub applied: $T/extra.sql" "$T/out"; assert_eq 0 $? "prints which extra file was applied"
}

test_extra_scrub_missing_ignored() {
  make_shims
  run_script EXTRA_SCRUB_SQL="$T/nope.sql"
  assert_eq 0 "$CODE" "exit code"
  grep -q 'DELETE FROM x;' "$T/log"; assert_eq 1 $? "nothing extra fed"
  grep -q 'extra scrub' "$T/out"; assert_eq 1 $? "no extra scrub line printed"
}

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

run_tests
