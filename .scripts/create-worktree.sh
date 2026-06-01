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

clean_name=$(sanitize_worktree_name "$branch")
worktree_dir="${root}/${clean_name}"

# Refuse if this exact branch is already checked out in a worktree —
# that's a retry, not a name collision.
if run_git worktree list --porcelain | awk '/^branch / {print $2}' | grep -qx "refs/heads/${branch}"; then
  echo "Branch '${branch}' is already checked out:"
  run_git worktree list | grep -F "[${branch}]" || true
  exit 1
fi

# Different branch, but its sanitized name collides with an existing
# worktree directory. Append a short deterministic hash of the full
# branch name so both can coexist.
if [ -d "$worktree_dir" ]; then
  hash=$(printf '%s' "$branch" | sha1sum | cut -c1-4)
  base_len=$((WORKTREE_NAME_MAX_LEN - 5))
  short_base=$(printf '%s' "$clean_name" | cut -c1-"$base_len" | sed 's/-$//')
  clean_name="${short_base}-${hash}"
  worktree_dir="${root}/${clean_name}"

  if [ -d "$worktree_dir" ]; then
    echo "Name collision unresolvable — '${worktree_dir}' also exists"
    exit 1
  fi
  echo "Name collision — using hash-suffixed slug: ${clean_name}"
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

# Pre-create node_modules so Docker doesn't create it as root when
# mounting the shared_node_modules volume over the bind-mounted worktree.
mkdir -p "${worktree_dir}/node_modules"

# --- Seed untracked files (secrets/env) from the base worktree ---
SEED_MANIFEST="${root}/.docker-config/worktree-seed.txt"
base_dir="${root}/$(find_base_worktree_name)"
if [ -f "$SEED_MANIFEST" ]; then
  echo "Seeding untracked files from ${base_dir}..."
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|\#*) continue ;; esac
    matched=0
    for src in "$base_dir"/$pattern; do
      [ -e "$src" ] || continue
      matched=1
      rel="${src#"$base_dir"/}"
      dest="${worktree_dir}/${rel}"
      mkdir -p "$(dirname "$dest")"
      cp -p "$src" "$dest"
      echo "  seeded: ${rel}"
    done
    [ "$matched" -eq 0 ] && echo "  warn: no match for seed pattern '${pattern}'" >&2
  done < "$SEED_MANIFEST"
fi

echo ""
echo "✓ Worktree created"
echo "  Branch:          ${branch}"
echo "  Directory:       ${worktree_dir}"
echo "  Worktree ID:     ${next_id}"
echo "  App URL:         http://${clean_name}.localhost"
echo "  RustFS API URL:  http://s3.${clean_name}.localhost"
echo "  RustFS UI URL:   http://s3-ui.${clean_name}.localhost"
echo "  Neovim port:     $((17000 + next_id))"
echo "  Ruby debug port: $((33000 + next_id))"
echo ""
echo "Note: 'mise run up' auto-starts the proxy; if running compose directly,"
echo "      run 'mise run proxy:up' first."
echo ""
cd "${worktree_dir}"

# Trust before install — mise refuses to read an untrusted config, so trusting
# must come first or `mise install` fails on the freshly generated mise.local.toml.
mise trust -y
mise install
