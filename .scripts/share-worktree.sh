#!/usr/bin/env bash
set -euo pipefail

# Expose ONE worktree over the tailnet, on demand. Run from the worktree dir.
# Nothing persists: `off` puts it all back.
#
# Serves the rails and rustfs containers by their docker IPs — tailscaled runs
# on the host and routes to the bridge networks directly, so this needs no
# published ports. Traefik is bypassed, which sidesteps its Host-header rules
# and keeps every other worktree unreachable.
#
# The overrides go in a compose file, not .env.development: compose.yml already
# sets DOMAIN and RUSTFS_ENDPOINT as container env, and dotenv never overwrites
# an ENV var that is already set.

action="${1:-on}"
: "${COMPOSE_PROJECT_NAME:?run from a worktree directory (mise env not loaded)}"
: "${COMPOSE_FILE:?COMPOSE_FILE unset (mise env not loaded)}"
: "${WORKTREE_HOST:?WORKTREE_HOST unset (mise env not loaded)}"

override="${TMPDIR:-/tmp}/filial-share-${COMPOSE_PROJECT_NAME}.yml"

container_ip() {
  local cid
  cid=$(docker compose ps -q "$1")
  [ -n "$cid" ] || { echo "Error: $1 not running — mise run up first" >&2; exit 1; }
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" | awk '{print $1}'
}

case "$action" in
  on)
    ts_host=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    ts_ip=$(tailscale ip -4)
    [ -n "$ts_host" ] && [ "$ts_host" != "null" ] ||
      { echo "Error: tailscale not up (sudo systemctl start tailscaled)" >&2; exit 1; }

    # DOMAIN drives default_url_options + config.hosts; DEV_HOSTS keeps the
    # desktop's http://<slug>.localhost working while shared. extra_hosts lets
    # rails reach its own signing endpoint server-side.
    cat > "$override" <<EOF
services:
  rails:
    environment:
      DOMAIN: $ts_host
      DEV_HOSTS: $WORKTREE_HOST
      RUSTFS_ENDPOINT: https://$ts_host:8443
    extra_hosts:
      - "$ts_host:$ts_ip"
EOF

    # Recreate before serving: a new container gets a new IP.
    COMPOSE_FILE="$COMPOSE_FILE:$override" docker compose up -d rails

    tailscale serve --bg --https=443  "http://$(container_ip rails):3000"
    tailscale serve --bg --https=8443 "http://$(container_ip rustfs):9000"

    echo "Shared: https://$ts_host  (S3 on :8443)"
    ;;
  off)
    tailscale serve reset
    rm -f "$override"
    docker compose up -d rails
    echo "Unshared."
    ;;
  *)
    echo "Usage: $0 [on|off]" >&2
    exit 1
    ;;
esac
