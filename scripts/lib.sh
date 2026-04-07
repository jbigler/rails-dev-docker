find_git_dir() {
  # If we're inside a worktree or repo, check it's not the parent's unrelated repo
  if [ -f ".git" ]; then
    # Linked worktree — .git is a file
    echo "./"
    return
  elif [ -d ".git" ] && [ -d ".git/worktrees" ]; then
    # Root worktree — has .git/worktrees/ managing linked worktrees
    echo "./"
    return
  fi

  # Prefer the base worktree (.git directory) over linked worktrees (.git file)
  for d in */; do
    if [ -d "${d}.git" ]; then
      echo "$d"
      return
    fi
  done

  for d in */; do
    if [ -f "${d}.git" ]; then
      echo "$d"
      return
    fi
  done

  echo "No git worktree found in $(pwd)" >&2
  return 1
}

# Returns the directory name of the base worktree (the one with a .git directory)
find_base_worktree_name() {
  if [ -d ".git" ]; then
    basename "$PWD"
    return
  fi

  for d in */; do
    if [ -d "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  echo "No base worktree found in $(pwd)" >&2
  return 1
}
