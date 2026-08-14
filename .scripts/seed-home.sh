#!/usr/bin/env bash
# Seed a worktree's container home from the template, idempotently. Called by
# the mise `up` task, compose-run fallback tasks and create-worktree.sh —
# anything that may bind-mount .home/<slug> must run this first, or the
# Docker daemon creates the bind source (and volume mount points) as root.
#
# Usage: seed-home.sh <worktree-name>
set -euo pipefail

source "$(dirname "$0")/lib.sh"

name="${1:?usage: seed-home.sh <worktree-name>}"
root=$(find_project_root)
home_dir="$root/.home/$name"
tmpl="$root/.docker-config/home-template"

if [ ! -d "$home_dir" ]; then
  mkdir -p "$home_dir"
  if [ -d "$tmpl" ]; then
    cp -a "$tmpl/." "$home_dir/"
  fi
fi

# Mount-point dirs must exist appuser-owned even when the template is empty
# (fresh clone): a missing bind/volume mount point gets created by the Docker
# daemon as root, and the containers then cannot write their own home.
mkdir -p \
  "$home_dir/.ssh" \
  "$home_dir/.config/nvim" \
  "$home_dir/.config/git" \
  "$home_dir/.npm" \
  "$home_dir/.npm-global" \
  "$home_dir/.local/bin" \
  "$home_dir/.cache/ms-playwright" \
  "$home_dir/.local/share/nvim" \
  "$home_dir/.claude/plugins/cache" \
  "$home_dir/.claude/plugins/marketplaces"

# ~/.config/git/ignore is a FILE bind target — if it does not exist when a
# container starts, the Docker daemon creates it root-owned in the home,
# which later breaks the user-level `rm -rf .home/<slug>` in wt:rm.
[ -e "$home_dir/.config/git/ignore" ] || touch "$home_dir/.config/git/ignore"
