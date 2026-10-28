#!/usr/bin/env bash
# Compare (or with --write, fix) a site checkout's fleet files: .netlife/fleet.json and the workflow callers.
# Usage: onboard-files.sh <checkout-dir> [--host forge|servebolt|cloud] [--slug S] [--develop B|none] [--write]
# Prints one line per check: "ok|diff|todo <check>: <detail>", then a last line "host=<host> backup=<yes|no>".
# Exit 0: nothing to do. Exit 1: some check is diff or todo. Exit 2: usage error or host not determinable.
# --write fixes the diffs this script owns (files), never commits, and reports them as "ok ... (written)".
# The manifest is only created when absent, never rewritten. GITHUB_REPOSITORY names the repo for the default slug.
set -euo pipefail

SCHEMA_URL="https://raw.githubusercontent.com/netliferesearch/craft-ci/v1/fleet.schema.json"
EXAMPLES="$(cd "$(dirname "$0")/../examples" && pwd)"
MANIFEST_SH="$(cd "$(dirname "$0")" && pwd)/manifest.sh"

usage() { echo "usage: onboard-files.sh <checkout-dir> [--host forge|servebolt|cloud] [--slug S] [--develop B|none] [--write]" >&2; exit 2; }

dir="" host="" slug="" develop="" write=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || usage; host="$2"; shift 2 ;;
    --slug) [ $# -ge 2 ] || usage; slug="$2"; shift 2 ;;
    --develop) [ $# -ge 2 ] || usage; develop="$2"; shift 2 ;;
    --write) write=1; shift ;;
    -*) usage ;;
    *) [ -z "$dir" ] || usage; dir="$1"; shift ;;
  esac
done
[ -n "$dir" ] && [ -d "$dir" ] || usage
case "$host" in ""|forge|servebolt|cloud) ;; *) echo "onboard-files: --host must be forge, servebolt or cloud" >&2; exit 2 ;; esac
cd "$dir"

if [ -z "$host" ]; then
  if [ -f craft-cloud.yaml ]; then
    host=cloud
  else
    echo "onboard-files: cannot tell the host (no craft-cloud.yaml); pass --host forge|servebolt|cloud" >&2
    exit 2
  fi
fi
backup=no
[ -f .github/workflows/backup-database.yml ] && backup=yes

status=0
report() { # state name detail
  echo "$1 $2: $3"
  if [ "$1" != ok ]; then status=1; fi
}

# Callers: byte-compare with the example, copy it over with --write.
check_caller() { # name example-file
  local name="$1" example="$EXAMPLES/$2" target=".github/workflows/$1.yml"
  if [ -f "$target" ] && cmp -s "$example" "$target"; then
    report ok "caller $name" "matches examples/$2"
  elif [ "$write" = 1 ]; then
    mkdir -p .github/workflows && cp "$example" "$target"
    report ok "caller $name" "matches examples/$2 (written)"
  elif [ -f "$target" ]; then
    report diff "caller $name" "differs from examples/$2"
  else
    report diff "caller $name" "missing, expected examples/$2"
  fi
}

# Manifest
repo_slug() {
  local repo="${GITHUB_REPOSITORY:-}"
  printf '%s' "${repo#*/}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-12
}
mpath=.netlife/fleet.json
if [ -f "$mpath" ]; then
  err_file="$(mktemp)"
  code=0
  out="$(bash "$MANIFEST_SH" "$mpath" 2>"$err_file")" || code=$?
  if [ "$code" -ne 0 ]; then
    report diff manifest "manifest.sh exited $code: $(tr '\n' ' ' < "$err_file")"
  else
    got_slug="$(printf '%s\n' "$out" | grep '^SLUG=' | cut -d= -f2-)"
    got_develop="$(printf '%s\n' "$out" | grep '^BRANCH_DEVELOP=' | cut -d= -f2-)"
    want_develop="$develop"; [ "$develop" = none ] && want_develop=""
    problems=""
    if [ -n "$slug" ] && [ "$slug" != "$got_slug" ]; then problems="slug is '$got_slug', expected '$slug'"; fi
    if [ -n "$develop" ] && [ "$want_develop" != "$got_develop" ]; then
      problems="${problems:+$problems; }develop is '${got_develop:-none}', expected '$develop'"
    fi
    if [ -n "$problems" ]; then report diff manifest "$problems"; else report ok manifest "valid (slug $got_slug)"; fi
  fi
  rm -f "$err_file"
elif [ "$write" = 1 ]; then
  mkdir -p .netlife
  jq -n --arg schema "$SCHEMA_URL" --arg slug "$slug" --arg default "$(repo_slug)" --arg develop "$develop" '
    {"$schema": $schema}
    + (if $slug != "" and $slug != $default then {slug: $slug} else {} end)
    + (if $develop == "none" then {branches: {develop: null}} else {} end)' > "$mpath"
  report ok manifest "created $mpath (written)"
else
  report diff manifest "$mpath is missing"
fi

# Callers
if [ "$host" = cloud ]; then verify_example=verify-cloud.yml; else verify_example=verify.yml; fi
if [ "$host" = cloud ] && [ "$backup" = yes ]; then snapshot_example=snapshot-cloud-backup.yml; else snapshot_example=snapshot.yml; fi
check_caller verify "$verify_example"
check_caller snapshot "$snapshot_example"
check_caller backmerge backmerge.yml

# ddev database must be MySQL 8.0 (todo, never written)
if [ ! -f .ddev/config.yaml ]; then
  report todo "ddev database" "no .ddev/config.yaml; set up ddev with database type mysql, version 8.0"
else
  db="$(awk '
    /^database:/ { in_db = 1; next }
    in_db && /^[^ \t#]/ { in_db = 0 }
    in_db && /^[ \t]+type:/ { t = $2; gsub(/["\047]/, "", t) }
    in_db && /^[ \t]+version:/ { v = $2; gsub(/["\047]/, "", v) }
    END { print t " " v }' .ddev/config.yaml)"
  if [ "$db" = "mysql 8.0" ]; then
    report ok "ddev database" "mysql 8.0"
  else
    report todo "ddev database" "database is '${db# }', expected type: mysql and version: \"8.0\" in .ddev/config.yaml"
  fi
fi

# scrub
if [ -f .netlife/scrub.sql ]; then
  report ok scrub ".netlife/scrub.sql present"
else
  report todo scrub "write and review .netlife/scrub.sql before merging (blocks the snapshot)"
fi

# legacy preview config
if [ -f .craft-preview.json ]; then
  if [ "$write" = 1 ]; then
    rm -f .craft-preview.json
    report ok "legacy preview config" ".craft-preview.json removed (written)"
  else
    report diff "legacy preview config" ".craft-preview.json is obsolete, delete it"
  fi
else
  report ok "legacy preview config" "none"
fi

echo "host=$host backup=$backup"
exit "$status"
