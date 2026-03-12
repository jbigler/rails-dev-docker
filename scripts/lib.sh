find_git_dir() {
  # Prefer master as it's never removed
  if [ -d "master/.git" ] || [ -f "master/.git" ]; then
    echo "master/"
    return
  fi

  for d in */; do
    if [ -d "${d}.git" ] || [ -f "${d}.git" ]; then
      echo "$d"
      return
    fi
  done

  echo "No git worktree found in $(pwd)" >&2
  exit 1
}
