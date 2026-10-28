#!/usr/bin/env bash
# Runs scripts/scrub.sql against a real MySQL 8.0 in docker: on a Craft 4-like database where the
# guarded tables do not exist, on one where they do, and on a Craft 4 address shape.
# SKIPS (and passes) when docker is unavailable or the container cannot start.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRUB="$ROOT/scripts/scrub.sql"
FIX="$ROOT/tests/fixtures"
NAME=craftci-scrub-$$
PORT="${SCRUB_TEST_PORT:-3311}"
STARTED=0

stop_container() { [ "$STARTED" = 1 ] && docker stop "$NAME" > /dev/null 2>&1; STARTED=0; }
trap stop_container EXIT

skip() { echo "SKIP: scrub-sql.test.sh: $1"; exit 0; }

command -v docker > /dev/null 2>&1 || skip "docker is not installed"
docker info > /dev/null 2>&1 || skip "docker daemon is not reachable"
docker run -d --rm --name "$NAME" -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -p "$PORT:3306" mysql:8.0 > /dev/null 2>&1 \
  || skip "cannot start mysql:8.0 (image pull or port $PORT failed)"
STARTED=1

ready=0
for _ in $(seq 1 90); do
  # A real query over TCP: the entrypoint's temporary server answers ping before the final one is up.
  if docker exec "$NAME" mysql --protocol=TCP -h127.0.0.1 -uroot -e 'SELECT 1' > /dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || { echo "SKIP: scrub-sql.test.sh: mysql did not become ready in time"; exit 0; }

sql() { docker exec -i "$NAME" mysql --protocol=TCP -h127.0.0.1 -uroot "$@"; }
q() { sql -N -B "$1" -e "$2"; }  # db query

fresh_db() { sql -e "DROP DATABASE IF EXISTS $1; CREATE DATABASE $1"; sql "$1" < "$FIX/scrub-base.sql"; }
# Without --force the client stops at the first error and exits non-zero, like snapshot.sh relies on.
run_scrub() { CODE=0; OUT="$(sql "$1" < "$SCRUB" 2>&1)" || CODE=$?; }

test_craft4_like_without_guarded_tables() {
  fresh_db c4
  run_scrub c4
  assert_eq 0 "$CODE" "scrub exit ($OUT)"
  assert_eq "user1@example.test|user1" "$(q c4 'SELECT CONCAT(email, "|", username) FROM users')" "user scrubbed"
  assert_eq 0 "$(q c4 'SELECT COUNT(*) FROM sessions')" "sessions emptied"
}

test_craft5_like_with_guarded_tables() {
  fresh_db c5
  sql c5 < "$FIX/scrub-extra.sql"
  run_scrub c5
  assert_eq 0 "$CODE" "scrub exit ($OUT)"
  local t
  for t in webauthn authenticator recoverycodes sso_identities elementactivity craftidtokens; do
    assert_eq 0 "$(q c5 "SELECT COUNT(*) FROM $t")" "$t emptied"
  done
  assert_eq "1|scrubbed-2" "$(q c5 "SELECT CONCAT(SUM(accessToken = '__PUBLIC__'), '|', MAX(IF(id = 2, accessToken, ''))) FROM gqltokens")" "gql tokens: public kept, other scrubbed"
  assert_eq 1 "$(q c5 'SELECT COUNT(*) FROM drafts WHERE notes IS NULL')" "draft notes cleared"
  assert_eq "50" "$(q c5 'SELECT GROUP_CONCAT(elementId) FROM searchindex')" "user search rows deleted, entry rows kept"
  assert_eq "NULL|NULL|NULL|NULL|NULL|NULL|NO" "$(q c5 'SELECT CONCAT_WS("|", IFNULL(fullName,"NULL"), IFNULL(addressLine1,"NULL"), IFNULL(postalCode,"NULL"), IFNULL(locality,"NULL"), IFNULL(latitude,"NULL"), IFNULL(longitude,"NULL"), countryCode) FROM addresses WHERE id = 10')" "user address scrubbed"
  assert_eq "Office|Street 2|0151" "$(q c5 'SELECT CONCAT_WS("|", fullName, addressLine1, postalCode) FROM addresses WHERE id = 11')" "entry address kept"
}

test_scrub_is_idempotent() {
  fresh_db c5b
  sql c5b < "$FIX/scrub-extra.sql"
  run_scrub c5b
  assert_eq 0 "$CODE" "first run exit ($OUT)"
  run_scrub c5b
  assert_eq 0 "$CODE" "second run exit ($OUT)"
}

test_craft4_address_owner_column() {
  fresh_db c4a
  sql c4a < "$FIX/scrub-extra-craft4-address.sql"
  run_scrub c4a
  assert_eq 0 "$CODE" "scrub exit ($OUT)"
  assert_eq "NULL|NULL|NULL" "$(q c4a 'SELECT CONCAT_WS("|", IFNULL(firstName,"NULL"), IFNULL(lastName,"NULL"), IFNULL(addressLine1,"NULL")) FROM addresses WHERE id = 10')" "user-owned address scrubbed via ownerId"
  assert_eq "Office|Co|Street 2" "$(q c4a 'SELECT CONCAT_WS("|", firstName, lastName, addressLine1) FROM addresses WHERE id = 11')" "entry-owned address kept"
}

run_tests
code=$?
stop_container
exit $code
