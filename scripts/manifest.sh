#!/usr/bin/env bash
# Resolve .netlife/fleet.json (defaults applied) into KEY=value lines for workflows to source.
# Usage: manifest.sh [path]   (inside the site checkout, with origin set and GITHUB_REPOSITORY in the env)
# Prints: SLUG SNAPSHOT_SOURCE SNAPSHOT_KEY VERIFY_CRAWL_LIMIT VERIFY_IGNORE_LOG_PATTERN
#         VERIFY_ENVIRONMENT BRANCH_MAIN BRANCH_DEVELOP
# Exit 0: resolved. Exit 2: the manifest or the derived slug is invalid (reasons on stderr).
# Exit 3: jq is missing. Exit 4: the git ls-remote probe for develop failed (not just "no such branch").
# Env: MANIFEST_NO_REMOTE=1 skips the `git ls-remote` probe for a develop branch.
set -euo pipefail

path="${1:-.netlife/fleet.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "manifest: jq is required but not installed" >&2
  exit 3
fi

if [ -f "$path" ]; then
  manifest="$(cat "$path")"
else
  manifest='{}'
fi

if ! printf '%s' "$manifest" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "manifest: $path must contain a JSON object" >&2
  exit 2
fi

# Validation: key sets, slug pattern, enums and types. Prints one problem per line.
errors="$(printf '%s' "$manifest" | jq -r '
  def unknown($obj; $allowed; $where):
    ($obj | keys - $allowed)[] | "unknown key \"\($where)\(.)\" (allowed: \($allowed | join(", ")))";
  def block($name; $allowed):
    if has($name) then
      (if (.[$name] | type) != "object" then "\($name) must be an object"
       else unknown(.[$name]; $allowed; $name + ".") end)
    else empty end;
  unknown(.; ["$schema","slug","snapshot","verify","branches","preview"]; ""),
  block("snapshot"; ["source","key"]),
  block("verify"; ["crawlLimit","ignoreLogPattern","environment"]),
  block("branches"; ["main","develop"]),
  (if has("preview") and (.preview | type) != "object" then "preview must be an object" else empty end),
  (if has("slug") and ((.slug | type) != "string" or (.slug | test("^[a-z][a-z0-9]{1,11}$") | not))
     then "slug must match ^[a-z][a-z0-9]{1,11}$" else empty end),
  (if (.snapshot | type) == "object" and (.snapshot | has("source"))
      and ((.snapshot.source | type) != "string" or (.snapshot.source as $s | ["production","staging","none","forge-backup"] | index($s) == null))
     then "snapshot.source must be one of: production, staging, none, forge-backup" else empty end),
  (if (.snapshot | type) == "object" and (.snapshot | has("key"))
      and ((.snapshot.key | type) != "string" or (.snapshot.key | length) == 0)
     then "snapshot.key must be a non-empty string" else empty end),
  (if (.verify | type) == "object" and (.verify | has("crawlLimit"))
      and ((.verify.crawlLimit | type) != "number" or .verify.crawlLimit < 1 or (.verify.crawlLimit != (.verify.crawlLimit | floor)))
     then "verify.crawlLimit must be a positive integer" else empty end),
  (if (.verify | type) == "object" and (.verify | has("ignoreLogPattern")) and (.verify.ignoreLogPattern | type) != "string"
     then "verify.ignoreLogPattern must be a string" else empty end),
  (if (.verify | type) == "object" and (.verify | has("environment"))
      and ((.verify.environment | type) != "string" or (.verify.environment | length) == 0)
     then "verify.environment must be a non-empty string" else empty end),
  (if (.branches | type) == "object" and (.branches | has("main"))
      and ((.branches.main | type) != "string" or (.branches.main | length) == 0)
     then "branches.main must be a non-empty string" else empty end),
  (if (.branches | type) == "object" and (.branches | has("develop"))
      and (.branches.develop != null) and ((.branches.develop | type) != "string" or (.branches.develop | length) == 0)
     then "branches.develop must be a non-empty string or null" else empty end)
')"

if [ -n "$errors" ]; then
  echo "manifest: invalid $path:" >&2
  printf '  %s\n' "$errors" >&2
  exit 2
fi

get() { printf '%s' "$manifest" | jq -r "$1"; }

# slug: explicit, else derived from the repository name
slug="$(get '.slug // ""')"
if [ -z "$slug" ]; then
  repo="${GITHUB_REPOSITORY:-}"
  slug="$(printf '%s' "${repo#*/}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-12)"
  if ! printf '%s' "$slug" | grep -Eq '^[a-z][a-z0-9]{1,11}$'; then
    echo "manifest: cannot derive a slug from repository '${repo}' (got '${slug}'); set slug in $path (^[a-z][a-z0-9]{1,11}\$)" >&2
    exit 2
  fi
fi

source_="$(get '.snapshot.source // "production"')"
key="$(get '.snapshot.key // ""')"
[ -n "$key" ] || key="snapshots/$slug/latest.sql.gz"
crawl="$(get '.verify.crawlLimit // 40')"
ignore="$(get '.verify.ignoreLogPattern // ""')"
environment="$(get '.verify.environment // "staging"')"
main="$(get '.branches.main // "main"')"

# develop: explicit string wins, explicit null means none, absent means probe origin
if [ "$(get '(.branches // {}) | has("develop")')" = true ]; then
  develop="$(get '.branches.develop // ""')"
elif [ "${MANIFEST_NO_REMOTE:-}" = 1 ]; then
  develop=""
else
  probe=0
  probe_err="$(git ls-remote --exit-code --heads origin develop 2>&1 >/dev/null)" || probe=$?
  case "$probe" in
    0) develop="develop" ;;
    2) develop="" ;;
    *)
      echo "manifest: could not probe origin for a develop branch (git ls-remote exited $probe): $probe_err" >&2
      exit 4
      ;;
  esac
fi

printf 'SLUG=%s\nSNAPSHOT_SOURCE=%s\nSNAPSHOT_KEY=%s\nVERIFY_CRAWL_LIMIT=%s\nVERIFY_IGNORE_LOG_PATTERN=%s\nVERIFY_ENVIRONMENT=%s\nBRANCH_MAIN=%s\nBRANCH_DEVELOP=%s\n' \
  "$slug" "$source_" "$key" "$crawl" "$ignore" "$environment" "$main" "$develop"
