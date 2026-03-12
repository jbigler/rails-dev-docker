#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
git_dir=$(find_git_dir)

if [ -z "$git_dir" ]; then
  echo "No git worktree found in $(pwd)"
  exit 1
fi

git -C "$git_dir" worktree list --porcelain \
  | grep "^worktree " \
  | sed "s|^worktree .*/||" \
  | grep -vE "^(main|master)$"
