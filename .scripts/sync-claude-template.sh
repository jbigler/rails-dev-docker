#!/usr/bin/env bash
# Sync the Claude config set between a worktree's home (.home/<slug>) and the
# template (.docker-config/home-template) that seeds new worktrees.
#
# Usage:
#   sync-claude-template.sh promote <worktree> [--replace] [--yes]
#   sync-claude-template.sh apply <worktree>|--all [--yes]
#
#   promote  Push the worktree's config set to the template. Plugin records
#            merge into the template's by default; --replace overwrites them.
#            Project-scoped install records are stripped — they key on the
#            per-worktree /app-<slug> path, so they are dead in a seed.
#   apply    Copy the template's config set onto the worktree home(s).
#            Writes only the config set: state (projects/, history, sessions)
#            and .credentials.json are never touched. .claude.json is merged
#            (template keys win; the worktree's projects/trust entries
#            survive).
#
# The config set: .claude/{agents,hooks,skills}, .claude/settings.json,
# .claude/keybindings.json, .claude/statusline-command.sh,
# .claude/CLAUDE.local.md, .claude/plugins/{known_marketplaces,
# installed_plugins}.json, and the home-root .claude.json (sanitized: the
# projects key is stripped).
set -euo pipefail

source "$(dirname "$0")/lib.sh"

CONFIG_DIRS=(agents hooks skills)
CONFIG_FILES=(settings.json keybindings.json statusline-command.sh CLAUDE.local.md)
PLUGIN_RECORDS=(known_marketplaces.json installed_plugins.json)

usage() {
  sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

root=$(find_project_root)
template="$root/.docker-config/home-template"
stamp=$(date +%Y%m%d-%H%M%S)

case "${1:-}" in -h|--help) usage 0 ;; esac

mode="${1:-}"
[ -n "$mode" ] && shift || usage

target=""
replace=false
assume_yes=false
apply_all=false

while [ $# -gt 0 ]; do
  case "$1" in
    --replace) replace=true ;;
    --all)     apply_all=true ;;
    --yes|-y)  assume_yes=true ;;
    -h|--help) usage 0 ;;
    -*)        echo "Unknown option: $1" >&2; usage ;;
    *)
      [ -n "$target" ] && { echo "Only one worktree at a time" >&2; usage; }
      target="$1"
      ;;
  esac
  shift
done

confirm() {
  [ "$assume_yes" = true ] && return 0
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
}

# Replace $2 with $1, keeping a timestamped backup of $2. Works for files
# and directories; missing sources are skipped silently.
backup_replace() {
  local src="$1" dest="$2"
  [ -e "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"
  [ -e "$dest" ] && mv "$dest" "$dest.bak-$stamp"
  cp -a "$src" "$dest"
}

# Drop project-scoped install records: they key on the per-worktree
# /app-<slug> path and are what makes Claude report "not cached" from a seed.
strip_project_scope() {
  jq '
    .plugins |= with_entries(.value |= map(select(.scope != "project")))
    | .plugins |= with_entries(select(.value | length > 0))
  ' "$1"
}

sanitize_claude_json() {
  jq 'del(.projects)' "$1"
}

case "$mode" in

promote)
  [ -n "$target" ] || usage
  src="$root/.home/$target/.claude"
  src_json="$root/.home/$target/.claude.json"
  [ -d "$src" ] || { echo "No Claude config at $src" >&2; exit 1; }

  echo "Promoting $target to the template ($([ "$replace" = true ] && echo replace || echo merge) for plugin records)"
  confirm
  mkdir -p "$template/.claude/plugins"

  for d in "${CONFIG_DIRS[@]}"; do
    backup_replace "$src/$d" "$template/.claude/$d"
  done
  for f in "${CONFIG_FILES[@]}"; do
    backup_replace "$src/$f" "$template/.claude/$f"
  done

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  for record in "${PLUGIN_RECORDS[@]}"; do
    [ -f "$src/plugins/$record" ] || { echo "warn: missing $src/plugins/$record" >&2; continue; }
    if [ "$record" = installed_plugins.json ]; then
      strip_project_scope "$src/plugins/$record" > "$work/$record"
    else
      cp "$src/plugins/$record" "$work/$record"
    fi
    dest="$template/.claude/plugins/$record"
    if [ "$replace" = false ] && [ -f "$dest" ]; then
      # Source wins on shared keys; keys only the template has survive.
      jq -s '.[0] * .[1]' "$dest" "$work/$record" > "$work/merged-$record"
      mv "$work/merged-$record" "$work/$record"
    fi
    backup_replace "$work/$record" "$dest"
  done

  if [ -f "$src_json" ]; then
    sanitize_claude_json "$src_json" > "$work/claude.json"
    backup_replace "$work/claude.json" "$template/.claude.json"
  fi

  echo "Template updated (previous copies kept as *.bak-$stamp)."
  ;;

apply)
  if [ "$apply_all" = true ]; then
    [ -z "$target" ] || { echo "--all and a worktree name are mutually exclusive" >&2; usage; }
    set -- "$root"/.home/*/
  else
    [ -n "$target" ] || usage
    set -- "$root/.home/$target/"
  fi
  [ -d "$template/.claude" ] || { echo "No template Claude config at $template/.claude" >&2; exit 1; }

  echo "Applying the template config set to:"
  for dir in "$@"; do
    [ -d "$dir" ] && echo "  $(basename "$dir")"
  done
  echo "State (projects/, history, sessions) and .credentials.json stay untouched."
  confirm

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  for dir in "$@"; do
    [ -d "$dir" ] || { echo "warn: no home at $dir" >&2; continue; }
    name=$(basename "$dir")
    dest="$dir.claude"
    mkdir -p "$dest/plugins"

    for d in "${CONFIG_DIRS[@]}"; do
      backup_replace "$template/.claude/$d" "$dest/$d"
    done
    for f in "${CONFIG_FILES[@]}"; do
      backup_replace "$template/.claude/$f" "$dest/$f"
    done
    for record in "${PLUGIN_RECORDS[@]}"; do
      backup_replace "$template/.claude/plugins/$record" "$dest/plugins/$record"
    done

    if [ -f "$template/.claude.json" ]; then
      if [ -f "$dir.claude.json" ]; then
        # Template keys win; the worktree's projects/trust entries survive
        # because the sanitized template has no projects key.
        jq -s '.[0] * .[1]' "$dir.claude.json" "$template/.claude.json" > "$work/claude.json"
        backup_replace "$work/claude.json" "$dir.claude.json"
      else
        cp "$template/.claude.json" "$dir.claude.json"
      fi
    fi
    echo "Applied to $name"
  done
  ;;

*)
  usage
  ;;
esac

echo
echo "Restart any running Claude session to pick this up."
