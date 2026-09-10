#!/usr/bin/env bash
# Render the Quadlet unit templates in .docker-config/quadlet/ into the user's
# systemd config dir, and check the rootless prerequisites.
#
# The templates carry @@TOKEN@@ placeholders because Quadlet does no variable
# expansion of its own: PROJECT_PREFIX and absolute paths have to be baked in at
# install time, the same way .mise/local.toml.template is rendered per worktree.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

: "${PROJECT_PREFIX:?PROJECT_PREFIX unset (mise env not loaded)}"
# Deliberately NOT inherited from PROXY_SUBNET/TRAEFIK_IP. Those describe the
# Docker proxy network, which holds 10.213.0.0/24 while the compose stack still
# exists -- and netavark refuses to create a network whose subnet is already
# used on the host ("subnet ... is already used on the host or by another
# config", exit 125). The podman proxy therefore gets its own range so both can
# coexist during the transition. After the Docker proxy is gone you can point
# these at 10.213.x if you prefer, but there is no reason to.
PODMAN_PROXY_SUBNET="${PODMAN_PROXY_SUBNET:-10.214.0.0/24}"
PODMAN_PROXY_IP_RANGE="${PODMAN_PROXY_IP_RANGE:-10.214.0.128/25}"
PODMAN_TRAEFIK_IP="${PODMAN_TRAEFIK_IP:-10.214.0.2}"
# Compose let Docker pick the gateway; Quadlet wants it named.
PODMAN_PROXY_GATEWAY="${PODMAN_PROXY_GATEWAY:-${PODMAN_PROXY_SUBNET%.*}.1}"

DEST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
MARKER="# rendered by .scripts/quadlet.sh"

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; FAILED=1; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
FAILED=0

render() {
  sed -e "s|@@P@@|$PROJECT_PREFIX|g" \
      -e "s|@@ROOT@@|$ROOT|g" \
      -e "s|@@TRAEFIK_IP@@|$PODMAN_TRAEFIK_IP|g" \
      -e "s|@@PROXY_SUBNET@@|$PODMAN_PROXY_SUBNET|g" \
      -e "s|@@PROXY_GATEWAY@@|$PODMAN_PROXY_GATEWAY|g" \
      -e "s|@@PROXY_IP_RANGE@@|$PODMAN_PROXY_IP_RANGE|g" \
      "$1"
}

# Exact-subnet check across both engines. netavark only reports the clash when
# the unit starts, which surfaces as a systemd dependency failure several units
# deep -- much easier to catch here.
subnet_in_use_by() {
  local want="$1" engine ids id own="${PROJECT_PREFIX}_proxy"
  for engine in podman docker; do
    command -v "$engine" >/dev/null 2>&1 || continue
    ids="$("$engine" network ls -q 2>/dev/null || true)"
    [[ -n "$ids" ]] || continue
    for id in $ids; do
      # Skip this stack's own proxy network. It holds the subnet precisely
      # because the proxy is running, which is the healthy state -- flagging it
      # told you to renumber a working setup.
      [[ "$("$engine" network inspect "$id" --format '{{.Name}}' 2>/dev/null)" == "$own" ]] && continue
      if "$engine" network inspect "$id" 2>/dev/null \
           | grep -oiE '"subnet": *"[^"]+"' \
           | grep -oE '[0-9.]+/[0-9]+' \
           | grep -qxF "$want"; then
        printf '%s' "$engine"; return 0
      fi
    done
  done
  return 1
}

# Writing unit files needs only podman and a user systemd. The socket, the
# privileged-port sysctl and linger matter when you *start* the services, so
# they are reported by doctor rather than blocking an install.
require_hard() {
  command -v podman >/dev/null || die "podman is not installed"
  local v major
  v="$(podman version --format '{{.Client.Version}}')"
  major="${v%%.*}"
  (( major >= 5 )) || die "podman $v is too old; needs >= 5 (on 4.x, Quadlet's
  Notify=healthy silently degrades to --sdnotify=conmon, so health-gated
  ordering stops working with no error)"
  systemctl --user list-units >/dev/null 2>&1 \
    || die "no systemd --user session; Quadlet needs one"
}

