#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run wt:rm <branch|dir-name>}"

source "$(dirname "$0")/lib.sh"
root=$(find_project_root)
git_dir=$(find_git_dir)

run_git() {
  git -C "$git_dir" "$@"
}

# Sanitize the same way as creation. Note: this only resolves the
# canonical (un-hashed) slug. If the worktree was created with a hash
# suffix due to name collision, pass the full directory name directly.
clean_name=$(sanitize_worktree_name "$input")
worktree_dir="${root}/${clean_name}"

# If the un-hashed slug doesn't exist, try the input verbatim — it may
# already be the hash-suffixed dir name.
if [ ! -d "$worktree_dir" ] && [ -d "${root}/${input}" ]; then
  clean_name="$input"
  worktree_dir="${root}/${input}"
fi

if [ ! -d "$worktree_dir" ]; then
  echo "Worktree not found: $worktree_dir"
  echo ""
  echo "Known worktrees:"
  run_git worktree list
  exit 1
fi

# A linked worktree has a .git file; the base worktree has a .git directory
if [ -d "${worktree_dir}/.git" ]; then
  echo "Error: Cannot remove the base worktree (${clean_name})"
  exit 1
fi

# Refuse to remove a worktree with uncommitted or unstaged changes —
# removal is destructive (rm -rf) and would lose that work. The user can
# override with FORCE=1 if they really want to discard the changes.
dirty=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)
if [ -n "$dirty" ]; then
  if [ "${FORCE:-}" = "1" ]; then
    echo "Warning: ${clean_name} has uncommitted or unstaged changes — discarding them (FORCE=1):"
    git -C "$worktree_dir" status --short
  else
    echo "Error: Refusing to remove '${clean_name}' — it has uncommitted or unstaged changes:" >&2
    echo "" >&2
    git -C "$worktree_dir" status --short >&2
    echo "" >&2
    echo "Commit or stash them first, or re-run with FORCE=1 to discard them." >&2
    exit 1
  fi
fi

# Determine compose project name (mirrors mise.local.toml.template).
# No fallback: with a wrong prefix the docker teardown below silently
# targets a nonexistent project and leaves the real stack running.
if [ -z "${PROJECT_PREFIX:-}" ]; then
  echo "Error: PROJECT_PREFIX is unset — run via 'mise run wt:rm' so the mise env is loaded" >&2
  exit 1
fi
project_name="${PROJECT_PREFIX}-${clean_name}"

echo "Stopping compose stack: ${project_name}..."
docker compose -p "$project_name" down -v --rmi local --remove-orphans --timeout 30 || true

# Force-remove any lingering containers
lingering=$(docker ps -aq --filter "label=com.docker.compose.project=$project_name")
if [ -n "$lingering" ]; then
  echo "Force removing lingering containers..."
  docker rm -f $lingering
fi

# Remove any orphaned volumes belonging to this project
orphan_volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project_name")
if [ -n "$orphan_volumes" ]; then
  echo "Removing orphaned volumes..."
  docker volume rm $orphan_volumes || true
fi

# Remove any orphaned networks belonging to this project
orphan_networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project_name")
if [ -n "$orphan_networks" ]; then
  echo "Removing orphaned networks..."
  docker network rm $orphan_networks || true
fi

# Remove any orphaned images belonging to this project
orphan_images=$(docker images -q --filter "label=com.docker.compose.project=$project_name")
if [ -n "$orphan_images" ]; then
  echo "Removing orphaned images..."
  docker rmi $orphan_images || true
fi

# Deregister ports
REGISTRY="${root}/ports.registry"
if [ -f "$REGISTRY" ]; then
  sed -i.bak "/^${clean_name}:/d" "$REGISTRY"
  rm -f "${REGISTRY}.bak"
fi

# Remove mise trust symlinks for this worktree
mise_state_dir="${HOME}/.local/state/mise"
for subdir in tracked-configs trusted-configs; do
  dir="${mise_state_dir}/${subdir}"
  [ -d "$dir" ] || continue
  find "$dir" -type l | while read -r link; do
    target=$(readlink -f "$link" 2>/dev/null || true)
    if [[ "$target" == "${worktree_dir}"* ]]; then
      echo "Removing mise trust link: $link -> $target"
      rm -f "$link"
    fi
  done
done

# Remove the worktree
echo "Removing worktree directory..."
rm -rf "$worktree_dir"
run_git worktree prune

base_name=$(find_base_worktree_name)
base_dir="${root}/${base_name}"
echo "✓ Removed worktree: ${worktree_dir}"

# Change to base worktree directory
if [ -d "$base_dir" ]; then
  echo "Changing to ${base_name} directory..."
  cd "$base_dir"
fi
