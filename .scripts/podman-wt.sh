#!/usr/bin/env bash
# Worktree lifecycle under podman. Run from inside a worktree.
#
# The units are systemd templates instantiated by worktree slug, so every
# operation here is `systemctl --user <verb> <prefix>-<svc>@<slug>`. Starting
# rails pulls in the network, db, redis, rustfs and the proxy through its
# Requires=/Wants=, so `up` starts one unit and systemd resolves the rest.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

: "${PROJECT_PREFIX:?run from a worktree directory (mise env not loaded)}"
: "${CURRENT_WORKTREE_NAME:?CURRENT_WORKTREE_NAME unset (mise env not loaded)}"
P="$PROJECT_PREFIX"
W="$CURRENT_WORKTREE_NAME"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
unit() { printf '%s-%s@%s.service' "$P" "$1" "$W"; }

# Everything that belongs to this worktree, in start order. playwright and
# claude are deliberately absent: they are started on demand only.
CORE=(net-network db redis rustfs-init rustfs rails)
ALL=(rails rustfs rustfs-init redis db playwright claude net-network)

require_units() {
  systemctl --user cat "$(unit rails)" >/dev/null 2>&1 \
    || die "$(unit rails) does not exist. Install the units first:
    mise run podman:install"
}

require_env() {
  [[ -f "$PWD/.units.env" ]] || {
    printf 'no .units.env in this worktree; generating it...\n'
    "$ROOT/.scripts/units-env.sh"
  }
}

cmd_up() {
  require_units; require_env
  # One unit; systemd pulls the network, data services and proxy in through
  # Requires=/Wants=, and gates rails on db/redis/rustfs being *healthy*.
  printf 'starting %s (dependencies resolve automatically)...\n' "$(unit rails)"
  systemctl --user start "$(unit rails)" || {
    printf '\nstart failed. The dependency that failed is usually clearer than\n' >&2
    printf 'the rails failure itself:\n' >&2
    printf '  systemctl --user --failed | grep %s\n' "$W" >&2
    printf '  journalctl --user -u %s -n 40\n' "$(unit rails)" >&2
    exit 1
  }
  cmd_status
}

cmd_stop() {
  # Non-destructive, mirroring the docker `stop` task: leaves volumes alone.
  local svc
  for svc in "${ALL[@]}"; do
    systemctl --user stop "$(unit "$svc")" 2>/dev/null || true
  done
  printf 'stopped every %s unit for worktree %s\n' "$P" "$W"
}

cmd_down() {
  # Destructive, mirroring the docker `down` task, which removed volumes.
  cmd_stop
  printf '\nremoving this worktree'\''s volumes...\n'
  local v
  for v in "$P-$W-db-data" "$P-$W-rustfs-data" "$P-$W-node-modules"; do
    if podman volume exists "$v"; then
      podman volume rm "$v" >/dev/null && printf '  removed %s\n' "$v"
    fi
  done
  # The cross-worktree volumes (gems, npm caches, nvim share, playwright
  # browsers, claude plugins) are deliberately untouched: they are shared, and
  # removing them would slow down every other worktree.
  printf 'kept the shared volumes (gems, npm, nvim, playwright, claude plugins)\n'
}

cmd_restart() { require_units; systemctl --user restart "$(unit rails)"; cmd_status; }

cmd_status() {
  printf '\n'
  systemctl --user --no-pager --no-legend list-units "$P-*@$W.service" 2>/dev/null \
    | sed 's/^/  /' || true
  printf '\n'
  podman ps --filter "name=^$P-$W-" \
    --format 'table {{.Names}} {{.Status}} {{.Ports}}' 2>/dev/null || true
  printf '\n  app        http://%s\n' "${WORKTREE_HOST:-$W.localhost}"
  printf '  s3 / ui    http://%s  http://%s\n' "${S3_HOST:-s3.$W.localhost}" "${RUSTFS_UI_HOST:-s3-ui.$W.localhost}"
}

cmd_logs() {
  local svc="${1:-rails}"
  exec journalctl --user -f -u "$(unit "$svc")"
}

# Exec into the running rails container, or a throwaway one if the stack is
# down. The --label traefik.enable=false on the transient container matters:
# without it Traefik discovers a second backend for this worktree's router and
# load-balances into a container that is not serving, which shows up as
# intermittent 502s on a host that looks otherwise healthy.
cmd_exec() {
  local ct="$P-$W-rails"
  (( $# )) || set -- /bin/bash
  if [[ "$(podman inspect "$ct" --format '{{.State.Running}}' 2>/dev/null)" == "true" ]]; then
    exec podman exec -it "$ct" "$@"
  fi
  require_env
  printf 'rails is not running; using a transient container\n' >&2
  systemctl --user start "$(unit db)" "$(unit redis)" 2>/dev/null || true
  set -a; . "$PWD/.units.env"; set +a
  exec podman run --rm -it \
    --network "$P-$W-dev" \
    --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
    --label traefik.enable=false \
    --env-file "$ROOT/.docker-config/.env" --env-file "$PWD/.units.env" \
    -v "$PWD:/app:z" -v "$ROOT/.home/$W:/home/appuser:z" \
    -v "${GEM_VOLUME}:/usr/local/bundle" \
    -v "$P-$W-node-modules:/app/node_modules:U" \
    --entrypoint "" "$RAILS_IMAGE" "$@"
}

cmd_test_system() {
  require_units; require_env
  # Ensure playwright is up, but never stop it afterwards. A Claude instance
  # inside the claude container may be running system tests against the same
  # browser server, and it cannot restart one we tore out from under it -- it
  # has no access to the host's systemd. Idle cost is low anyway: ShmSize is a
  # tmpfs cap, not a reservation.
  systemctl --user start "$(unit playwright)"
  cmd_exec bin/rails test:system "$@"
}

case "${1:-}" in
  up)          shift; cmd_up ;;
  stop)        shift; cmd_stop ;;
  down)        shift; cmd_down ;;
  restart)     shift; cmd_restart ;;
  status)      shift; cmd_status ;;
  logs)        shift; cmd_logs "$@" ;;
  exec)        shift; cmd_exec "$@" ;;
  test:system) shift; cmd_test_system "$@" ;;
  *) die "usage: $(basename "$0") {up|stop|down|restart|status|logs [svc]|exec [cmd...]|test:system}" ;;
esac
