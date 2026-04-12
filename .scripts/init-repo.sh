#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run init <user/repo | git-url>}"

source "$(dirname "$0")/lib.sh"
root=$(find_project_root)

# --- Resolve clone URL and repo name ---

if [[ "$input" =~ ^https?:// || "$input" =~ ^git@ ]]; then
  clone_url="$input"
  repo_name=$(basename "$input" .git)
elif [[ "$input" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  clone_url="https://github.com/${input}.git"
  repo_name=$(echo "$input" | cut -d/ -f2)
else
  echo "Error: unrecognized format '${input}'"
  echo "  Expected: user/repo  or  https://github.com/user/repo.git"
  exit 1
fi

clone_dir="${root}/${repo_name}"

if [ -d "$clone_dir" ]; then
  echo "Error: directory already exists: ${clone_dir}"
  exit 1
fi

# --- Clone ---

echo "Cloning ${clone_url} into ${clone_dir}..."
git clone "$clone_url" "$clone_dir"

# --- Register as base worktree (ID 0) in ports registry ---

REGISTRY="${root}/ports.registry"
if [ -f "$REGISTRY" ]; then
  echo "Warning: ${REGISTRY} already exists, skipping registration"
else
  echo "${repo_name}:0" > "$REGISTRY"
fi

# --- Generate mise.local.toml from template ---

template_file="${root}/.mise/local.toml.template"
if [ ! -f "$template_file" ]; then
  echo "Warning: ${template_file} not found, skipping"
else
  sed "s|{{WORKTREE_ID}}|0|g" "$template_file" > "${clone_dir}/mise.local.toml"
fi

# --- Ensure the shared gem volume exists for this Ruby version ---

ruby_version=$(cat "${clone_dir}/.ruby-version" 2>/dev/null | tr -d '[:space:]') || true
if [ -n "$ruby_version" ] && [ -n "${GEM_VOLUME_BASE:-}" ]; then
  ruby_slug=$(echo "$ruby_version" | tr '.' '_')
  gem_volume="${GEM_VOLUME_BASE}_ruby_${ruby_slug}"

  if ! docker volume inspect "$gem_volume" >/dev/null 2>&1; then
    echo "Creating shared gem volume: ${gem_volume}"
    docker volume create "$gem_volume"
  fi
fi

# Pre-create node_modules so Docker doesn't create it as root
mkdir -p "${clone_dir}/node_modules"

echo ""
echo "Repo initialized"
echo "  Repository:      ${clone_url}"
echo "  Directory:       ${clone_dir}"
echo "  Worktree ID:     0"
echo "  App port:        3000"
echo "  Neovim port:     7000"
echo "  RustFS API port: 9000"
echo "  RustFS UI port:  9100"
echo ""
echo "cd ${clone_dir} to get started"
