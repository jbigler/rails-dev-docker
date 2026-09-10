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
  local want="$1" engine ids
  for engine in podman docker; do
    command -v "$engine" >/dev/null 2>&1 || continue
    ids="$("$engine" network ls -q 2>/dev/null || true)"
    [[ -n "$ids" ]] || continue
    if "$engine" network inspect $ids 2>/dev/null \
         | grep -oiE '"subnet": *"[^"]+"' \
         | grep -oE '[0-9.]+/[0-9]+' \
         | grep -qxF "$want"; then
      printf '%s' "$engine"; return 0
    fi
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

cmd_install() {
  require_hard
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
    bad "unreachable at $api -- start the proxy first: mise run podman:proxy"
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

  printf '\n'
  return $FAILED
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  doctor)    cmd_doctor ;;
  spike)     cmd_spike ;;
  verify)    cmd_verify ;;
  allow-ports) cmd_allow_ports ;;
  *) die "usage: $(basename "$0") {install|uninstall|doctor|verify|spike|allow-ports}" ;;
esac
