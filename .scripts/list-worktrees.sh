#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
git_dir=$(find_git_dir) || exit 1
base_name=$(find_base_worktree_name) || exit 1

git -C "$git_dir" worktree list --porcelain \
  | grep "^worktree " \
  | sed "s|^worktree .*/||" \
  | grep -v "^${base_name}$"
