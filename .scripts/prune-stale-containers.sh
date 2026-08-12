#!/usr/bin/env bash
# Remove this worktree's containers that reference a docker network that no
# longer exists under the ID they pinned. A stopped container records the
# network *ID*, not its name, so it breaks two ways:
#
#   * the network is recreated with a new ID (e.g. a proxy compose change), or
#   * the network is pruned while unused — after `mise run stop` this worktree's
#     `<project>_dev` network has no running members, so a `docker network prune`
#     or `docker system prune` sweeps it up.
#
# Either way the container fails to start with "network <id> not found".
# Removing them lets `docker compose up` recreate them attached to the current
# networks — data lives in volumes, so nothing is lost.
#
# Also removes containers carrying another worktree's `/app` bind mount. Every
# worktree shares one compose file and separates itself purely through the
# environment, so a `docker compose` run that pairs this project's
# COMPOSE_PROJECT_NAME with another worktree's CURRENT_WORKTREE_NAME produces a
# container labelled for us but wired to their source tree and their published
# ports. It then fails to start with "port is already allocated" the moment the
# real owner of those ports is up — a message that begins "failed to set up
# container networking", which reads as a network fault but is not one.
#
# Expects the compose project context of the current worktree (run from a
# worktree directory).
set -euo pipefail

for ctr in $(docker compose ps -aq 2>/dev/null); do
  stale=""
  while IFS='=' read -r net pinned_id; do
    [ -n "$net" ] || continue
    current_id=$(docker network inspect "$net" --format '{{.Id}}' 2>/dev/null) || current_id=""
    if [ "$current_id" != "$pinned_id" ]; then
      stale="stale reference to network ${net}"
      break
    fi
  done < <(docker inspect "$ctr" \
    --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{$name}}={{$cfg.NetworkID}}{{"\n"}}{{end}}' \
    2>/dev/null)

  # The app source is mounted at /app (rails, nvim) or /app-<worktree> (claude);
  # its source directory is the worktree that container really belongs to. Nested
  # mounts under those paths (the node_modules volume) carry no such identity, so
  # they are skipped. Only checked when mise has exported the expected name.
  if [ -z "$stale" ] && [ -n "${CURRENT_WORKTREE_NAME:-}" ]; then
    while IFS='=' read -r dest src; do
      case "$dest" in
        /app) ;;
        /app-*/*) continue ;;
        /app-*) ;;
        *) continue ;;
      esac
      mounted=$(basename "$src")
      if [ "$mounted" != "$CURRENT_WORKTREE_NAME" ]; then
        stale="${dest} mounted from worktree ${mounted}"
        break
      fi
    done < <(docker inspect "$ctr" \
      --format '{{range .Mounts}}{{.Destination}}={{.Source}}{{"\n"}}{{end}}' \
      2>/dev/null)
  fi

  if [ -n "$stale" ]; then
    name=$(docker inspect "$ctr" --format '{{.Name}}' | cut -c2-)
    echo "Recreating ${name} — ${stale}"
    docker rm -f "$ctr" >/dev/null
  fi
done
