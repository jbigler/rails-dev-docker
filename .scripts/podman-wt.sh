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
# Never $PWD: mise runs tasks from config_root, so $PWD is the wrapper root
# whichever worktree you invoke from. The units use <root>/<worktree> paths,
# so everything here must agree with that.
WT_DIR="$ROOT/$W"

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
  [[ -f "$WT_DIR/.units.env" ]] || {
    printf 'no .units.env in this worktree; generating it...\n'
    "$ROOT/.scripts/units-env.sh"
  }
}

# systemd reports only "A dependency job for X failed" and does not name the
# dependency. `systemctl --user --failed` often shows nothing either, because a
# oneshot that failed during a cancelled job does not stay in failed state. So
# walk the units this worktree owns and report each one's real state, plus the
# journal tail for whichever actually failed.
diagnose_failure() {
  local svc u state result
  printf '\nstart failed. State of this worktree'\''s units:\n\n' >&2
  # Workspace-scoped units first. rails@ Requires= the proxy network (implied by
  # Network=<prefix>-proxy.network) and Wants= traefik, so a failure there
  # cancels the rails job while every per-worktree unit still looks fine --
  # which is exactly the blind spot an earlier version of this had.
  for u in "${PROJECT_PREFIX}-proxy-network.service" "${PROJECT_PREFIX}-traefik.service"; do
    state="$(systemctl --user show -p ActiveState --value "$u" 2>/dev/null)"
    result="$(systemctl --user show -p Result --value "$u" 2>/dev/null)"
    case "$state" in
      active)     printf '  ok      %-22s active\n' "${u%.service}" >&2 ;;
      "")         printf '  MISSING %-22s no such unit\n' "${u%.service}" >&2 ;;
      *)          printf '  FAILED  %-22s %s (result=%s)\n' "${u%.service}" "$state" "${result:-?}" >&2 ;;
    esac
  done
  printf '\n' >&2
  for svc in net-network db redis rustfs-init rustfs playwright rails; do
    u="$(unit "$svc")"
    state="$(systemctl --user show -p ActiveState --value "$u" 2>/dev/null)"
    result="$(systemctl --user show -p Result --value "$u" 2>/dev/null)"
    case "$state" in
      active)     printf '  ok      %-14s active\n' "$svc" >&2 ;;
      activating) printf '  ...     %-14s activating\n' "$svc" >&2 ;;
      "")         printf '  MISSING %-14s no such unit -- run: mise run podman:install\n' "$svc" >&2 ;;
      *)          printf '  FAILED  %-14s %s (result=%s)\n' "$svc" "$state" "${result:-?}" >&2 ;;
    esac
  done
  printf '\n' >&2
  # Include activating: a unit stuck there is usually the cause (a healthcheck
  # that never passes, or podman trying to pull an image that was never built),
  # and its journal says which.
  for u in "${PROJECT_PREFIX}-proxy-network.service" \
           "$(unit net-network)" "$(unit db)" "$(unit redis)" \
           "$(unit rustfs-init)" "$(unit rustfs)" "$(unit playwright)"; do
    state="$(systemctl --user show -p ActiveState --value "$u" 2>/dev/null)"
    [[ "$state" == "failed" || "$state" == "activating" ]] || continue
    printf '=== journal: %s ===\n' "$u" >&2
    journalctl --user -u "$u" -n 15 --no-pager 2>/dev/null \
      | grep -vE '^-- (Boot|No entries)' | sed 's/^/  /' >&2
    printf '\n' >&2
  done
  # Missing images are the most common cause and produce no obvious error --
  # podman tries to pull localhost/... which cannot succeed, so the unit sits
  # in activating until it times out.
  if [[ -f "$WT_DIR/.units.env" ]]; then
    ( set -a; . "$WT_DIR/.units.env"; set +a
      printf 'Images the units reference:\n' >&2
      for img in "$RAILS_IMAGE" "$NVIM_IMAGE" "$CLAUDE_IMAGE" "$PLAYWRIGHT_IMAGE"; do
        if podman image exists "$img" 2>/dev/null; then
          printf '  ok      %s\n' "$img" >&2
        else
          printf '  MISSING %s  <- mise run podman:build\n' "$img" >&2
        fi
      done
      printf '\n' >&2 )
  fi

  printf 'Common causes, in order of likelihood:\n' >&2
  printf '  1. images not built yet          -> mise run podman:build\n' >&2
  printf '  2. templates not installed       -> mise run podman:install\n' >&2
  printf '  3. host prerequisites            -> mise run podman:doctor\n' >&2
}

cmd_up() {
  require_units; require_env
  # One unit; systemd pulls the network, data services and proxy in through
  # Requires=/Wants=, and gates rails on db/redis/rustfs being *healthy*.
  printf 'starting %s (dependencies resolve automatically)...\n' "$(unit rails)"
  systemctl --user start "$(unit rails)" || { diagnose_failure; exit 1; }
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

# mise's own `confirm` renders a nicer prompt, but it preselects Yes and takes a
# bare Enter as acceptance -- the wrong default for the one verb that deletes a
# database. So the prompt lives here. gum, if installed, gives the same widget
# with an explicit --default=no; otherwise fall back to a plain read, which is
# always available. Either way Enter means keep the data.
confirm_destructive() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=no --affirmative="Delete" --negative="Keep" "$prompt"
    return
  fi
  local reply=""
  read -r -p "$prompt [y/N] " reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

cmd_down() {
  # Destructive, mirroring the docker `down` task, which removed volumes. The
  # confirmation lives here rather than only in the mise task because these
  # scripts get called directly too, which bypasses mise's confirm entirely.
  # Defaults to No: `down` is one keystroke from `stop`, and the difference
  # between them is this worktree's database.
  local vols=("$P-$W-db-data" "$P-$W-rustfs-data" "$P-$W-node-modules")
  local v present=()
  for v in "${vols[@]}"; do
    podman volume exists "$v" 2>/dev/null && present+=("$v")
  done

  if (( ${#present[@]} == 0 )); then
    printf 'No volumes to remove for worktree %s; stopping only.\n' "$W"
    cmd_stop
    return
  fi

  printf '\nThis will DELETE the following volumes for worktree %s:\n' "$W"
  printf '  %s\n' "${present[@]}"
  printf '\nThe database and any uploaded rustfs objects go with them.\n'
  printf 'If you meant to stop the containers and keep the data, use:\n'
  printf '    mise run podman:stop\n\n'

  if [[ "${FORCE:-}" == "1" ]]; then
    printf 'FORCE=1 set; proceeding without asking.\n'
  elif [[ -t 0 ]]; then
    confirm_destructive "Delete these volumes?" || {
      printf 'Aborted; nothing was removed. Containers left running.\n'; return; }
  else
    die "refusing to delete volumes without a terminal to confirm at.
  Re-run interactively, or set FORCE=1 if you are sure."
  fi

  cmd_stop
  printf '\nremoving this worktree'\''s volumes...\n'
  for v in "${present[@]}"; do
    podman volume rm "$v" >/dev/null && printf '  removed %s\n' "$v"
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
  set -a; . "$WT_DIR/.units.env"; set +a
  exec podman run --rm -it \
    --network "$P-$W-dev" \
    --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
    --label traefik.enable=false \
    --env-file "$ROOT/.docker-config/.env" --env-file "$WT_DIR/.units.env" \
    -v "$WT_DIR:/app:z" -v "$ROOT/.home/$W:/home/appuser:z" \
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
