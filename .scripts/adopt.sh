#!/usr/bin/env bash
set -euo pipefail
# Adopt an existing Rails checkout into this wrapper as the base worktree.
# Moves the checkout physically under the wrapper root (required: mise resolves
# config by physical path, so the base must live under the root to inherit the
# wrapper's .mise config + tasks), then leaves a backward symlink at the original
# location so the old path keeps working everywhere.
#
# Usage: .scripts/adopt.sh [-p <prefix>] [-b <base-name>] <path-to-existing-checkout>
#   -p <prefix>     Docker volume/network prefix (default: checkout folder name)
#   -b <base-name>  base worktree directory name (default: checkout folder name;
#                   set to your default branch, e.g. -b master, to match the
#                   tool's clone-time convention)

prefix=""; base_name=""
while getopts ":p:b:h" opt; do
  case "$opt" in
    p) prefix="$OPTARG" ;;
    b) base_name="$OPTARG" ;;
    h|*) echo "Usage: $0 [-p <prefix>] [-b <base-name>] <app-path>" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

app_in="${1:?Usage: $0 [-p <prefix>] [-b <base-name>] <app-path>}"
app_path="$(cd "$app_in" && pwd -P)"
[ -d "$app_path/.git" ] || { echo "Error: $app_path is not a git repo root" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
base="$(basename "$app_path")"
prefix="${prefix:-$base}"
base_name="${base_name:-$base}"
dest="$root/$base_name"

# --- Move checkout under the root + backward symlink at the original location ---
if [ -e "$dest" ] || [ -L "$dest" ]; then
  echo "Destination '$dest' already exists; skipping move/symlink"
else
  mv "$app_path" "$dest"
  ln -s "$dest" "$app_path"
  echo "Moved checkout to $dest; backward symlink left at $app_path"
fi

# --- Detect development DB name (best-effort; fallback to <prefix>_development) ---
dev_db="$(awk '/^[[:space:]]*development:/{f=1} f&&/database:/{sub(/.*database:[[:space:]]*/,"");gsub(/["'"'"' ]/,"");print;exit}' "$dest/config/database.yml" 2>/dev/null || true)"
case "$dev_db" in ''|*'<%'*|*'ENV'*) dev_db="${prefix}_development" ;; esac
echo "Using DEV_DB_NAME=$dev_db"

# --- Root mise.local.toml (git-ignored) ---
cat > "$root/mise.local.toml" <<EOF
[env]
PROJECT_PREFIX = "$prefix"
GEM_VOLUME_BASE = "${prefix}_shared_gems"
NODE_MODULES_VOLUME = "${prefix}_shared_node_modules"
DEV_DB_NAME = "$dev_db"
NVIM_CONFIG_DIR = "$HOME/.config/nvim"
EOF
echo "Wrote $root/mise.local.toml"

# --- Locally ignore the generated per-worktree mise.local.toml in the repo ---
excl="$dest/.git/info/exclude"
grep -qxF 'mise.local.toml' "$excl" 2>/dev/null || echo 'mise.local.toml' >> "$excl"

# --- Ports registry (base = ID 0) ---
if [ -f "$root/ports.registry" ]; then
  echo "ports.registry exists, leaving as-is"
else
  echo "$base_name:0" > "$root/ports.registry"
  echo "Wrote ports.registry ($base_name:0)"
fi

# --- Render the base worktree's mise.local.toml from the template (WORKTREE_ID=0) ---
tmpl="$root/.mise/local.toml.template"
if [ -f "$tmpl" ] && [ ! -f "$dest/mise.local.toml" ]; then
  sed 's|{{WORKTREE_ID}}|0|g' "$tmpl" > "$dest/mise.local.toml"
  echo "Rendered $dest/mise.local.toml (WORKTREE_ID=0)"
fi

mkdir -p "$dest/node_modules"

# --- External docker volumes ---
for vol in claude_config claude_bashhistory "${prefix}_shared_node_modules"; do
  docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
  echo "  volume $vol ready"
done

cat <<EOF

Adoption complete.
Next:
  cd $root && mise trust && mise install
  cd $dest && mise trust && mise install && mise run up
  App URL: http://$base_name.localhost
EOF
