# Returns the absolute path to the orchestration root.
# Resolved from the location of this script file, so it works regardless of $PWD.
find_project_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$script_dir/.." && pwd)
}

# Returns the absolute path to a directory with app git context.
# Walks up from $PWD (stopping at the project root), then falls back to
# scanning the project root's subdirectories.
# Prefers the base worktree (.git directory) over linked worktrees (.git file).
find_git_dir() {
  local root
  root=$(find_project_root)

  # Walk up from $PWD looking for app git context (skip the project root
  # itself, which has its own unrelated git repo)
  local dir="$PWD"
  while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.git" ] || [ -d "$dir/.git" ]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done

  # Search project root subdirectories — prefer the base worktree
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  echo "No app git repository found in $root" >&2
  return 1
}

# Returns the directory name of the base worktree (the one with a .git directory).
find_base_worktree_name() {
  local root
  root=$(find_project_root)

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      basename "${d%/}"
      return
    fi
  done

  echo "No base worktree found in $root" >&2
  return 1
}
