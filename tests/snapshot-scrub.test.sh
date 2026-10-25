#!/usr/bin/env bash
# Tests for the EXTRA_SCRUB_SQL hook in scripts/snapshot.sh, with mysqldump/mysql/gzip/aws shimmed on PATH
# so the script runs end to end without a database or network. The mysql shim logs each call's args and stdin.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/scripts/snapshot.sh"

make_shims() {
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/mysql" <<'S'
#!/usr/bin/env bash
{ echo "CALL $*"; [ -t 0 ] || cat; } >> "$SHIM_LOG"
S
  printf '#!/usr/bin/env bash\necho "-- dump"\n' > "$T/bin/mysqldump"
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

run_tests
