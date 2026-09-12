#!/usr/bin/env bash
# Expose ONE worktree over the tailnet, on demand. Run from the worktree dir.
# Nothing persists: `off` puts it all back.
#
# The docker version served the rails and rustfs containers by their bridge IPs,
# because tailscaled runs on the host and could route straight into a docker
# bridge. Rootless podman cannot do that: its netavark bridge lives in a
# separate network namespace, and podman-unshare(1) says connecting to a
# rootless container by IP "is otherwise not possible from the host network
# namespace". A tailscale sidecar per worktree would be one answer; the far
# simpler one is that loopback-published ports ARE reachable from the host, and
# `tailscale serve` takes a plain http://127.0.0.1:<port> target. So rails@ and
# rustfs@ publish :3000 and :9000 on per-worktree loopback ports and this points
# tailscale at those.
#
# Traefik stays bypassed, exactly as before: no Host-header rules are involved
# and no other worktree becomes reachable.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

action="${1:-on}"
: "${PROJECT_PREFIX:?run from a worktree directory (mise env not loaded)}"
: "${CURRENT_WORKTREE_NAME:?this task acts on a single worktree, so run it from inside one. At the workspace root PROJECT_PREFIX is set but CURRENT_WORKTREE_NAME is not, because that value is defined in the mise.local.toml inside each worktree. Use mise run wt:ls to list them.}"
P="$PROJECT_PREFIX"
W="$CURRENT_WORKTREE_NAME"
WT_ENV="$ROOT/.unit-env/$W.env"
SHARE_ENV="$ROOT/.unit-env/$W.share.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$WT_ENV" ]] || die "no env file at $WT_ENV -- run: mise run units:env"
# shellcheck disable=SC1090
set -a; . "$WT_ENV"; set +a
: "${APP_PORT:?APP_PORT missing from $WT_ENV -- regenerate it: mise run units:env}"
: "${S3_PORT:?S3_PORT missing from $WT_ENV -- regenerate it: mise run units:env}"

restart_rails() {
  systemctl --user restart "$P-rails@$W.service"
  # The published port is bound by rootlessport after the container starts, so
  # tailscale serve can be pointed at a port nothing is listening on yet. Wait
  # for the listener rather than racing it -- /proc/net/tcp, because `ss` is not
  # installed everywhere and its absence would read as "not listening".
  local hexport i
  hexport=$(printf '%04X' "$1")
  for i in $(seq 1 60); do
    if awk -v p=":$hexport" '$4 == "0A" && $2 ~ p"$" { f=1 } END { exit !f }' \
         /proc/net/tcp 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  die "nothing is listening on 127.0.0.1:$1 after 30s -- check: mise run logs"
}

case "$action" in
  on)
    command -v tailscale >/dev/null || die "tailscale is not installed"
    ts_host=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' | sed 's/\.$//')
    [ -n "$ts_host" ] && [ "$ts_host" != "null" ] \
      || die "tailscale is not up (sudo systemctl start tailscaled)"
    ts_ip=$(tailscale ip -4)
    [ -n "$ts_ip" ] || die "tailscale reports no IPv4 address"

    # DOMAIN drives default_url_options and config.hosts; DEV_HOSTS keeps the
    # desktop's http://<slug>.localhost working while shared; TS_HOST_ENTRY
    # becomes rails@'s extra --add-host so rails can reach its own signing
    # endpoint server-side. These override .unit-env/<wt>.env, which rails@ loads
    # first -- podman joins --env over the earlier --env-file, and systemd's
    # last EnvironmentFile wins the same way.
    cat > "$SHARE_ENV" <<EOF
# Written by wt:share. Remove with: mise run wt:unshare
DOMAIN=$ts_host
DEV_HOSTS=$WORKTREE_HOST
RUSTFS_ENDPOINT=https://$ts_host:8443
TS_HOST_ENTRY=$ts_host:$ts_ip
EOF

    restart_rails "$APP_PORT"

    # One worktree at a time: reset drops any previous worktree's mappings
    # rather than stacking a second :443 on top.
    tailscale serve reset
    tailscale serve --bg --https=443  "http://127.0.0.1:${APP_PORT}"
    tailscale serve --bg --https=8443 "http://127.0.0.1:${S3_PORT}"

    printf 'Shared: https://%s  (S3 on :8443)\n' "$ts_host"
    printf 'Local http://%s keeps working.\n' "$WORKTREE_HOST"
    ;;
  off)
    command -v tailscale >/dev/null && tailscale serve reset || true
    # Truncated, not deleted: rails@ loads it unconditionally and podman's
    # --env-file fails on a missing path.
    printf '# Written by wt:share. Empty means not shared.\n' > "$SHARE_ENV"
    restart_rails "$APP_PORT"
    printf 'Unshared. http://%s is back to local only.\n' "$WORKTREE_HOST"
    ;;
  *)
    die "usage: $(basename "$0") [on|off]"
    ;;
esac
