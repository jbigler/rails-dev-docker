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
# The env file lives in the wrapper, not the worktree: a worktree is a checkout
# of the app repo, and this file holds POSTGRES_PASSWORD.
WT_ENV="$ROOT/.units/$W.env"
WT_SHARE_ENV="$ROOT/.units/$W.share.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
unit() { printf '%s-%s@%s.service' "$P" "$1" "$W"; }

# Everything that belongs to this worktree, in start order. playwright and
# claude are deliberately absent: they are started on demand only.
CORE=(net-network db redis rustfs-init rustfs rails)
ALL=(rails rustfs rustfs-init redis db playwright claude net-network)

require_units() {
  systemctl --user cat "$(unit rails)" >/dev/null 2>&1 \
    || die "$(unit rails) does not exist. Install the units first:
    mise run units:install"
  # Refuse rather than warn. Starting units that no longer match the templates
  # burns a cycle and reports the *previous* failure, which reads as a fix that
  # did not work instead of a fix that was never installed -- twice now.
  "$ROOT/.scripts/quadlet.sh" check-stale >/dev/null \
    || die "the installed units are out of date; see above"
}

# The docker path calls this from six mise tasks; the podman path called it from
# none, which is why rails died on `statfs .../.home/master`. Idempotent, so it
# is cheap to run on every up.
require_home() {
  "$ROOT/.scripts/seed-home.sh" "$W"
}

