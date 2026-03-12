#!/usr/bin/env bash
set -euo pipefail

input="${1:?Usage: mise run wt <branch-name|PR#>}"

# --- Find a git worktree to run git commands from ---

source "$(dirname "$0")/lib.sh"
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
worktree_dir="${PWD}/${clean_name}"

if [ -d "$worktree_dir" ]; then
  echo "Worktree already exists: $worktree_dir"
  exit 1
fi

REGISTRY="${PWD}/ports.registry"

if [ ! -f "$REGISTRY" ]; then
  echo "master:3000:7000:9000:9100" > "$REGISTRY"
fi

next_port_in_column() {
  local col=$1
  local base=$2
  local max=$base
  while IFS=: read -r name p1 p2 p3 p4; do
    case $col in
      1) p=$p1 ;;
      2) p=$p2 ;;
      3) p=$p3 ;;
      4) p=$p4 ;;
    esac
    [ "$p" -gt "$max" ] 2>/dev/null && max=$p
  done < "$REGISTRY"
  echo $((max + 1))
}

app_port=$(next_port_in_column 1 3000)
nvim_port=$(next_port_in_column 2 7000)
rustfs_api_port=$(next_port_in_column 3 9000)
rustfs_ui_port=$(next_port_in_column 4 9100)

echo "${clean_name}:${app_port}:${nvim_port}:${rustfs_api_port}:${rustfs_ui_port}" >> "$REGISTRY"

# --- Create worktree ---

if run_git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
  run_git worktree add "$worktree_dir" "$branch"
elif run_git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
  run_git worktree add "$worktree_dir" "$branch"
else
  run_git worktree add -b "$branch" "$worktree_dir"
fi

# --- Generate mise.local.toml from template ---

template_file="${PWD}/mise.local.toml.template"
if [ ! -f "$template_file" ]; then
  echo "Warning: ${template_file} not found, skipping"
else
  sed \
    -e "s|{{RUBY_DEBUG_PORT}}|3${app_port}|g" \
    -e "s|{{APP_PORT}}|${app_port}|g" \
    -e "s|{{NVIM_PORT}}|${nvim_port}|g" \
    -e "s|{{RUSTFS_API_PORT}}|${rustfs_api_port}|g" \
    -e "s|{{RUSTFS_UI_PORT}}|${rustfs_ui_port}|g" \
    "$template_file" \
    > "${worktree_dir}/mise.local.toml"
fi

echo ""
echo "✓ Worktree created"
echo "  Branch:          ${branch}"
echo "  Directory:       ${worktree_dir}"
echo "  App port:        ${app_port}"
echo "  Neovim port:     ${nvim_port}"
echo "  RustFS API port: ${rustfs_api_port}"
echo "  RustFS UI port:  ${rustfs_ui_port}"
echo ""
cd "${worktree_dir}"

mise install
mise trust -y
