#!/usr/bin/env bash
# Seed a worktree's container home from the template, idempotently. Called by
# `up`, `exec`'s transient-container path, podman-claude.sh and
# create-worktree.sh — anything that may bind-mount .home/<slug> must run this
# first. Under docker the cost of skipping it was the daemon creating the bind
# source as root; under podman it is worse, because podman does not create a
# missing bind source at all and fails the unit with
# "statfs <path>: no such file or directory" (exit 125).
#
# Usage: seed-home.sh <worktree-name>
set -euo pipefail

source "$(dirname "$0")/lib.sh"

name="${1:?usage: seed-home.sh <worktree-name>}"
root=$(find_project_root)
home_dir="$root/.home/$name"
tmpl="$root/.container-config/home-template"

if [ ! -d "$home_dir" ]; then
  mkdir -p "$home_dir"
  if [ -d "$tmpl" ]; then
    cp -a "$tmpl/." "$home_dir/"
  fi
fi

# Mount-point dirs must exist even when the template is empty (fresh clone).
# Rootless podman creates what it must as you rather than as root, so the old
# ownership hazard is gone, but a missing *bind* source is still fatal and the
# volumes mounted inside this home need their mount points to exist.
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
  "$home_dir/.claude/plugins/marketplaces" \
  "$home_dir/.claude/projects/-app-$name"

# ~/.config/git/ignore is a FILE bind target: nvim@ mounts the host's copy at
# this path, which lands inside the bind-mounted home. Under docker the daemon
# created the missing file root-owned, which then broke the user-level
# `rm -rf .home/<slug>` in wt:rm. Rootless podman would create it as you, so
# that specific hazard is gone; creating it here keeps the home's contents
# predictable rather than depending on what the runtime does with a missing
# mount point.
[ -e "$home_dir/.config/git/ignore" ] || touch "$home_dir/.config/git/ignore"
