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
# Expects the compose project context of the current worktree (run from a
# worktree directory).
set -euo pipefail

for ctr in $(docker compose ps -aq 2>/dev/null); do
  stale=""
  while IFS='=' read -r net pinned_id; do
    [ -n "$net" ] || continue
    current_id=$(docker network inspect "$net" --format '{{.Id}}' 2>/dev/null) || current_id=""
    if [ "$current_id" != "$pinned_id" ]; then
      stale="$net"
      break
    fi
  done < <(docker inspect "$ctr" \
    --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{$name}}={{$cfg.NetworkID}}{{"\n"}}{{end}}' \
    2>/dev/null)

  if [ -n "$stale" ]; then
    name=$(docker inspect "$ctr" --format '{{.Name}}' | cut -c2-)
    echo "Recreating ${name} — stale reference to network ${stale}"
    docker rm -f "$ctr" >/dev/null
  fi
done
