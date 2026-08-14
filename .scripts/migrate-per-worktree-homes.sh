#!/usr/bin/env bash
# One-time migration from the shared .docker-config/home to per-worktree
# homes under .home/, plus template build and cache-volume seeding.
# Idempotent per target: anything that already exists is skipped, so a
# partial run can be re-run safely. The old home is left untouched; delete
# its contents by hand once the new layout is confirmed working.
#
# Usage: migrate-per-worktree-homes.sh [--yes]
# Requires: PROJECT_PREFIX in the environment (mise provides it; or set it).
set -euo pipefail

source "$(dirname "$0")/lib.sh"

root=$(find_project_root)
old="$root/.docker-config/home"
template="$root/.docker-config/home-template"

: "${PROJECT_PREFIX:?PROJECT_PREFIX must be set (run under mise or export it)}"

[ -d "$old" ] || { echo "No shared home at $old — nothing to migrate" >&2; exit 1; }

if docker ps --format '{{.Names}}' | grep -q "^${PROJECT_PREFIX}-"; then
  echo "Containers with prefix ${PROJECT_PREFIX}- are running. Stop every" >&2
  echo "worktree stack first (mise run down in each worktree)." >&2
  exit 1
fi

if [ "${1:-}" != "--yes" ]; then
  echo "This will:"
  echo "  - build $template from $old"
  echo "  - create .home/<slug> for master and every registered worktree"
  echo "  - seed the ${PROJECT_PREFIX}_* cache volumes from the old home"
  echo "The old home is not modified."
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

uid=$(id -u); gid=$(id -g)

# --- 1. Build the template ---------------------------------------------
echo "== Building template"
mkdir -p "$template"
for item in .zshrc .zimrc .zim .gitconfig .irbrc; do
  if [ -e "$old/$item" ] && [ ! -e "$template/$item" ]; then
    cp -a "$old/$item" "$template/$item"
    echo "  template: $item"
  fi
done
# Mount-point and skeleton directories (bind/volume mounts must land on
# appuser-owned dirs).
mkdir -p "$template/.ssh" "$template/.npm" "$template/.npm-global" \
  "$template/.config/nvim" "$template/.config/git" \
  "$template/.local/share/nvim" "$template/.cache/ms-playwright" \
  "$template/.claude/plugins/cache" "$template/.claude/plugins/marketplaces"

# Claude config set.
for d in agents hooks skills; do
  if [ -d "$old/.claude/$d" ] && [ ! -e "$template/.claude/$d" ]; then
    cp -a "$old/.claude/$d" "$template/.claude/$d"
    echo "  template: .claude/$d"
  fi
done
for f in settings.json keybindings.json statusline-command.sh CLAUDE.local.md; do
  if [ -f "$old/.claude/$f" ] && [ ! -e "$template/.claude/$f" ]; then
    cp -a "$old/.claude/$f" "$template/.claude/$f"
    echo "  template: .claude/$f"
  fi
done
if [ -f "$old/.claude/plugins/known_marketplaces.json" ] && [ ! -f "$template/.claude/plugins/known_marketplaces.json" ]; then
  cp "$old/.claude/plugins/known_marketplaces.json" "$template/.claude/plugins/known_marketplaces.json"
fi
if [ -f "$old/.claude/plugins/installed_plugins.json" ] && [ ! -f "$template/.claude/plugins/installed_plugins.json" ]; then
  jq '
    .plugins |= with_entries(.value |= map(select(.scope != "project")))
    | .plugins |= with_entries(select(.value | length > 0))
  ' "$old/.claude/plugins/installed_plugins.json" > "$template/.claude/plugins/installed_plugins.json"
fi
if [ ! -f "$template/.claude.json" ]; then
  claude_json_src=""
  if [ -f "$old/.claude-worktrees/master/.claude.json" ]; then
    claude_json_src="$old/.claude-worktrees/master/.claude.json"
  elif [ -f "$old/.claude.json" ]; then
    claude_json_src="$old/.claude.json"
  fi
  if [ -n "$claude_json_src" ]; then
    jq 'del(.projects)' "$claude_json_src" > "$template/.claude.json"
  fi
fi

# --- 2. Per-worktree homes ----------------------------------------------
slugs="master"
if [ -f "$root/ports.registry" ]; then
  slugs="$slugs $(cut -d: -f1 "$root/ports.registry" | tr '\n' ' ')"
fi

