#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run wt:rm <branch|dir-name>}"

source "$(dirname "$0")/lib.sh"
root=$(find_project_root)
git_dir=$(find_git_dir)

run_git() {
  git -C "$git_dir" "$@"
}

# Sanitize the same way as creation
clean_name=$(echo "$input" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/--*/-/g; s/^-//; s/-$//')
worktree_dir="${root}/${clean_name}"

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

# Determine compose project name (mirrors mise.local.toml.template)
project_prefix="${PROJECT_PREFIX:-default}"
project_name="${project_prefix}-${clean_name}"

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
