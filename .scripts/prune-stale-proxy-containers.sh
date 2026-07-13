#!/usr/bin/env bash
# Remove this worktree's containers that reference a proxy network that no
# longer exists. Containers stopped across a proxy-network recreation (e.g.
# after a proxy compose config change) pin the old network ID and fail to
# start with "network <id> not found". Removing them lets `docker compose up`
# recreate them attached to the current network — data lives in volumes, so
# nothing is lost.
#
# Expects PROJECT_PREFIX in the environment (set via mise) and the compose
# project context of the current worktree (run from a worktree directory).
set -euo pipefail

proxy_net="${PROJECT_PREFIX:?PROJECT_PREFIX is not set}_proxy"

proxy_id=$(docker network inspect "$proxy_net" --format '{{.Id}}' 2>/dev/null) || exit 0

for ctr in $(docker compose ps -aq 2>/dev/null); do
  stale=$(docker inspect "$ctr" \
    --format "{{with index .NetworkSettings.Networks \"$proxy_net\"}}{{.NetworkID}}{{end}}" \
    2>/dev/null) || continue
  if [ -n "$stale" ] && [ "$stale" != "$proxy_id" ]; then
    name=$(docker inspect "$ctr" --format '{{.Name}}' | cut -c2-)
    echo "Recreating ${name} — stale proxy network reference"
    docker rm -f "$ctr" >/dev/null
  fi
done
