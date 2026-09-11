#!/usr/bin/env bash
# Dump this worktree's development database and its RustFS objects into
# .container-config/db-dumps/, which is exactly where the restore path reads from:
# db@'s initdb hook (restore-dump.sh) creates and restores <dbname>.dump on a
# first start against an empty data volume, and rustfs-init@ untars
# rustfs_data.tar.gz when /data/rustfs0 is absent. So a dump taken here is
# picked up automatically by the next `up` on an empty volume.
#
# Usage: podman-db-dump.sh [clear]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

: "${PROJECT_PREFIX:?run from a worktree directory (mise env not loaded)}"
: "${CURRENT_WORKTREE_NAME:?CURRENT_WORKTREE_NAME unset (mise env not loaded)}"
P="$PROJECT_PREFIX"
W="$CURRENT_WORKTREE_NAME"
DUMP_DIR="$ROOT/.container-config/db-dumps"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "clear" ]]; then
  # Deliberately explicit extensions rather than a glob of the directory: the
  # .gitkeep must survive, and restore-dump.sh treats every file it finds as a
  # database, so a stray file here would be restored as one.
  rm -f "$DUMP_DIR"/*.dump "$DUMP_DIR"/*.sql "$DUMP_DIR"/*.sql.gz "$DUMP_DIR"/rustfs_data.tar.gz
  printf 'Cleared the dump files from %s\n' "$DUMP_DIR"
  printf 'The next up on an empty db volume will run a full db:prepare instead.\n'
  exit 0
fi

: "${DEV_DB_NAME:?DEV_DB_NAME is empty -- .scripts/dev-db-name.sh could not parse it
  from config/database.yml (a dynamic ERB or ENV value does that). Set it in
  mise.local.toml.}"

mkdir -p "$DUMP_DIR"

db_ct="$P-$W-db"
podman container exists "$db_ct" \
  || die "$db_ct is not running. Start the stack first: mise run up"

# -Fc (custom format) is what restore-dump.sh expects for a .dump file, and it
# is what lets pg_restore run without the database existing yet.
printf 'Dumping %s from %s...\n' "$DEV_DB_NAME" "$db_ct"
podman exec "$db_ct" pg_dump -Fc -U postgres "$DEV_DB_NAME" > "$DUMP_DIR/$DEV_DB_NAME.dump"
printf '  wrote %s (%s)\n' "$DEV_DB_NAME.dump" "$(du -h "$DUMP_DIR/$DEV_DB_NAME.dump" | cut -f1)"

# The rustfs volume is read through a throwaway container because it is a named
# volume, not a path -- there is nothing on the host to tar directly. :ro on the
# data side, and :z on the bind so SELinux does not deny the write.
vol="$P-$W-rustfs-data"
if podman volume exists "$vol" 2>/dev/null; then
  printf 'Dumping RustFS objects from %s...\n' "$vol"
  podman run --rm \
    -v "$vol:/data:ro" \
    -v "$DUMP_DIR:/backup:z" \
    docker.io/library/alpine tar czf /backup/rustfs_data.tar.gz -C /data .
  printf '  wrote rustfs_data.tar.gz (%s)\n' "$(du -h "$DUMP_DIR/rustfs_data.tar.gz" | cut -f1)"
else
  printf 'no %s volume; skipping the RustFS dump\n' "$vol" >&2
fi

printf '\nDumps are in %s\n' "$DUMP_DIR"
printf 'They restore automatically on the next up against an empty db volume,\n'
printf 'which is what `mise run down` leaves behind.\n'