# podman refuses to start a container whose bind-mount source is missing --
# "Error: statfs <path>: no such file or directory", exit 125 -- where the
# Docker daemon would have created it, as root, which is the very thing
# seed-home.sh exists to prevent. That difference is invisible until first boot,
# and podman reports one path per attempt, so check them all at once.
#
# Only the services `up` starts are checked. nvim@ mounts things (the kitty
# socket, /usr/bin/kitten) that are legitimately absent until you run it, and
# claude is a script rather than a unit, checking its own mounts as it goes.
missing_mount_sources() {
  ( set -a; . "$WT_ENV"; set +a
    local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" svc f line src
    for svc in db redis rustfs-init rustfs rails playwright; do
      f="$ROOT/.container-config/quadlet/$svc@.container"
      [[ -f "$f" ]] || continue
      while IFS= read -r line; do
        src="${line#Volume=}"; src="${src%%:*}"
        src="${src//@@ROOT@@/$ROOT}"; src="${src//@@P@@/$P}"
        src="${src//%i/$W}"; src="${src//%h/$HOME}"; src="${src//%t/$rt}"
        # ${VAR} is resolved by systemd at runtime, so resolve it here too.
        # eval only after asserting the path holds nothing but path characters
        # -- no spaces, no backticks, no $( -- since these are our own
        # templates and the alternative is hand-listing every variable.
        if [[ "$src" == *'${'* ]]; then
          # The class must include $ itself, or every ${VAR} path fails the
          # guard and is skipped -- silently passing the check it exists for.
          [[ "$src" =~ ^[A-Za-z0-9_./%'$''{''}'~:-]+$ ]] || {
            printf 'warn: not checking %s (unexpected characters)\n' "$src" >&2
            continue
          }
          eval "src=$src"
        fi
        [[ "$src" == /* ]] || continue   # a named volume, which podman creates
        [[ -e "$src" ]] || printf '%s\t%s\n' "$svc" "$src"
      done < <(grep '^Volume=' "$f")
    done )
}

require_mounts() {
  local out
  out="$(missing_mount_sources)"
  [[ -n "$out" ]] || return 0
  printf 'error: these bind-mount sources do not exist, and podman will not\n' >&2
  printf 'create them the way the Docker daemon did:\n\n' >&2
  printf '%s\n' "$out" | while IFS=$'\t' read -r svc src; do
    printf '  %-12s %s\n' "$svc" "$src" >&2
  done
  printf '\nEach one fails the unit with "statfs <path>: no such file or\n' >&2
  printf 'directory" and exit 125. Create them, or fix the value in\n' >&2
  printf '%s\n' "$WT_ENV" >&2
  exit 1
}

require_env() {
  [[ -f "$WT_ENV" ]] || {
    printf 'no env file for this worktree; generating it...\n'
    "$ROOT/.scripts/units-env.sh"
  }
  # rails@ loads the share overrides unconditionally, and podman's --env-file is
  # fatal on a missing path. A worktree set up before wt:share existed has the
  # file above but not this one, so create the empty form rather than letting
  # the unit fail on an upgrade.
  [[ -f "$WT_SHARE_ENV" ]] || \
    printf '# Written by wt:share. Empty means not shared.\n' > "$WT_SHARE_ENV"
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
      "")         printf '  MISSING %-14s no such unit -- run: mise run units:install\n' "$svc" >&2 ;;
      *)          printf '  FAILED  %-14s %s (result=%s)\n' "$svc" "$state" "${result:-?}" >&2 ;;
    esac
  done
  printf '\n' >&2
  # rails first, and always: it is the unit `up` asked for, so when every
  # dependency reports ok it is the only thing left -- and an earlier version
  # skipped it on the theory that systemd's own "see journalctl -xeu" covered
  # it, which left the one interesting journal unprinted.
  #
  # Include activating as well as failed: a unit stuck there is usually the
  # cause (a healthcheck that never passes, an image that was never built, or
  # Restart=on-failure cycling a container that dies on boot).
  #
  # Both halves are needed. Every unit sets LogDriver=k8s-file, so the
  # container's own stdout does NOT go to the journal: the journal carries
  # systemd's and podman's messages ("Error: ..." from `podman run`), while the
  # entrypoint's output -- the wait-for-postgres loop, a Puma backtrace -- is
  # only in `podman logs`. Printing one without the other hides half the
  # failures.
  local ct
  for svc in rails playwright rustfs rustfs-init redis db net-network; do
    u="$(unit "$svc")"
    state="$(systemctl --user show -p ActiveState --value "$u" 2>/dev/null)"
    [[ "$svc" == rails || "$state" == "failed" || "$state" == "activating" ]] || continue
    printf '=== journal: %s (%s) ===\n' "$u" "${state:-no such unit}" >&2
    journalctl --user -u "$u" -n 20 --no-pager 2>/dev/null \
      | grep -vE '^-- (Boot|No entries)' | sed 's/^/  /' >&2
    ct="$P-$W-$svc"
    if [[ "$svc" != net-network ]] && podman container exists "$ct" 2>/dev/null; then
      printf '  --- podman logs %s (container stdout; k8s-file, not journald) ---\n' "$ct" >&2
      podman logs --tail 25 "$ct" 2>&1 | sed 's/^/  /' >&2
    fi
    printf '\n' >&2
  done
  # The proxy network is not a container and has no logs, so it stays separate.
  state="$(systemctl --user show -p ActiveState --value "${PROJECT_PREFIX}-proxy-network.service" 2>/dev/null)"
  if [[ "$state" == "failed" || "$state" == "activating" ]]; then
    printf '=== journal: %s-proxy-network.service (%s) ===\n' "$PROJECT_PREFIX" "$state" >&2
    journalctl --user -u "${PROJECT_PREFIX}-proxy-network.service" -n 15 --no-pager 2>/dev/null \
      | grep -vE '^-- (Boot|No entries)' | sed 's/^/  /' >&2
    printf '\n' >&2
  fi
  # Missing images are the most common cause and produce no obvious error --
  # podman tries to pull localhost/... which cannot succeed, so the unit sits
  # in activating until it times out.
  if [[ -f "$WT_ENV" ]]; then
    ( set -a; . "$WT_ENV"; set +a
      printf 'Images the units reference:\n' >&2
      for img in "$RAILS_IMAGE" "$NVIM_IMAGE" "$CLAUDE_IMAGE" "$PLAYWRIGHT_IMAGE"; do
        if podman image exists "$img" 2>/dev/null; then
          printf '  ok      %s\n' "$img" >&2
        else
          printf '  MISSING %s  <- mise run build\n' "$img" >&2
        fi
      done
      printf '\n' >&2 )
  fi

  printf 'Common causes, in order of likelihood:\n' >&2
  printf '  1. images not built yet          -> mise run build\n' >&2
  printf '  2. templates not installed       -> mise run units:install\n' >&2
  printf '  3. host prerequisites            -> mise run doctor\n' >&2
}

cmd_up() {
  require_units; require_env; require_home; require_mounts
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
  printf '    mise run stop\n\n'

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

# The third-party images only. rails/nvim/claude/playwright live under
# localhost/ -- built by `mise run build`, never pushed -- so pulling them
# cannot succeed, which is why compose needed --ignore-buildable here. Read the
# tags out of the templates rather than repeating them, so a version bump in a
# unit file cannot drift from what this pulls.
cmd_pull() {
  local img imgs=()
  local f
  for f in db redis rustfs rustfs-init; do
    img="$(sed -n 's/^Image=//p' "$ROOT/.container-config/quadlet/$f@.container" | head -1)"
    [[ -n "$img" && "$img" != localhost/* && "$img" != '${'* ]] || continue
    imgs+=("$img")
  done
  (( ${#imgs[@]} )) || die "found no third-party images in the templates"
  local failed=()
  for img in "${imgs[@]}"; do
    printf '\npulling %s\n' "$img"
    podman pull "$img" || failed+=("$img")
  done
  if (( ${#failed[@]} )); then
    printf '\nfailed to pull:\n' >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
  fi
  printf '\nAll third-party images up to date. Locally built images:\n'
  printf '  mise run build\n'
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
  local ct="$P-$W-rails" e extra=()
  (( $# )) || set -- /bin/bash
  # EXEC_ENV carries the per-task overrides compose passed with -e
  # (DISABLE_COVERAGE for the test watcher, DISABLE_LOGCRAFT for the console).
  for e in ${EXEC_ENV:-}; do extra+=(--env "$e"); done
  # EXEC_FRESH forces the transient container even when rails is up. The test
  # watchers and ci need it: compose used `run` for those deliberately, because
  # quitting a watcher attached to the rails container takes the server down
  # with it, and a ci run should not share a process space with the dev server.
  if [[ "${EXEC_FRESH:-}" != 1 ]] \
     && [[ "$(podman inspect "$ct" --format '{{.State.Running}}' 2>/dev/null)" == "true" ]]; then
    exec podman exec -it ${extra[@]+"${extra[@]}"} "$ct" "$@"
  fi
  require_env; require_home
  printf 'rails is not running; using a transient container\n' >&2
  systemctl --user start "$(unit db)" "$(unit redis)" 2>/dev/null || true
  set -a; . "$WT_ENV"; set +a
  # The npm and playwright volumes matter here, not just in rails@: `npx vitest`
  # resolves through .npm-global, and a system test run needs the browsers. A
  # compose `run` inherited the whole service definition and got them for free.
  exec podman run --rm -it ${extra[@]+"${extra[@]}"} \
    --network "$P-$W-dev" \
    --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
    --label traefik.enable=false \
    --env-file "$ROOT/.container-config/.env" --env-file "$WT_ENV" \
    -v "$WT_DIR:/app:z" -v "$ROOT/.home/$W:/home/appuser:z" \
    -v "${GEM_VOLUME}:/usr/local/bundle" \
    -v "$P-$W-node-modules:/app/node_modules:U" \
    -v "${P}_npm_cache:/home/appuser/.npm:U" \
    -v "${P}_npm_global:/home/appuser/.npm-global:U" \
    -v "${P}_playwright_browsers:/home/appuser/.cache/ms-playwright:U" \
    --entrypoint "" "$RAILS_IMAGE" "$@"
}

cmd_test_system() {
  require_units; require_env; require_home; require_mounts
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
  pull)        shift; cmd_pull ;;
  restart)     shift; cmd_restart ;;
  status)      shift; cmd_status ;;
  logs)        shift; cmd_logs "$@" ;;
  exec)        shift; cmd_exec "$@" ;;
  test:system) shift; cmd_test_system "$@" ;;
  *) die "usage: $(basename "$0") {up|stop|down|restart|pull|status|logs [svc]|exec [cmd...]|test:system}" ;;
esac
