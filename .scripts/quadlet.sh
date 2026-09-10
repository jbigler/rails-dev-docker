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
TRAEFIK_IP="${TRAEFIK_IP:-10.213.0.2}"
PROXY_SUBNET="${PROXY_SUBNET:-10.213.0.0/24}"
# Not in the mise env today; compose defaulted it inline.
PROXY_IP_RANGE="${PROXY_IP_RANGE:-10.213.0.128/25}"
# Compose let Docker pick the gateway; Quadlet wants it named.
PROXY_GATEWAY="${PROXY_GATEWAY:-${PROXY_SUBNET%.*}.1}"

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
      -e "s|@@TRAEFIK_IP@@|$TRAEFIK_IP|g" \
      -e "s|@@PROXY_SUBNET@@|$PROXY_SUBNET|g" \
      -e "s|@@PROXY_GATEWAY@@|$PROXY_GATEWAY|g" \
      -e "s|@@PROXY_IP_RANGE@@|$PROXY_IP_RANGE|g" \
      "$1"
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
    warn "PROJECT_PREFIX is still 'default' -- set it in mise.local.toml at the
          workspace root, or every podman object is named default_*"
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

  printf '\n== rootless podman socket (Traefik + Dozzle read it) ==\n'
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [[ -S "$sock" ]]; then
    ok "socket present at $sock"
  else
    bad "no socket at $sock. Enable it:
            systemctl --user enable --now podman.socket"
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
  curl -fsS http://wt.localhost/api/http/routers 2>/dev/null \
    | grep -oE "\"name\":\"[^\"]*\"" | sed 's/^/  /' \
    || printf '  could not reach the Traefik API at http://wt.localhost/api\n'
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

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  doctor)    cmd_doctor ;;
  spike)     cmd_spike ;;
  allow-ports) cmd_allow_ports ;;
  *) die "usage: $(basename "$0") {install|uninstall|doctor|spike|allow-ports}" ;;
esac
