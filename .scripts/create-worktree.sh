#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run wt <branch-name|PR#|new-branch-name>}"

# --- Find a git worktree to run git commands from ---

source "$(dirname "$0")/lib.sh"
root=$(find_project_root)
git_dir=$(find_git_dir)

run_git() {
  git -C "$git_dir" "$@"
}

# --- Resolve branch name ---
if [[ "$input" =~ ^[0-9]+$ ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: 'gh' CLI is required for PR checkouts"
    echo "  Install: https://cli.github.com/"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated"
    echo "  Run: gh auth login"
    exit 1
  fi

  echo "Fetching PR #${input}..."
  branch=$(cd "$git_dir" && gh pr view "$input" --json headRefName -q .headRefName) || {
    echo "Error: PR #${input} not found"
    exit 1
  }
  run_git fetch origin "$branch"
else
  branch="$input"
  run_git fetch origin "$branch" 2>/dev/null || true
fi

# --- Sanitize for directory and compose project name ---

clean_name=$(echo "$branch" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/--*/-/g; s/^-//; s/-$//')
worktree_dir="${root}/${clean_name}"

if [ -d "$worktree_dir" ]; then
  echo "Worktree already exists: $worktree_dir"
  exit 1
fi

REGISTRY="${root}/ports.registry"
base_name=$(find_base_worktree_name)

if [ ! -f "$REGISTRY" ]; then
  echo "${base_name}:0" > "$REGISTRY"
fi

# Find the next available ID by incrementing the highest current one
max_id=0
while IFS=: read -r _name id; do
  [ "$id" -gt "$max_id" ] 2>/dev/null && max_id=$id
done < "$REGISTRY"
next_id=$((max_id + 1))

echo "${clean_name}:${next_id}" >> "$REGISTRY"

# --- Create worktree ---

if run_git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
  run_git worktree add "$worktree_dir" "$branch"
elif run_git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
  run_git worktree add "$worktree_dir" "$branch"
else
  base_branch=$(run_git symbolic-ref --short HEAD)
  echo "Branch '${branch}' not found locally or on remote."
  echo "Creating new branch based on ${base_branch}..."
  run_git worktree add -b "$branch" "$worktree_dir" "$base_branch"
fi

# --- Generate mise.local.toml from template ---

template_file="${root}/.mise/local.toml.template"
if [ ! -f "$template_file" ]; then
  echo "Warning: ${template_file} not found, skipping"
else
  sed "s|{{WORKTREE_ID}}|${next_id}|g" "$template_file" > "${worktree_dir}/mise.local.toml"
fi

# --- Ensure the shared gem volume exists for this Ruby version ---

ruby_version=$(cat "${worktree_dir}/.ruby-version" 2>/dev/null | tr -d '[:space:]')
if [ -n "$ruby_version" ] && [ -n "${GEM_VOLUME_BASE:-}" ]; then
  ruby_slug=$(echo "$ruby_version" | tr '.' '_')
  gem_volume="${GEM_VOLUME_BASE}_ruby_${ruby_slug}"

  if ! docker volume inspect "$gem_volume" >/dev/null 2>&1; then
    echo "Creating shared gem volume: ${gem_volume}"
    docker volume create "$gem_volume"
  fi
fi

# Pre-create node_modules so Docker doesn't create it as root when
# mounting the shared_node_modules volume over the bind-mounted worktree.
mkdir -p "${worktree_dir}/node_modules"

echo ""
echo "✓ Worktree created"
echo "  Branch:          ${branch}"
echo "  Directory:       ${worktree_dir}"
echo "  Worktree ID:     ${next_id}"
echo "  App port:        $((3000 + next_id))"
echo "  Neovim port:     $((7000 + next_id))"
echo "  RustFS API port: $((9000 + next_id))"
echo "  RustFS UI port:  $((9100 + next_id))"
echo ""
cd "${worktree_dir}"

mise install
mise trust -y
