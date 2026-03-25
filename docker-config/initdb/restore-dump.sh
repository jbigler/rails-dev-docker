#!/bin/bash
set -e

# Runs inside /docker-entrypoint-initdb.d/ during PostgreSQL first-start
# initialization (empty data volume only).
#
# For each dump file in /db-dumps/, creates a database named after the file
# (minus extension) and restores the dump into it.
#
# Supported formats:
#   <dbname>.dump    — pg_dump custom format (pg_restore)
#   <dbname>.sql     — plain SQL text (psql)
#   <dbname>.sql.gz  — gzip-compressed SQL (gunzip | psql)
#
# Example: placing filial_health_rails_core_development.dump in the dump
# directory creates and restores the filial_health_rails_core_development db.
#
# To create a dump:
#   pg_dump -Fc -U postgres filial_health_rails_core_development > db-dumps/filial_health_rails_core_development.dump

DUMP_DIR="/db-dumps"

if [ ! -d "$DUMP_DIR" ] || [ -z "$(ls -A "$DUMP_DIR" 2>/dev/null)" ]; then
  echo "restore-dump: No files in $DUMP_DIR — skipping restore."
  exit 0
fi

restored=0

for dump_file in "$DUMP_DIR"/*.dump "$DUMP_DIR"/*.sql.gz "$DUMP_DIR"/*.sql; do
  [ -f "$dump_file" ] || continue

  filename=$(basename "$dump_file")

  case "$filename" in
    *.dump)    db_name="${filename%.dump}" ;;
    *.sql.gz)  db_name="${filename%.sql.gz}" ;;
    *.sql)     db_name="${filename%.sql}" ;;
    *)         continue ;;
  esac

  echo "restore-dump: Creating database '$db_name'..."
  createdb "$db_name"

  case "$dump_file" in
    *.dump)
      echo "restore-dump: Restoring from custom format — $filename"
      pg_restore --no-owner --no-privileges --dbname="$db_name" "$dump_file" || \
        echo "restore-dump: pg_restore exited with code $? (non-zero is common for minor warnings)"
      ;;
    *.sql.gz)
      echo "restore-dump: Restoring from compressed SQL — $filename"
      gunzip -c "$dump_file" | psql --quiet --dbname="$db_name"
      ;;
    *.sql)
      echo "restore-dump: Restoring from SQL — $filename"
      psql --quiet --dbname="$db_name" < "$dump_file"
      ;;
  esac

  echo "restore-dump: '$db_name' restored successfully."
  restored=$((restored + 1))
done

if [ "$restored" -eq 0 ]; then
  echo "restore-dump: No matching dump files found in $DUMP_DIR."
else
  echo "restore-dump: Restored $restored database(s)."
fi
