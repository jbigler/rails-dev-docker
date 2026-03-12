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

  # Prefer the primary branch (master or main) as it's never removed
  for primary in master main; do
    if [ -d "${primary}/.git" ] || [ -f "${primary}/.git" ]; then
      echo "${primary}/"
      return
    fi
  done

  for d in */; do
    if [ -d "${d}.git" ] || [ -f "${d}.git" ]; then
      echo "$d"
      return
    fi
  done

  echo "No git worktree found in $(pwd)" >&2
  return 1
}
