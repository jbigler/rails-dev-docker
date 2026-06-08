#!/usr/bin/env bash
# Print the development database name from a Rails config/database.yml.
#
# Postgres only — the only adapter this Docker tooling supports. Best-effort:
# prints nothing (exit 0) when the name can't be resolved statically (file
# missing, non-postgres adapter, or a dynamic ERB/ENV database value), so
# callers can fall back to a manual DEV_DB_NAME in mise.local.toml.
#
# Usage: dev-db-name.sh [path-to-database.yml]   (default: config/database.yml)
set -euo pipefail

yml="${1:-config/database.yml}"
[ -f "$yml" ] || exit 0

# Pull `database:` from the `development:` block. Stop at the next top-level
# (non-indented) key so we never read another environment's database name.
db="$(awk '
  /^[[:space:]]*development:/ { f = 1; next }
  f && /^[^[:space:]]/        { exit }
  f && /database:/ {
    sub(/.*database:[[:space:]]*/, "")
    gsub(/["'"'"' ]/, "")
    print
    exit
  }
' "$yml" 2>/dev/null || true)"

# Bail on an unresolved/dynamic value rather than emitting something wrong.
case "$db" in
  '' | *'<%'* | *'ENV'*) exit 0 ;;
esac

printf '%s\n' "$db"
