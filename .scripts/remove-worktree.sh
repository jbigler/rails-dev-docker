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

# No fallback on the prefix: with the wrong one the teardown below silently
# targets units that do not exist and leaves the real stack running.
if [ -z "${PROJECT_PREFIX:-}" ]; then
  echo "Error: PROJECT_PREFIX is unset — run via 'mise run wt:rm' so the mise env is loaded" >&2
  exit 1
fi
P="$PROJECT_PREFIX"
W="$clean_name"

# The containers belong to systemd, not to us. Stopping them with `podman stop`
# would leave the units active and Restart=on-failure would bring them straight
# back, so the units go first and the container sweep below is only a fallback
# for anything left behind (a container started by hand, or one whose unit was
# already removed).
echo "Stopping the units for worktree ${W}..."
for svc in rails claude nvim playwright rustfs rustfs-init redis db net-network; do
  systemctl --user stop "${P}-${svc}@${W}.service" 2>/dev/null || true
done

# Explicit names, never a prefix filter. `--filter name=` is an unanchored
# regex, so "^${P}-${W}-" also matches a *different* worktree whose slug starts
# with this one: removing "api" would have swept "api-v2"'s containers and
# volumes with it. Enumerating the service names the templates actually set
# cannot do that. Verified against a list containing api-v2 before and after.
SERVICES="rails claude nvim playwright rustfs rustfs-init redis db"
lingering=""
for svc in $SERVICES; do
  ct="${P}-${W}-${svc}"
  podman container exists "$ct" 2>/dev/null && lingering="$lingering $ct"
done
if [ -n "$lingering" ]; then
  echo "Force removing lingering containers..."
  # shellcheck disable=SC2086
  podman rm -f $lingering || true
fi

# Only this worktree's three volumes. The shared ones -- gems, npm caches, nvim
# share, playwright browsers, claude plugins -- are underscore-separated
# (${P}_npm_cache) and are not in this list; removing them would force every
# other worktree to a cold start.
orphan_volumes=""
for v in "${P}-${W}-db-data" "${P}-${W}-rustfs-data" "${P}-${W}-node-modules"; do
  podman volume exists "$v" 2>/dev/null && orphan_volumes="$orphan_volumes $v"
done
if [ -n "$orphan_volumes" ]; then
  echo "Removing this worktree's volumes (db, rustfs, node_modules)..."
  # shellcheck disable=SC2086
  podman volume rm $orphan_volumes || true
fi

# The per-worktree network, named exactly by net@.network's NetworkName -- an
# exact name, so the same prefix-collision problem does not arise. The shared
# ${P}_proxy network is underscore-separated and is not this name.
if podman network exists "${P}-${W}-dev" 2>/dev/null; then
  echo "Removing network ${P}-${W}-dev..."
  podman network rm "${P}-${W}-dev" || true
fi

# Deliberately NO image removal, which is a real difference from the compose
# teardown this replaces. That one ran `--rmi local` plus a label sweep, because
# compose built one image per project (filial-master-app) and those were dead
# once the project was gone.
#
# Under podman the tags are keyed by the runtime versions instead of the
# worktree -- localhost/<prefix>/rails:ruby4.0.3-node24.19.0 -- so one image
# serves every worktree on the same ruby/node combination. Removing images here
# would take the rails image out from under every other worktree and force a
# full rebuild. Sweeping genuinely unreferenced images is `mise run clean`'s
# job, where it can see all the worktrees at once.

# The unit env file lives in the workspace root, not the worktree, so removing
# the worktree directory does not take it with it.
rm -f "${root}/.units/${clean_name}.env" "${root}/.units/${clean_name}.share.env"

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
