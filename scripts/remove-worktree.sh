#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run wt:rm <branch|dir-name>}"

source "$(dirname "$0")/lib.sh"
git_dir=$(find_git_dir)

run_git() {
  git -C "$git_dir" "$@"
}

# Sanitize the same way as creation
clean_name=$(echo "$input" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/--*/-/g; s/^-//; s/-$//')
worktree_dir="${PWD}/${clean_name}"

if [ ! -d "$worktree_dir" ]; then
  echo "Worktree not found: $worktree_dir"
  echo ""
  echo "Known worktrees:"
  run_git worktree list
  exit 1
fi

# Find and stop the compose stack
project_name=$(docker compose ls -aq 2>/dev/null | grep "$clean_name" | head -1 || true)

if [ -n "$project_name" ]; then
  echo "Stopping compose stack: ${project_name}..."
  docker compose -p "$project_name" down -v --remove-orphans --timeout 30 || true
  if docker ps -q --filter "label=com.docker.compose.project=$project_name" | grep -q .; then
    echo "Force removing lingering containers..."
    docker rm -f $(docker ps -aq --filter "label=com.docker.compose.project=$project_name")
  fi
fi

# Deregister ports
REGISTRY="${PWD}/ports.registry"
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

master_dir="${PWD}/master"
echo "✓ Removed worktree: ${worktree_dir}"

# Change to master directory
if [ -d "$master_dir" ]; then
  echo "Changing to master directory..."
  cd "$master_dir"
fi
