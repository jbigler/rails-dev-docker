#!/usr/bin/env bash
# Promote one worktree's Claude plugin configuration to the shared default that
# new worktrees are seeded from.
#
# entrypoint-claude.sh gives every worktree its own known_marketplaces.json and
# installed_plugins.json, seeded once from ~/.claude/plugins and never resynced
# (see the comment there for why the files can't simply be shared). That makes
# the shared copy a frozen snapshot: marketplaces you add later in a worktree
# never reach a newly created one. This script pushes a worktree's copy back.
#
# Usage: promote-claude-plugins.sh <worktree-name> [--replace] [--reseed] [--yes]
#
#   --replace  Make the default exactly match the source worktree. The default
#              is to merge, which never drops a marketplace or plugin the shared
#              copy already has.
#   --reseed   Also overwrite every other already-migrated worktree with the new
#              default, discarding whatever they had. Without this the promotion
#              only affects worktrees created from now on.
#   --yes      Skip the confirmation prompt.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

# Paths as the containers see them. The files record absolute container paths,
# so every rewrite is between these two prefixes.
CONTAINER_HOME=/home/appuser

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

source_name=""
mode=merge
reseed=false
assume_yes=false

while [ $# -gt 0 ]; do
  case "$1" in
    --replace) mode=replace ;;
    --reseed)  reseed=true ;;
    --yes|-y)  assume_yes=true ;;
    -h|--help) usage 0 ;;
    -*)        echo "Unknown option: $1" >&2; usage ;;
    *)
      [ -n "$source_name" ] && { echo "Only one worktree can be promoted at a time" >&2; usage; }
      source_name="$1"
      ;;
  esac
  shift
done

[ -n "$source_name" ] || usage

root=$(find_project_root)
home_dir="$root/.docker-config/home"
shared_dir="$home_dir/.claude/plugins"
source_dir="$home_dir/.claude-worktrees/$source_name/plugins"

[ -d "$shared_dir" ] || { echo "No shared plugin directory at $shared_dir" >&2; exit 1; }

if [ ! -d "$source_dir" ]; then
  echo "No plugin directory for worktree '$source_name' at $source_dir" >&2
  exit 1
fi

# A worktree still on the pre-split whole-directory symlink has no config of its
# own — its files ARE the shared ones, so promoting it is a no-op that would
# only look like it did something.
if [ -L "$home_dir/.claude-worktrees/$source_name/plugins" ]; then
  echo "Worktree '$source_name' still links its whole plugins directory to the shared copy." >&2
  echo "It has no configuration of its own to promote. Start Claude in it once to migrate." >&2
  exit 1
fi

for record in known_marketplaces.json installed_plugins.json; do
  [ -f "$source_dir/$record" ] || { echo "Missing $source_dir/$record" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

source_prefix="$CONTAINER_HOME/.claude-worktrees/$source_name/plugins"
shared_prefix="$CONTAINER_HOME/.claude/plugins"

# Rewrite the source's paths to the shared prefix. Marketplace and cache
# directories are symlinked into the shared copy, so only the recorded strings
# change — every path still points at the same clone on disk.
rewrite() {
  sed "s|$1|$2|g" "$3"
}

rewrite "$source_prefix" "$shared_prefix" "$source_dir/known_marketplaces.json" > "$work/src-marketplaces.json"

# Project-scoped install records are dropped rather than promoted. They key on
# a worktree's /app-<slug> mount path, which is unique per worktree, so in a
# seed they are dead on arrival — and stale ones are what make Claude report a
# plugin as "not cached" despite an intact cache.
rewrite "$source_prefix" "$shared_prefix" "$source_dir/installed_plugins.json" \
  | jq '
      .plugins |= with_entries(.value |= map(select(.scope != "project")))
      | .plugins |= with_entries(select(.value | length > 0))
    ' > "$work/src-plugins.json"

if [ "$mode" = replace ]; then
  cp "$work/src-marketplaces.json" "$work/new-marketplaces.json"
  cp "$work/src-plugins.json" "$work/new-plugins.json"
else
  # The source wins on any key both sides have; keys only the shared copy has
  # survive. '*' recurses into objects, so a plugin's array of install records
  # is taken wholesale from whichever side supplies it rather than concatenated.
  jq -s '.[0] * .[1]' "$shared_dir/known_marketplaces.json" "$work/src-marketplaces.json" \
    > "$work/new-marketplaces.json"
  jq -s '.[0] * .[1]' "$shared_dir/installed_plugins.json" "$work/src-plugins.json" \
    > "$work/new-plugins.json"
fi

keys_of() { jq -r "$2 | keys[]" "$1" | sort; }

echo "Promoting $source_name to the shared default ($mode)"
echo

report() {
  local label="$1" old="$2" new="$3" filter="$4"
  local added removed
  added=$(comm -13 <(keys_of "$old" "$filter") <(keys_of "$new" "$filter") | tr '\n' ' ')
  removed=$(comm -23 <(keys_of "$old" "$filter") <(keys_of "$new" "$filter") | tr '\n' ' ')
  echo "$label:"
  echo "  added:   ${added:-none}"
  echo "  removed: ${removed:-none}"
}

report "Marketplaces" "$shared_dir/known_marketplaces.json" "$work/new-marketplaces.json" "."
report "Plugins" "$shared_dir/installed_plugins.json" "$work/new-plugins.json" ".plugins"

dropped=$(jq '[.plugins[][] | select(.scope == "project")] | length' "$source_dir/installed_plugins.json")
echo
echo "Project-scoped install records dropped from the seed: $dropped"

if [ "$mode" = merge ]; then
  kept=$(comm -23 <(keys_of "$shared_dir/known_marketplaces.json" ".") \
                  <(keys_of "$work/src-marketplaces.json" ".") | tr '\n' ' ')
  if [ -n "$kept" ]; then
    echo "Kept from the current default (absent in $source_name): $kept"
    echo "Use --replace to drop them instead."
  fi
fi

if [ "$reseed" = true ]; then
  echo
  echo "--reseed will also overwrite these worktrees with the new default:"
  for d in "$home_dir"/.claude-worktrees/*/; do
    name=$(basename "$d")
    [ "$name" = "$source_name" ] && continue
    [ -d "$d/plugins" ] && [ ! -L "$d/plugins" ] && echo "  $name"
  done
fi

if [ "$assume_yes" != true ]; then
  echo
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

stamp=$(date +%Y%m%d-%H%M%S)

install_record() {
  local new="$1" dest="$2"
  [ -f "$dest" ] && cp "$dest" "$dest.bak-$stamp"
  cp "$new" "$dest"
}

install_record "$work/new-marketplaces.json" "$shared_dir/known_marketplaces.json"
install_record "$work/new-plugins.json" "$shared_dir/installed_plugins.json"
echo "Shared default updated (previous copies kept as *.bak-$stamp)."

if [ "$reseed" = true ]; then
  for d in "$home_dir"/.claude-worktrees/*/; do
    name=$(basename "$d")
    [ "$name" = "$source_name" ] && continue
    [ -d "$d/plugins" ] && [ ! -L "$d/plugins" ] || continue

    target_prefix="$CONTAINER_HOME/.claude-worktrees/$name/plugins"
    for record in known_marketplaces.json installed_plugins.json; do
      rewrite "$shared_prefix" "$target_prefix" "$shared_dir/$record" > "$work/reseed.json"
      install_record "$work/reseed.json" "$d/plugins/$record"
    done
    echo "Reseeded $name"
  done
fi

echo
echo "Restart any running Claude session to pick this up."