# Quadlet writes Label= and Environment= values into ExecStart verbatim, and
# systemd then splits on whitespace. An unquoted value containing a space is
# therefore truncated at the space, with the remainder becoming separate
# arguments -- which for a Traefik rule label means silently losing half the
# rule and gaining junk labels. Quoting escapes the spaces (\x20) the way
# HealthCmd already does. This is invisible to the generator, which reports no
# error, so lint the source templates instead.
lint_templates() {
  local bad=0 f line
  while IFS=: read -r f n line; do
    [[ -n "$line" ]] || continue
    printf '  %s:%s\n    %s\n' "$(basename "$f")" "$n" "$line" >&2
    bad=1
  done < <(grep -nHE '^(Label|Environment)=[^"]*[[:space:]]' "$ROOT"/.docker-config/quadlet/* 2>/dev/null \
             | sed 's/^\([^:]*\):\([0-9]*\):/\1:\2:/')
  if (( bad )); then
    printf '\nerror: the values above contain spaces but are not quoted.\n' >&2
    printf 'Wrap the whole value in double quotes, e.g.\n' >&2
    printf '  Label="traefik.http.routers.x.rule=Host(`a`) && PathPrefix(`/b`)"\n' >&2
    return 1
  fi
}

# The second failure of the same shape, and the one that broke the first `up`:
# Quadlet translates a [Container] EnvironmentFile= into `podman run
# --env-file`, so the values land inside the container and the systemd service
# environment stays empty. But every ${VAR} in a Quadlet key is expanded by
# *systemd*, from the service environment, when it builds ExecStart. So a
# template that references ${VAR} in its keys and loads the file only under
# [Container] gets empty strings everywhere, and podman then does something
# quietly wrong rather than failing: `--publish 127.0.0.1::5432` binds a random
# host port, `--label ...Host(``)` registers an unroutable rule. Only `--cpus=`
# happened to be strict enough to error out and expose it.
#
# The fix is to load the same file under [Service] as well, and the two are not
# redundant: [Service] resolves the unit's own keys, [Container] gives the
# container process its environment.
#
# Also catches an unescaped ${1}: that is a Traefik regex backreference, and
# systemd would expand it to nothing. It has to be written $${1}.
lint_env_expansion() {
  local f out all=""
  for f in "$ROOT"/.docker-config/quadlet/*.container; do
    [[ -e "$f" ]] || continue
    out="$(awk '
      /^\[/ { section = $0; next }
      {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)      # strip trailing comments
        gsub(/\$\$/, "", line)                 # $$ is an escaped literal $
        if (section == "[Service]") {
          if (line ~ /^EnvironmentFile=/) svc_envfile = 1
          next
        }
        if (line ~ /\$\{[A-Za-z_][A-Za-z0-9_]*\}/) {
          refs++
          if (first_ref == "") first_ref = NR ": " $0
        }
        if (line ~ /\$\{[0-9]+\}/) backref = NR ": " $0
      }
      END {
        if (refs && !svc_envfile)
          print "    references ${VAR} in a key but has no EnvironmentFile= under [Service]\n    " first_ref
        if (backref != "")
          print "    unescaped ${N} -- systemd expands it away; write $${N}\n    " backref
      }
    ' "$f")"
    [[ -n "$out" ]] || continue
    printf '  %s\n%s\n' "$(basename "$f")" "$out" >&2
    all="x$all"
  done
  [[ -n "$all" ]] || return 0
  printf '\nerror: the templates above would expand ${VAR} to an empty string.\n' >&2
  printf 'Add to the [Service] section of each:\n' >&2
  printf '  EnvironmentFile=@@ROOT@@/%%i/.units.env\n' >&2
  return 1
}

# The generated units live in ~/.config/containers/systemd, so editing a
# template in the repo -- or checking out a branch that does -- changes nothing
# until install re-renders them. systemd then keeps running the old ExecStart and
# reports the *old* failure, which reads as "the fix did not work" rather than
# "the fix was never installed". So compare what is installed against what the
# templates would render, and say which files drifted.
#
# Installed files carry the marker line as line 1, hence tail -n +2.
stale_units() {
  local src b out
  shopt -s nullglob
  for src in "$ROOT"/.docker-config/quadlet/*; do
    b="$(basename "$src")"
    out="$DEST/${PROJECT_PREFIX}-${b}"
    if [[ ! -f "$out" ]]; then
      printf '%s\tnot installed\n' "${PROJECT_PREFIX}-${b}"
    elif ! diff -q <(render "$src") <(tail -n +2 "$out") >/dev/null 2>&1; then
      printf '%s\tdiffers from the template\n' "${PROJECT_PREFIX}-${b}"
    fi
  done
}

cmd_check_stale() {
  local out
  out="$(stale_units)"
  [[ -n "$out" ]] || { printf 'installed units match the templates\n'; return 0; }
  printf 'These installed units no longer match .docker-config/quadlet/:\n\n' >&2
  printf '%s\n' "$out" | while IFS=$'\t' read -r name why; do
    printf '  %-40s %s\n' "$name" "$why" >&2
  done
  printf '\nsystemd is still running the old generated units. Re-render them:\n' >&2
  printf '  mise run podman:install\n' >&2
  return 1
}

cmd_install() {
  require_hard
  lint_templates || die "refusing to install templates that would silently lose data"
  lint_env_expansion || die "refusing to install templates whose keys cannot expand"
  mkdir -p "$DEST"
  local src b out
  for src in "$ROOT"/.docker-config/quadlet/*; do
    b="$(basename "$src")"
    out="$DEST/${PROJECT_PREFIX}-${b}"
    { printf '%s from .docker-config/quadlet/%s -- edit the repo, not this file.\n' "$MARKER" "$b"
      render "$src"; } > "$out"
    printf 'installed %s\n' "$(basename "$out")"
  done
  systemctl --user daemon-reload
  printf '\nInstalled. Now run:\n'
  printf '  mise run podman:doctor    # confirms the socket and the :80 sysctl\n'
  printf '  systemctl --user start %s-traefik\n' "$PROJECT_PREFIX"
  printf '\nThe network and volumes are created by their own generated units and\n'
  printf 'are pulled in automatically by Requires= -- never create them by hand.\n'
  printf 'Quadlet units also cannot be `systemctl --user enable`d; the [Install]\n'
  printf 'section in each .container file already handles autostart.\n'
}

# The failure this most often hits: units installed under one PROJECT_PREFIX
# while a task runs with another. systemd's own message -- "Unit
# master-traefik.service not found" -- names neither the prefix in play nor the
# prefixes that do have units, so it reads as a missing install rather than a
# mismatch.
installed_prefixes() {
  local f b
  shopt -s nullglob
  for f in "$DEST"/*-traefik.container; do
    b="$(basename "$f")"
    printf '%s\n' "${b%-traefik.container}"
  done
}

require_prefix() {
  [[ -f "$DEST/${PROJECT_PREFIX}-traefik.container" ]] && return 0
  local have
  have="$(installed_prefixes | paste -sd' ' -)"
  if [[ -n "$have" ]]; then
    die "no units installed for PROJECT_PREFIX='$PROJECT_PREFIX', but units exist for: $have
  PROJECT_PREFIX comes from mise.local.toml at the workspace root. If that is
  the wrong value, fix it there rather than reinstalling -- reinstalling would
  add a second set of units and orphan the containers you already have.
  Otherwise: mise run podman:install"
  fi
  die "no units installed at all. Run: mise run podman:install"
}

PROXY_UNITS=(traefik dozzle home)

cmd_proxy_status() {
  printf '\n'
  systemctl --user --no-pager --no-legend list-units "${PROJECT_PREFIX}-traefik.service" \
    "${PROJECT_PREFIX}-dozzle.service" "${PROJECT_PREFIX}-home.service" 2>/dev/null \
    | sed 's/^/  /' || true
  printf '\n'
  podman ps --filter "name=^${PROJECT_PREFIX}-\(traefik\|dozzle\|home\)$" \
    --format 'table {{.Names}} {{.Status}} {{.Ports}}' 2>/dev/null || true
  printf '\n  dashboard  http://wt.localhost\n'
  printf '  logs       http://logs.localhost\n'
  printf '  traefik    http://127.0.0.1:8080/\n'
}

cmd_proxy_up() {
  require_prefix
  local u
  for u in "${PROXY_UNITS[@]}"; do
    systemctl --user start "${PROJECT_PREFIX}-$u.service"
  done
  cmd_proxy_status
}

cmd_proxy_down() {
  local u
  # Reverse order: dozzle and home Require= traefik.
  for u in home dozzle traefik; do
    systemctl --user stop "${PROJECT_PREFIX}-$u.service" 2>/dev/null || true
  done
  systemctl --user stop "${PROJECT_PREFIX}-proxy-network.service" 2>/dev/null || true
  printf 'proxy stopped\n'
}

cmd_proxy_restart() {
  require_prefix
  local u
  for u in "${PROXY_UNITS[@]}"; do
    systemctl --user restart "${PROJECT_PREFIX}-$u.service"
  done
  cmd_proxy_status
}

cmd_proxy_logs() {
  local svc="${1:-traefik}"
  exec journalctl --user -f -u "${PROJECT_PREFIX}-${svc}.service"
}

# The three proxy images are registry images, so this is a plain pull plus a
# recreate -- no --ignore-buildable equivalent needed.
cmd_proxy_pull() {
  require_prefix
  podman pull docker.io/traefik:v3.7 docker.io/amir20/dozzle:latest docker.io/library/nginx:alpine
  cmd_proxy_restart
}

cmd_uninstall() {
  local f removed=0
  shopt -s nullglob
  for f in "$DEST"/*; do
    if head -1 "$f" 2>/dev/null | grep -qF "$MARKER"; then
      rm -f "$f"; printf 'removed %s\n' "$(basename "$f")"; removed=1
    fi
  done
  (( removed )) || printf 'nothing of ours in %s\n' "$DEST"
  systemctl --user daemon-reload
}

cmd_doctor() {
  FAILED=0
  printf '\n== workspace ==\n'
  if [[ "$PROJECT_PREFIX" == "default" ]]; then
    warn "PROJECT_PREFIX is still 'default', so every podman object would be
          named default_*. Create the workspace config:
              mise run config:init"
  else
    ok "PROJECT_PREFIX=$PROJECT_PREFIX"
  fi

  # More than one installed prefix means an earlier install used a different
  # PROJECT_PREFIX -- most often units installed as default-* before
  # mise.local.toml existed. The stale set never runs (no [Install]), but its
  # units are startable, and starting one contends for 127.0.0.1:80 with the
  # real proxy.
  local prefixes count
  prefixes="$(installed_prefixes | paste -sd' ' -)"
  count="$(installed_prefixes | wc -l)"
  if (( count > 1 )); then
    warn "units are installed for more than one prefix: $prefixes
          Only '$PROJECT_PREFIX' is current. Remove the others -- they are
          startable and would fight for 127.0.0.1:80:
              rm ~/.config/containers/systemd/{$(installed_prefixes | grep -v "^${PROJECT_PREFIX}$" | paste -sd, -)}-*
              systemctl --user daemon-reload"
  fi

  # The failure this catches: a template fixed in the repo, or a branch checked
  # out, without a reinstall. systemd keeps running the old generated unit and
  # reports the old error, which looks like the fix not working.
  local drift
  drift="$(stale_units | cut -f1 | paste -sd' ' -)"
  if [[ -n "$drift" ]]; then
    bad "installed units are out of date: $drift
        Re-render them, or every start reports the previous failure:
            mise run podman:install"
  else
    ok "installed units match the templates"
  fi

  printf '\n== podman ==\n'
  if command -v podman >/dev/null; then
    local v major
    v="$(podman version --format '{{.Client.Version}}')"
    major="${v%%.*}"
    if (( major >= 5 )); then
      ok "podman $v"
    else
      bad "podman $v -- needs >= 5. On 4.x, Quadlet's Notify=healthy silently
        degrades to --sdnotify=conmon, so health-gated ordering stops working
        with no error. Do not convert on 4.x."
    fi
  else
    bad "podman not installed"
  fi

  # The Dockerfiles use unqualified base images (debian:bookworm-slim,
  # node:${NODE_VERSION}-slim), which podman cannot resolve without a search
  # registry. Fedora/RHEL ship one; Debian/Ubuntu do not.
  if podman info --format '{{.Registries}}' 2>/dev/null | grep -q docker.io; then
    ok "unqualified-search-registries includes docker.io"
  else
    bad "no unqualified search registry, so the Dockerfiles' short base image
        names (debian:, node:) will fail to resolve. Add to
        /etc/containers/registries.conf or ~/.config/containers/registries.conf:
            unqualified-search-registries = [\"docker.io\"]"
  fi

  printf '\n== rootless podman socket (Traefik + Dozzle read it) ==\n'
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [[ -S "$sock" ]]; then
    ok "socket present at $sock"
  else
    bad "no socket at $sock. Enable it:
            systemctl --user enable --now podman.socket"
  fi

  printf '\n== proxy subnet ==\n'
  local holder
  if holder="$(subnet_in_use_by "$PODMAN_PROXY_SUBNET")"; then
    bad "$PODMAN_PROXY_SUBNET is already used by a $holder network, so netavark
        will refuse to create it (exit 125, surfacing as a dependency failure
        for traefik). Pick a free range -- one line, no continuations:
            PODMAN_PROXY_SUBNET=10.215.0.0/24 PODMAN_PROXY_IP_RANGE=10.215.0.128/25 PODMAN_TRAEFIK_IP=10.215.0.2 mise run podman:install
        Better: set those three in mise.local.toml so every run picks them up."
  else
    ok "$PODMAN_PROXY_SUBNET is free (traefik at $PODMAN_TRAEFIK_IP)"
  fi

  printf '\n== privileged port for Traefik :80 ==\n'
  local start
  start="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)"
  if (( start <= 80 )); then
    ok "ip_unprivileged_port_start=$start -- rootless can publish :80"
  else
    bad "ip_unprivileged_port_start=$start -- rootless cannot publish :80, so
        http://<slug>.localhost will not resolve. Fix it with:
            mise run podman:allow-ports
        That runs two one-liners, both with sudo as the first word and no pipe:
            sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
            sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=80 > /etc/sysctl.d/99-rootless-ports.conf'"
  fi

  printf '\n== who holds 127.0.0.1:80 ==\n'
  # Only one process can bind it, so the podman and Docker proxies are mutually
  # exclusive: whichever is up owns every *.localhost hostname. Without this
  # check the clash surfaces as "bind: address already in use" from systemd,
  # several units away from the cause.
  #
  # Read /proc/net/tcp rather than ss/netstat -- neither is installed on every
  # box, and a `command -v` guard around the check silently reports "free",
  # which is worse than not checking. State 0A is LISTEN, :0050 is port 80,
  # matching both a loopback (0100007F) and a wildcard (00000000) bind.
  local holder80=""
  if awk '$4 == "0A" && $2 ~ /:0050$/ { f=1 } END { exit !f }' /proc/net/tcp 2>/dev/null \
     || awk '$4 == "0A" && $2 ~ /:0050$/ { f=1 } END { exit !f }' /proc/net/tcp6 2>/dev/null; then
    holder80="unknown"
    if [[ "$(podman inspect "${PROJECT_PREFIX}-traefik" --format '{{.State.Running}}' 2>/dev/null)" == "true" ]]; then
      holder80="podman"
    elif command -v docker >/dev/null 2>&1 \
         && docker ps --format '{{.Names}}' 2>/dev/null | grep -q traefik; then
      holder80="docker"
    fi
  fi
  case "$holder80" in
    "")      ok ":80 is free" ;;
    podman)  ok ":80 held by ${PROJECT_PREFIX}-traefik (this stack)" ;;
    docker)  warn ":80 is held by a Docker traefik. Expected before the cutover, but the
            podman proxy cannot start until it stops -- only one process can bind
            127.0.0.1:80, so whichever proxy is up owns every *.localhost host:
                mise run proxy:down" ;;
    *)       warn ":80 is bound by a process this script cannot identify. The podman
            proxy will fail with 'bind: address already in use' until it frees up." ;;
  esac

  printf '\n== systemd user session ==\n'
  if systemctl --user list-units >/dev/null 2>&1; then
    ok "systemd --user reachable"
    if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == "yes" ]]; then
      ok "linger enabled"
    else
      warn "linger off -- the proxy stops when you log out:
            loginctl enable-linger $(id -un)"
    fi
  else
    bad "no systemd --user session"
  fi

  printf '\n'
  return $FAILED
}

# Prove Traefik-on-podman can discover a podman container before committing to a
# cutover. The proxy and the worktree stacks CANNOT straddle engines -- Traefik
# on podman sees nothing on Docker's socket and cannot join a Docker network --
# so this is a throwaway spike, not a migration step.
cmd_spike() {
  # Not `local`: the EXIT trap fires after this function's scope is gone, and a
  # single-quoted trap body would expand $name then -- which under `set -u` dies
  # with "unbound variable" instead of cleaning up. Value is baked in below.
  spike_name="${PROJECT_PREFIX}-spike"
  trap "podman rm -f '$spike_name' >/dev/null 2>&1 || true" EXIT

  # The network is created by its own generated unit, pulled in by Requires= on
  # the containers. Starting traefik brings up both. Nothing here needs sudo,
  # and the network must never be created by hand -- a hand-made one would not
  # carry the subnet, ip-range and MTU from proxy.network.
  local net_unit="${PROJECT_PREFIX}-proxy-network.service"
  local traefik_unit="${PROJECT_PREFIX}-traefik.service"
  if ! systemctl --user cat "$traefik_unit" >/dev/null 2>&1; then
    die "$traefik_unit does not exist -- run 'mise run podman:install' first"
  fi
  printf 'starting %s and %s...\n' "$net_unit" "$traefik_unit"
  systemctl --user start "$traefik_unit" || die "could not start $traefik_unit.
  Check: systemctl --user status $traefik_unit
  A failure to publish :80 means the sysctl is missing -- see podman:doctor."

  if ! podman network exists "${PROJECT_PREFIX}_proxy"; then
    die "network ${PROJECT_PREFIX}_proxy still missing after starting $net_unit.
  Check: systemctl --user status $net_unit"
  fi
  ok "network ${PROJECT_PREFIX}_proxy exists"

  podman run -d --rm --name "$spike_name" \
    --network "${PROJECT_PREFIX}_proxy" \
    --label traefik.enable=true \
    --label "traefik.http.routers.${spike_name}.rule=Host(\`spike.localhost\`)" \
    --label "traefik.http.routers.${spike_name}.entrypoints=web" \
    --label "traefik.http.services.${spike_name}.loadbalancer.server.port=80" \
    docker.io/library/nginx:alpine >/dev/null
  printf 'spike container up; giving Traefik 5s to discover it...\n'
  sleep 5
  printf 'routers Traefik knows about:\n'
  curl -fsS --max-time 5 http://127.0.0.1:8080/api/http/routers 2>/dev/null \
    | grep -oE "\"name\":\"[^\"]*\"" | sed 's/^/  /' \
    || printf '  could not reach the Traefik API on 127.0.0.1:8080\n'
  printf '\nexpect a router named %s@docker above, and:\n' "$spike_name"
  printf '  curl -H "Host: spike.localhost" http://127.0.0.1/  -> nginx welcome page\n'
  curl -fsS -H 'Host: spike.localhost' http://127.0.0.1/ 2>/dev/null \
    | grep -qi 'welcome to nginx' && ok "routing works end to end" \
    || bad "Traefik did not route to the spike container"
}

# Lower the privileged-port threshold so rootless podman can publish :80.
# Both commands put sudo FIRST and use no pipe, so a `sudo` alias whose body
# contains a `;` cannot split them.
cmd_allow_ports() {
  local conf=/etc/sysctl.d/99-rootless-ports.conf
  printf 'This needs root once. Running:\n'
  printf '  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80\n'
  printf "  sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=80 > %s'\n\n" "$conf"
  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
  sudo sh -c "echo net.ipv4.ip_unprivileged_port_start=80 > $conf"
  printf '\n'
  local now
  now="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"
  if (( now <= 80 )); then
    ok "ip_unprivileged_port_start=$now, persisted in $conf"
  else
    bad "still $now -- the sysctl did not take"
  fi
}

# Answer the one thing `podman ps` cannot: has Traefik actually discovered the
# containers through the podman socket? Deliberately queries Traefik's API on
# its published port rather than through its own routing (wt.localhost/api),
# so it still reports correctly when discovery is exactly what is broken.
cmd_verify() {
  FAILED=0
  local api="http://127.0.0.1:8080/api"

  printf '\n== proxy containers ==\n'
  local c
  for c in traefik dozzle home; do
    if [[ "$(podman inspect "${PROJECT_PREFIX}-$c" --format '{{.State.Running}}' 2>/dev/null)" == "true" ]]; then
      ok "${PROJECT_PREFIX}-$c running"
    else
      bad "${PROJECT_PREFIX}-$c not running: systemctl --user start ${PROJECT_PREFIX}-$c"
    fi
  done

  printf '\n== traefik api (published port, not routed) ==\n'
  if curl -fsS --max-time 5 "$api/overview" >/dev/null 2>&1; then
    ok "reachable at $api"
  elif (( FAILED )); then
    bad "unreachable at $api -- start the proxy first: mise run podman:proxy:up"
    printf '\n'; return 1
  else
    bad "unreachable at $api even though traefik is running. Its API is not
        answering; check: podman logs ${PROJECT_PREFIX}-traefik"
    printf '\n'; return 1
  fi

  printf '\n== did traefik discover the containers over the podman socket? ==\n'
  local routers want
  routers="$(curl -fsS --max-time 5 "$api/http/routers" 2>/dev/null \
    | grep -oE '"name":"[^"]+"' | sed 's/.*:"//; s/"$//')"
  if [[ -z "$routers" ]]; then
    bad "traefik knows about NO routers, so the socket mount or the docker
        provider is not working. Check:
            systemctl --user status podman.socket
            podman logs ${PROJECT_PREFIX}-traefik"
  else
    printf '%s\n' "$routers" | sed 's/^/      /'
    for want in wt-home wt-logs wt-api; do
      if printf '%s\n' "$routers" | grep -q "^${want}@"; then
        ok "$want discovered"
      else
        bad "$want missing -- labels on that container are not being picked up"
      fi
    done
  fi

  printf '\n== end-to-end routing ==\n'
  local host code
  for host in wt.localhost logs.localhost; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $host" \
      http://127.0.0.1/ 2>/dev/null || echo 000)"
    case "$code" in
      2*|3*) ok "http://$host -> $code" ;;
      *)     bad "http://$host -> $code" ;;
    esac
  done

  # The dashboard fetches /api/http/routers same-origin, which only works if
  # the wt-api router (Host(wt.localhost) && PathPrefix(/api) -> api@internal)
  # wins over wt-home. When it does not, the request falls through to nginx and
  # comes back as an HTML 404 -- which the dashboard reports as
  # "Failed to load: Unexpected token '<'". Checking the API on :8080 directly
  # does NOT catch this, because that bypasses Traefik's own routing.
  local ctype
  ctype="$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 \
    -H 'Host: wt.localhost' http://127.0.0.1/api/http/routers 2>/dev/null || echo none)"
  case "$ctype" in
    application/json*) ok "wt.localhost/api routes to Traefik's API (JSON)" ;;
    text/html*)        bad "wt.localhost/api returns HTML, not JSON: the wt-api router is not
        intercepting, so the request is falling through to nginx. The
        dashboard will show \"Failed to load: Unexpected token '<'\".
        Compare Traefik's own view:
            curl -s http://127.0.0.1:8080/api/http/routers | grep -o '\"name\":\"wt-api[^\"]*\"'
            curl -s http://127.0.0.1:8080/api/overview" ;;
    *)                 bad "wt.localhost/api returned content-type '$ctype'" ;;
  esac

  printf '\n'
  return $FAILED
}

case "${1:-}" in
  install)   cmd_install ;;
  check-stale) cmd_check_stale ;;
  uninstall) cmd_uninstall ;;
  doctor)    cmd_doctor ;;
  spike)     cmd_spike ;;
  verify)    cmd_verify ;;
  allow-ports) cmd_allow_ports ;;
  proxy-up)      cmd_proxy_up ;;
  proxy-status)  cmd_proxy_status ;;
  proxy-down)    cmd_proxy_down ;;
  proxy-restart) cmd_proxy_restart ;;
  proxy-logs)    shift; cmd_proxy_logs "$@" ;;
  proxy-pull)    cmd_proxy_pull ;;
  *) die "usage: $(basename "$0") {install|check-stale|uninstall|doctor|verify|spike|allow-ports|proxy-up|proxy-status|proxy-down|proxy-restart|proxy-logs|proxy-pull}" ;;
esac
