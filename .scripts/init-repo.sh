#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run init <user/repo | git-url>}"

source "$(dirname "$0")/lib.sh"
root=$(find_project_root)

# A manual clone of the wrapper has no root mise.local.toml, which leaves
# PROJECT_PREFIX as the literal "default". bootstrap.sh writes it before
# calling us, so this is a no-op on that path.
"$(dirname "$0")/local-config.sh"

# --- Resolve clone URL ---

if [[ "$input" =~ ^https?:// || "$input" =~ ^git@ ]]; then
  clone_url="$input"
elif [[ "$input" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  clone_url="https://github.com/${input}.git"
else
  echo "Error: unrecognized format '${input}'"
  echo "  Expected: user/repo  or  https://github.com/user/repo.git"
  exit 1
fi

# --- Detect the remote's default branch and use it as the folder name ---

default_branch=$(git ls-remote --symref "$clone_url" HEAD 2>/dev/null \
  | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')

if [ -z "$default_branch" ]; then
  echo "Error: could not detect default branch for ${clone_url}"
  exit 1
fi

branch_slug=$(sanitize_worktree_name "$default_branch")
clone_dir="${root}/${branch_slug}"

if [ -d "$clone_dir" ]; then
  echo "Error: directory already exists: ${clone_dir}"
  exit 1
fi

# --- Clone ---

echo "Cloning ${clone_url} (branch ${default_branch}) into ${clone_dir}..."
git clone "$clone_url" "$clone_dir"

# --- Locally ignore mise.local.toml in the cloned repo ---

exclude_file="${clone_dir}/.git/info/exclude"
if [ -f "$exclude_file" ] && ! grep -qxF 'mise.local.toml' "$exclude_file"; then
  echo 'mise.local.toml' >> "$exclude_file"
fi

# --- Register as base worktree (ID 0) in ports registry ---

REGISTRY="${root}/ports.registry"
if [ -f "$REGISTRY" ]; then
  echo "Warning: ${REGISTRY} already exists, skipping registration"
else
  echo "${branch_slug}:0" > "$REGISTRY"
fi

# --- Generate mise.local.toml from template ---

template_file="${root}/.mise/local.toml.template"
if [ ! -f "$template_file" ]; then
  echo "Warning: ${template_file} not found, skipping"
else
  sed "s|{{WORKTREE_ID}}|0|g" "$template_file" > "${clone_dir}/mise.local.toml"
fi

# Pre-create node_modules so Docker doesn't create it as root
mkdir -p "${clone_dir}/node_modules"

echo ""
echo "Repo initialized"
echo "  Repository:      ${clone_url}"
echo "  Directory:       ${clone_dir}"
echo "  Worktree ID:     0"
echo "  App URL:         http://${branch_slug}.localhost"
echo "  RustFS API URL:  http://s3.${branch_slug}.localhost"
echo "  RustFS UI URL:   http://s3-ui.${branch_slug}.localhost"
echo "  Neovim port:     7000"
echo ""
echo "Next, from inside ${clone_dir}:"
echo "  mise trust -y && mise install"
echo "  mise run podman:build      # generates the unit env file, then builds"
echo "  mise run podman:up"
echo "  Ruby debug port: 33000"
echo ""
echo "cd ${clone_dir} to get started"
