#!/usr/bin/env bash
# Build the four locally built images under podman.
#
# Replaces `docker compose build --pull`. Tags and build args are read from this
# worktree's unit env file rather than recomputed, so the images this produces
# cannot drift from the tags the Quadlet units expect.
#
# Usage: podman-build.sh [--pull] [service...]
#   --pull    re-fetch the ruby/node/debian FROM layers instead of reusing
#             cached ones (podman --pull=newer)
#   service   one or more of: rails nvim claude playwright (default: all)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"
CTX="$ROOT/.container-config"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Not $PWD: mise runs tasks from config_root regardless of the directory you
# invoke them from, so the worktree has to be derived from its name.
: "${CURRENT_WORKTREE_NAME:?this task acts on a single worktree, so run it from inside one. At the workspace root PROJECT_PREFIX is set but CURRENT_WORKTREE_NAME is not, because that value is defined in the mise.local.toml inside each worktree. Use mise run wt:ls to list them.}"
WT_DIR="$ROOT/$CURRENT_WORKTREE_NAME"
# The env file lives in the wrapper, not the worktree: a worktree is a checkout
# of the app repo, and this file holds POSTGRES_PASSWORD.
WT_ENV="$ROOT/.unit-env/$CURRENT_WORKTREE_NAME.env"

[[ -d "$WT_DIR" ]] || die "no worktree directory at $WT_DIR"

# Generate it rather than complaining: build-before-up would otherwise be an
# ordering trap, and podman-wt.sh already self-heals the same way. Stale counts
# as missing -- the whole point of this script is to build the tags a .nvmrc or
# .ruby-version bump asks for.
ensure_unit_env
set -a; . "$WT_ENV"; set +a

for v in RAILS_IMAGE NVIM_IMAGE CLAUDE_IMAGE PLAYWRIGHT_IMAGE RUBY_VERSION NODE_VERSION PLAYWRIGHT_VERSION; do
  [[ -n "${!v:-}" ]] || die "$v missing from $WT_ENV -- regenerate it: mise run units:env"
done

PULL=()
if [[ "${1:-}" == "--pull" ]]; then PULL=(--pull=newer); shift; fi
services=("$@")
(( ${#services[@]} )) || services=(rails nvim claude playwright)

# APP_USER_UID/APP_GROUP_GID are fixed at 1000 rather than taken from the host,
# because the units map the host UID onto 1000 with
# UserNS=keep-id:uid=1000,gid=1000. Passing the host's own UID here would break
# that mapping on any machine where it is not 1000.
common=(
  --build-arg "RUBY_VERSION=$RUBY_VERSION"
  --build-arg "NODE_VERSION=$NODE_VERSION"
  --build-arg APP_USER_UID=1000
  --build-arg APP_GROUP_GID=1000
  # The claude-cli stage is shared by the nvim and claude targets, so its args
  # belong to every build rather than just the claude one -- otherwise the two
  # images could end up on different Claude Code versions.
  # UPDATE_CLAUDE_CODE is a cache-buster whose value is never read.
  --build-arg CLAUDE_CODE_VERSION=latest
  --build-arg "UPDATE_CLAUDE_CODE=${UPDATE_CLAUDE_CODE:-0}"
)

built=()

build_target() {
  local target="$1" tag="$2"; shift 2
  printf '\n==> %s  ->  %s\n' "$target" "$tag"
  podman build "${PULL[@]}" --target "$target" -t "$tag" \
    "${common[@]}" "$@" -f "$CTX/Dockerfile" "$CTX"
  built+=("$tag")
}

for svc in "${services[@]}"; do
  case "$svc" in
    rails)  build_target rails "$RAILS_IMAGE" ;;
    nvim)   build_target nvim  "$NVIM_IMAGE" ;;
    claude) build_target claude "$CLAUDE_IMAGE" \
              --build-arg GIT_DELTA_VERSION=0.19.2 ;;
    playwright)
      printf '\n==> playwright  ->  %s\n' "$PLAYWRIGHT_IMAGE"
      podman build "${PULL[@]}" -t "$PLAYWRIGHT_IMAGE" \
        --build-arg "PLAYWRIGHT_VERSION=$PLAYWRIGHT_VERSION" \
        -f "$CTX/Dockerfile.playwright" "$CTX"
      built+=("$PLAYWRIGHT_IMAGE") ;;
    *) die "unknown service '$svc' (rails nvim claude playwright)" ;;
  esac
done

# The tags this run produced, not every tag matching the repo name: the old
# footer grepped `podman images` for localhost/<prefix>/rails and so listed the
# *previous* node/ruby tags as if they had just been built -- while omitting
# nvim, claude and playwright, whose repo names did not match.
printf '\nBuilt:\n'
for tag in "${built[@]}"; do
  printf '  %-52s %s\n' "$tag" \
    "$(podman image inspect --format '{{.Size}}' "$tag" 2>/dev/null \
       | numfmt --to=iec --suffix=B 2>/dev/null)"
done
