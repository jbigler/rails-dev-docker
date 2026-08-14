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

# Safety: refuse to run when git's worktree view is incomplete. Inside the
# claude container the sibling worktrees are not mounted at their registered
# host paths, so any prune-like operation would see every absent directory as
# a dead worktree and purge the entire registry (disconnecting all worktrees).
# Only proceed when every registered worktree path actually exists on disk.
missing=""
while read -r wt; do
  [ -n "$wt" ] || continue
  [ -d "$wt" ] || missing="${missing}"$'\n'"  ${wt}"
done < <(run_git worktree list --porcelain | sed -n 's/^worktree //p')
if [ -n "$missing" ]; then
  echo "Error: Refusing to remove — git reports worktrees whose directories are missing:" >&2
  echo "$missing" >&2
  echo "" >&2
  echo "This means you are in a partial filesystem view (e.g. the claude container)." >&2
  echo "Run 'mise run wt:rm' on the host, where all worktrees are present." >&2
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

# Remove any orphaned images belonging to this project. The compose project
# label alone is NOT sufficient here: compose stamps it on the shared base
# images too (filial/rails, filial/nvim, filial/playwright, filial/claude),
# using whichever project built them last — so filtering on the label would
# delete the bases out from under every other worktree. An image is only ours
# when its project + service labels reconstruct its own repository name, which
# is compose's default naming for images it builds:
#   filial-master-app  = filial-master + "-" + app   → ours
#   filial/rails:...   labelled filial-master        → not ours, skipped
# The service label has to come from `docker image inspect`: `docker images
# --format` exposes no .Labels field and errors on it.
orphan_image_ids=$(docker images -q --filter "label=com.docker.compose.project=$project_name" | sort -u)
orphan_images=""
if [ -n "$orphan_image_ids" ]; then
  orphan_images=$(docker image inspect $orphan_image_ids \
    --format '{{range .RepoTags}}{{.}} {{end}}	{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null \
    | awk -F'\t' -v p="$project_name" '
        $2 == "" { next }
        {
          n = split($1, tags, " ")
          for (i = 1; i <= n; i++) {
            if (tags[i] == "") continue
            repo = tags[i]; sub(/:[^:]*$/, "", repo)
            if (repo == p "-" $2) print tags[i]
          }
        }')
fi
if [ -n "$orphan_images" ]; then
  echo "Removing orphaned images..."
  docker rmi $orphan_images || true
fi

# Drop the dashboard's claude status file for this worktree
rm -f "${root}/.docker-config/status/${clean_name}.json"

# Drop this worktree's home. Its ~/.claude holds a live OAuth refresh token
# valid for weeks, so an orphaned home is a stale credential, not just
# clutter. Guard the path: only a plain name directly under .home/ may go.
case "$clean_name" in
  ''|.|..|*/*)
    echo "warn: suspicious worktree name '${clean_name}'; not removing its home" >&2
    ;;
  *)
    rm -rf "${root}/.home/${clean_name}"
    ;;
esac

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

# Remove the worktree. Use the scoped 'git worktree remove' — it deletes only
# this worktree's directory and its single admin entry. Never use a blanket
# 'git worktree prune', which sweeps every entry whose path is not currently
# visible and can purge unrelated worktrees. --force is required because the
# per-worktree seed files (mise.local.toml, etc.) are always untracked; the
# tracked/staged dirty check above already guards the user's real work.
echo "Removing worktree directory..."
if ! run_git worktree remove --force "$worktree_dir"; then
  # Fallback: the directory is not a git-tracked worktree (already orphaned).
  # Remove the directory and ONLY this worktree's admin entry — never a prune.
  echo "Not tracked by git; removing directory and its admin entry directly..."
  rm -rf "$worktree_dir"
  rm -rf "${git_dir}/worktrees/${clean_name}"
fi

base_name=$(find_base_worktree_name)
base_dir="${root}/${base_name}"
echo "✓ Removed worktree: ${worktree_dir}"

# Change to base worktree directory
if [ -d "$base_dir" ]; then
  echo "Changing to ${base_name} directory..."
  cd "$base_dir"
fi