for slug in $slugs; do
  home_dir="$root/.home/$slug"
  if [ -d "$home_dir" ]; then
    echo "== $slug: home exists, skipping"
    continue
  fi
  echo "== $slug: building home"
  mkdir -p "$home_dir"
  cp -a "$template/." "$home_dir/"

  # Carry over the worktree's Claude state (sessions, credentials, settings).
  wt_claude="$old/.claude-worktrees/$slug"
  if [ -d "$wt_claude" ]; then
    # The legacy per-worktree dirs symlink agents/hooks and plugins/{cache,
    # data,marketplaces} into the shared home, and cp -a cannot overwrite the
    # template's real directories with those symlinks — clear the destination
    # counterparts first; the blocks below then replace the copied links.
    find "$wt_claude" -maxdepth 2 -type l | while IFS= read -r link; do
      rel="${link#"$wt_claude"/}"
      rm -rf "$home_dir/.claude/$rel"
    done
    cp -a "$wt_claude/." "$home_dir/.claude/"
    # The old per-worktree dirs symlinked agents/hooks and the plugin
    # cache/data/marketplaces into the shared home; those links are dead in
    # the new layout. Replace them with template copies or plain dirs (the
    # cache and marketplaces get volume-mounted over anyway).
    for d in agents hooks; do
      if [ -L "$home_dir/.claude/$d" ]; then
        rm "$home_dir/.claude/$d"
        [ -d "$template/.claude/$d" ] && cp -a "$template/.claude/$d" "$home_dir/.claude/$d"
      fi
    done
    for d in cache marketplaces; do
      if [ -L "$home_dir/.claude/plugins/$d" ]; then
        rm "$home_dir/.claude/plugins/$d"
        mkdir -p "$home_dir/.claude/plugins/$d"
      fi
    done
    # plugins/data was shared but is NOT a volume in the new design — each
    # worktree gets its own copy of the shared content.
    if [ -L "$home_dir/.claude/plugins/data" ]; then
      rm "$home_dir/.claude/plugins/data"
      if [ -d "$old/.claude/plugins/data" ]; then
        cp -a "$old/.claude/plugins/data" "$home_dir/.claude/plugins/data"
      else
        mkdir -p "$home_dir/.claude/plugins/data"
      fi
    fi
    # Plugin records point at ~/.claude-worktrees/<slug>/plugins; the config
    # dir is plain ~/.claude now.
    for record in known_marketplaces.json installed_plugins.json; do
      if [ -f "$home_dir/.claude/plugins/$record" ]; then
        sed -i "s|/home/appuser/.claude-worktrees/$slug/plugins|/home/appuser/.claude/plugins|g" \
          "$home_dir/.claude/plugins/$record"
      fi
    done
    echo "  carried over .claude-worktrees/$slug"

    # Claude reads ~/.claude.json (home root) when CLAUDE_CONFIG_DIR is unset;
    # the legacy split kept it inside the config dir. Promote the live copy.
    if [ -f "$home_dir/.claude/.claude.json" ]; then
      mv "$home_dir/.claude/.claude.json" "$home_dir/.claude.json"
    fi
  fi

  # Histories are nice-to-keep, not required.
  for h in .zhistory .irb_history .psql_history; do
    [ -f "$old/$h" ] && cp -a "$old/$h" "$home_dir/$h"
  done
done

# --- 3. Seed the cache volumes ------------------------------------------
seed_volume() {
  local vol="$1" src="$2"
  local name="${PROJECT_PREFIX}_${vol}"
  if ! docker volume inspect "$name" >/dev/null 2>&1; then
    docker volume create "$name" >/dev/null
  fi
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    echo "== Seeding volume $name from ${src#"$root/"}"
    docker run --rm -v "$name":/dest -v "$src":/src:ro alpine \
      sh -c "cp -a /src/. /dest/ && chown -R $uid:$gid /dest"
  else
    docker run --rm -v "$name":/dest alpine chown "$uid:$gid" /dest
  fi
}

seed_volume npm_cache                    "$old/.npm"
seed_volume npm_global                   "$old/.npm-global"
seed_volume nvim_share                   "$old/.local/share/nvim"
seed_volume playwright_browsers          "$old/.cache/ms-playwright"
seed_volume claude_plugins_cache         "$old/.claude/plugins/cache"
seed_volume claude_plugins_marketplaces  "$old/.claude/plugins/marketplaces"

echo
echo "Migration done. The old home at .docker-config/home is untouched."
echo "After you confirm every worktree works: rm -rf .docker-config/home"
