#!/usr/bin/env bash
# Crawl a Craft site's sitemap and fail on bad responses or new Craft errors.
# Usage: crawl.sh <base-url> [limit]
set -euo pipefail

base="${1:?base url}"
base="${base%/}"
limit="${2:-40}"
fetch=(curl -k -s -L --max-time 60 -A "netlife-craft-ci")
probe=(curl -k -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 60 -A "netlife-craft-ci")

log_lines() { { cat storage/logs/web-*.log 2>/dev/null || true; }; }
log_marker() { log_lines | wc -l | tr -d ' '; }
locs() { grep -o '<loc>[^<]*</loc>' | sed -e 's/<loc>//' -e 's/<\/loc>//'; }

before="$(log_marker)"

# sitemap.xml, following one level of sitemap index (SEOmatic and Craft's own sitemaps use one)
index="$("${fetch[@]}" "$base/sitemap.xml" || true)"
if [[ "$index" == *'<sitemapindex'* ]]; then
  urls=""
  while IFS= read -r child; do
    [ -z "$child" ] && continue
    urls+="$("${fetch[@]}" "$child" | locs || true)"$'\n'
  done <<< "$(printf '%s' "$index" | locs)"
else
  urls="$(printf '%s' "$index" | locs || true)"
fi
urls="$(printf '%s\n' "$urls" | sed '/^$/d' | head -n "$limit" || true)"

if [ -z "$urls" ]; then
  echo "no sitemap.xml, crawling the front page only"
  urls="$base/"
fi

fail=0
printf '%-6s %-7s %s\n' code secs url
while IFS= read -r url; do
  [ -z "$url" ] && continue
  read -r code secs < <("${probe[@]}" "$url" || true)
  printf '%-6s %-7s %s\n' "$code" "$secs" "$url"
  case "$code" in
    2*|3*) ;;
    *)
      fail=1
      # In dev mode Craft's error page carries the exception; show its first lines.
      "${fetch[@]}" "$url" | sed -e 's/<[^>]*>/ /g' | grep -iE 'exception|error|undefined|not found' | head -n 3 | sed 's/^/      /' || true
      ;;
  esac
done <<< "$urls"

after="$(log_marker)"
if [ "$after" -gt "$before" ]; then
  new="$(log_lines | tail -n "+$((before + 1))" | grep -E '\[(error|critical)\]|\[(web|console)\.(ERROR|CRITICAL)\]' || true)"
  if [ -n "$new" ]; then
    echo "::error::Craft logged errors during the crawl"
    echo "$new" | head -n 50
    fail=1
  fi
fi

exit "$fail"
