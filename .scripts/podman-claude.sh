#!/usr/bin/env bash
# Run Claude Code for this worktree in a one-off interactive container.
#
# Deliberately NOT a systemd unit. Under compose this was `docker compose run
# --rm claude` against a service carrying profiles: ["do_not_start"] -- a
# foreground, interactive, throwaway container. A Quadlet unit models a service:
# systemd starts it detached with nothing attached to its TTY, so `systemctl
# --user start claude@<wt>` could never give you a session. claude@.container
# was removed for that reason and its mount set lives here instead.
#
# The unit's Wants= is reproduced by starting rails and playwright first. The
# test path is claude -> playwright -> rails: Claude drives the browser server,
# and the browser visits the rails dev server by its `rails` network alias. So
# starting claude alone has to bring both up, or its system tests have nothing
# to drive and nothing to visit. Failures there are not fatal -- neither should
# take the Claude session down with it.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

: "${PROJECT_PREFIX:?run from a worktree directory (mise env not loaded)}"
: "${CURRENT_WORKTREE_NAME:?this task acts on a single worktree, so run it from inside one. At the workspace root PROJECT_PREFIX is set but CURRENT_WORKTREE_NAME is not, because that value is defined in the mise.local.toml inside each worktree. Use mise run wt:ls to list them.}"
P="$PROJECT_PREFIX"
W="$CURRENT_WORKTREE_NAME"
WT_DIR="$ROOT/$W"
WT_ENV="$ROOT/.unit-env/$W.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

ensure_unit_env
"$ROOT/.scripts/seed-home.sh" "$W" >&2

# Only the unit env file. .container-config/.env is a podman --env-file, NOT a
# shell file: it uses podman's bare-name pass-through form (a line with just
# GH_TOKEN), which a shell reads as a command -- "GH_TOKEN: command not found".
# Nothing here needs it anyway; every value below comes from the unit env file,
# and the container still receives .env through --env-file further down.
set -a; . "$WT_ENV"; set +a
podman image exists "$CLAUDE_IMAGE" || die "$CLAUDE_IMAGE is not built. Run: mise run build claude"

# Best-effort, like the unit's Wants=.
systemctl --user start "$P-rails@$W.service" "$P-playwright@$W.service" 2>/dev/null || true

# CLAUDE_NO_TOKEN leaves the flag out so this home's own login -- or the /login
# prompt on a home that has none -- decides. Otherwise forward the host's token;
# a bare --env NAME inherits the value from this environment, and the token wins
# over anything stored in the home.
token=()
[[ -n "${CLAUDE_NO_TOKEN:-}" ]] || token=(--env CLAUDE_CODE_OAUTH_TOKEN)

# SSH_AGENT_SOCK may be unset or stale; mounting a missing path fails the run
# outright under podman, so skip it rather than lose the session over an agent.
agent=()
[[ -S "${SSH_AGENT_SOCK:-}" ]] && agent=(-v "$SSH_AGENT_SOCK:/tmp/ssh-agent.sock:ro,z")
gitignore=()
[[ -f "$HOME/.config/git/ignore" ]] && \
  gitignore=(-v "$HOME/.config/git/ignore:/home/appuser/.config/git/ignore:ro,z")

# The two plugin payload dirs are mounted separately and deliberately NOT as one
# volume at ~/.claude/plugins: known_marketplaces.json and installed_plugins.json
# live between them and must stay in the per-worktree bind-mounted home, or
# claude:template:promote and :apply stop seeing the plugin records.
#
# claude-memory is one directory shared by every worktree and by host sessions,
# which symlink to it. Homes are per-worktree and wt:rm deletes them, so memory
# kept under .home/<slug> would die with the worktree.
mkdir -p "$ROOT/.container-config/claude-memory" "$ROOT/.container-config/status"
memdir="$ROOT/.home/$W/.claude/projects/-app-$W"
mkdir -p "$memdir"

exec podman run --rm -it \
  --name "$P-$W-claude" \
  --network "$P-$W-dev" --network-alias claude \
  --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cpus="$CPUS_50" \
  --label traefik.enable=false \
  --env-file "$ROOT/.container-config/.env" --env-file "$WT_ENV" \
  --env NODE_OPTIONS=--max-old-space-size=4096 \
  --env POWERLEVEL9K_DISABLE_GITSTATUS=true \
  --env SSH_AUTH_SOCK=/tmp/ssh-agent.sock \
  --env RUSTFS_ENDPOINT=http://rustfs:9000 \
  "${token[@]}" "${agent[@]}" "${gitignore[@]}" \
  -v "$ROOT/.home/$W:/home/appuser:z" \
  -v "$WT_DIR:/app-$W:z" \
  -v "$ROOT/.container-config/CLAUDE.md:/opt/claude/CLAUDE.md:ro,z" \
  -v "$ROOT/.container-config/claude-memory:/home/appuser/.claude/projects/-app-$W/memory:z" \
  -v "$ROOT/.container-config/entrypoint-claude.sh:/usr/local/bin/entrypoint-claude.sh:ro,z" \
  -v "$ROOT/.container-config/init-firewall.sh:/usr/local/bin/init-firewall.sh:ro,z" \
  -v "$ROOT/.container-config/claude-status-hook.sh:/usr/local/bin/claude-status-hook.sh:ro,z" \
  -v "$ROOT/.container-config/status:/status:z" \
  -v "$MAIN_WORKTREE_PATH/.git:$MAIN_WORKTREE_PATH/.git:z" \
  -v "$SSH_PATH:/home/appuser/.ssh:ro,z" \
  -v "$GEM_VOLUME:/usr/local/bundle" \
  -v "$P-$W-node-modules:/app-$W/node_modules:U" \
  -v "${P}_npm_cache:/home/appuser/.npm:U" \
  -v "${P}_npm_global:/home/appuser/.npm-global:U" \
  -v "${P}_claude_plugins_cache:/home/appuser/.claude/plugins/cache:U" \
  -v "${P}_claude_plugins_marketplaces:/home/appuser/.claude/plugins/marketplaces:U" \
  -w "/app-$W" \
  --entrypoint entrypoint-claude.sh \
  "$CLAUDE_IMAGE" "$@"
