#!/usr/bin/env bash
# Create the workspace-root mise.local.toml if it is missing.
#
# bootstrap.sh writes this file as part of setting up a new workspace, but a
# manual `git clone` of the wrapper does not -- and without it PROJECT_PREFIX
# falls back to the literal "default", so every volume, network and container
# is named default_*. This fills that gap and can be re-run safely.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"
CONF="$ROOT/mise.local.toml"

if [[ -f "$CONF" ]]; then
  printf 'mise.local.toml already exists -- leaving it alone.\n\n'
  grep -E '^(PROJECT_PREFIX|GEM_VOLUME_BASE|PODMAN_)' "$CONF" | sed 's/^/  /' || true
  exit 0
fi

default_name="$(sanitize_worktree_name "$(basename "$ROOT")")"

# Non-interactive (CI, a task pipeline) takes the default rather than blocking.
if [[ -t 0 ]]; then
  read -r -p "Project name [$default_name]: " name
else
  name=""
  printf 'Not a terminal; using the default.\n'
fi
name="$(sanitize_worktree_name "${name:-$default_name}")"
[[ -n "$name" ]] || { printf 'error: project name resolved to empty\n' >&2; exit 1; }

cat > "$CONF" <<EOF
# Workspace-local configuration. Git-ignored -- yours alone, never shared.
# Created by .scripts/local-config.sh.

[env]
# Prefixes every container, volume, network and generated systemd unit.
PROJECT_PREFIX = "$name"
GEM_VOLUME_BASE = "${name}_shared_gems"

# --- podman proxy network (see .scripts/quadlet.sh) ---------------------
# The defaults in quadlet.sh (10.214.0.0/24) already avoid the Docker proxy
# network's 10.213.0.0/24. Uncomment and change these only if that range is
# also taken -- netavark refuses a subnet already in use on the host, and the
# failure surfaces as a dependency error for traefik rather than naming the
# subnet. \`mise run doctor\` reports the clash directly.
# PODMAN_PROXY_SUBNET = "10.215.0.0/24"
# PODMAN_PROXY_IP_RANGE = "10.215.0.128/25"
# PODMAN_TRAEFIK_IP = "10.215.0.2"

# --- secrets ------------------------------------------------------------
# CLAUDE_CODE_OAUTH_TOKEN = "..."
EOF

printf '\nWrote %s\n' "$CONF"
printf '  PROJECT_PREFIX  = %s\n' "$name"
printf '  GEM_VOLUME_BASE = %s_shared_gems\n\n' "$name"
printf 'mise picks this up on the next command in this directory.\n'
