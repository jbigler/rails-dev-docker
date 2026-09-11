# Per-Worktree Container Homes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single shared `/home/appuser` bind mount with one home directory per worktree (`.home/<slug>/`), seeded from a template, with heavy caches shared through external Docker volumes.

**Architecture:** The orchestration repo root gains `.home/` (per-worktree homes, gitignored) and `.docker-config/home-template/` (untracked skeleton). Compose mounts `.home/${CURRENT_WORKTREE_NAME}` as `/home/appuser` and mounts six new external volumes for caches. Worktree lifecycle scripts seed and remove homes. The claude entrypoint loses the `CLAUDE_CONFIG_DIR` workaround. `promote-claude-plugins.sh` becomes `sync-claude-template.sh` with `promote` and `apply` modes.

**Tech Stack:** Docker Compose, bash, mise tasks, jq.

**Spec:** `.docker-config/docs/specs/2026-08-14-per-worktree-homes-design.md`

## Global Constraints

- This is the orchestration repo (`filial-rails-core`), not the Rails app. No Ruby/Rails/Node code here — only bash, TOML, YAML.
- Work on `main` directly (repo convention for orchestration changes). Commit after each task.
- Never run `git worktree prune` or `git worktree remove` (see AGENTS.md Gotchas).
- Shell scripts must pass `bash -n <file>` (syntax check) before commit.
- All `.scripts/*.sh` follow the existing style: `set -euo pipefail`, `source lib.sh`, comments explain constraints not mechanics.
- External volume names: `${PROJECT_PREFIX}_npm_cache`, `${PROJECT_PREFIX}_npm_global`, `${PROJECT_PREFIX}_nvim_share`, `${PROJECT_PREFIX}_playwright_browsers`, `${PROJECT_PREFIX}_claude_plugins_cache`, `${PROJECT_PREFIX}_claude_plugins_marketplaces`.
- The Claude config set (used by Tasks 6–8): `.claude/agents/`, `.claude/hooks/`, `.claude/skills/`, `.claude/settings.json`, `.claude/keybindings.json`, `.claude/statusline-command.sh`, `.claude/CLAUDE.local.md`, `.claude/plugins/known_marketplaces.json`, `.claude/plugins/installed_plugins.json`, home-root `.claude.json` (sanitized = `jq 'del(.projects)'`).
- Do NOT delete or move `.docker-config/home` (the live shared home) in Tasks 1–8. Only Task 9 (migration, with stacks down) touches it, and even then it is left in place until the user confirms the new layout works.

---

### Task 1: Gitignore rules and template placeholder

**Files:**
- Modify: `.gitignore`
- Create: `.docker-config/home-template/.gitkeep` (via `git mv`)

**Interfaces:**
- Produces: `.docker-config/home-template/` exists as a tracked-placeholder directory; `.home/` is ignored by the existing `/*` rule (verify, don't add a rule).

- [ ] **Step 1: Update `.gitignore`**

Replace this block:

```gitignore
# Include the docker-config directory and its contents (except for the home,
# db-dumps and status directories)
!/.docker-config/
/.docker-config/home/*
/.docker-config/home/.*
!/.docker-config/home/.gitkeep
```

with:

```gitignore
# Include the docker-config directory and its contents (except for the
# home-template, db-dumps and status directories)
!/.docker-config/
/.docker-config/home-template/*
/.docker-config/home-template/.*
!/.docker-config/home-template/.gitkeep
```

- [ ] **Step 2: Move the tracked placeholder**

```bash
mkdir -p .docker-config/home-template
git mv .docker-config/home/.gitkeep .docker-config/home-template/.gitkeep
```

Note: `.docker-config/home/` and its contents stay on disk (they are live mounts); only the tracked placeholder moves.

- [ ] **Step 3: Verify ignore behavior**

```bash
touch .docker-config/home-template/probe .home_probe_dir 2>/dev/null; mkdir -p .home/probe
git status --porcelain | grep -E 'home-template/probe|\.home/' && echo "FAIL: not ignored" || echo "OK: ignored"
rm -rf .docker-config/home-template/probe .home .home_probe_dir
```

Expected: `OK: ignored` (git must not list either probe).

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "Point home gitignore rules at home-template"
```

---

### Task 2: Compose changes

**Files:**
- Modify: `.docker-config/compose.yml`

**Interfaces:**
- Consumes: nothing from other tasks (bind source `.home/<slug>` may not exist yet; `docker compose config` does not require it).
- Produces: services mount `../.home/${CURRENT_WORKTREE_NAME}` as `/home/appuser`; six external volumes with the names from Global Constraints; `CLAUDE_CONFIG_DIR` gone.

- [ ] **Step 1: Change the home bind mount in all three services**

In the `rails` service volumes (currently `- ../.docker-config/home:/home/appuser`), in `nvim` (same string), and in `claude` (same string), replace each with:

```yaml
      - ../.home/${CURRENT_WORKTREE_NAME}:/home/appuser
```

- [ ] **Step 2: Add cache volume mounts per service**

`rails` service — add to `volumes:`:

```yaml
      - npm_cache:/home/appuser/.npm
      - npm_global:/home/appuser/.npm-global
      - playwright_browsers:/home/appuser/.cache/ms-playwright
```

`nvim` service — add to `volumes:`:

```yaml
      - npm_cache:/home/appuser/.npm
      - npm_global:/home/appuser/.npm-global
      - nvim_share:/home/appuser/.local/share/nvim
```

`claude` service — add to `volumes:`:

```yaml
      - npm_cache:/home/appuser/.npm
      - npm_global:/home/appuser/.npm-global
      - claude_plugins_cache:/home/appuser/.claude/plugins/cache
      - claude_plugins_marketplaces:/home/appuser/.claude/plugins/marketplaces
```

- [ ] **Step 3: Remove `CLAUDE_CONFIG_DIR` and stale comments**

In the `claude` service `environment:`, delete the `CLAUDE_CONFIG_DIR` line and its comment block:

```yaml
      # Per-worktree, not the shared ~/.claude: Claude caches credentials in
      # memory and the OAuth refresh rotates the refresh token, so containers
      # sharing one .credentials.json invalidate each other and force a daily
      # re-login. The entrypoint symlinks the genuinely global pieces back.
      CLAUDE_CONFIG_DIR: "/home/appuser/.claude-worktrees/${CURRENT_WORKTREE_NAME}"
```

Update the comment above the claude service's `/app-${CURRENT_WORKTREE_NAME}` mount (it currently justifies itself with "the home dir is shared by every worktree's claude container"). Replace the comment with:

```yaml
      # Worktree-specific mount point: kept so host paths differ per worktree
      # in prompts/logs even though homes are per-worktree now.
```

Update the `node_modules` volume comment (currently ends with "Installs stay fast via the npm cache in the shared /home/appuser bind mount (~/.npm)."). Replace that final sentence with:

```
  # Installs stay fast via the shared npm_cache volume (~/.npm).
```

- [ ] **Step 4: Replace the volumes block**

Delete the dead `home:` entry and add the six external volumes. The top-level `volumes:` block becomes:

```yaml
volumes:
  db_data:
  rustfs_data:
  # Per-worktree (compose prefixes the project name): a single volume shared
  # across worktrees let diverging lockfiles clobber each other and concurrent
  # boots race in `npm install`. Installs stay fast via the shared npm_cache
  # volume (~/.npm).
  node_modules:
  shared_gems:
    external: true
    name: ${GEM_VOLUME:-shared_gems}
  # Cross-worktree cache/install-state volumes; created and chowned by the
  # mise `up` task (a fresh named volume mounts root-owned, and copy-from-image
  # initialization does not work under a bind-mounted home).
  npm_cache:
    external: true
    name: ${PROJECT_PREFIX}_npm_cache
  npm_global:
    external: true
    name: ${PROJECT_PREFIX}_npm_global
  nvim_share:
    external: true
    name: ${PROJECT_PREFIX}_nvim_share
  playwright_browsers:
    external: true
    name: ${PROJECT_PREFIX}_playwright_browsers
  claude_plugins_cache:
    external: true
    name: ${PROJECT_PREFIX}_claude_plugins_cache
  claude_plugins_marketplaces:
    external: true
    name: ${PROJECT_PREFIX}_claude_plugins_marketplaces
```

- [ ] **Step 5: Verify the compose file renders**

```bash
(cd master && mise exec -- docker compose config --quiet) && echo RENDER_OK
```

Expected: `RENDER_OK`. If `mise exec` fails because the shell lacks worktree env, run from any worktree directory instead of `master`.

- [ ] **Step 6: Commit**

```bash
git add .docker-config/compose.yml
git commit -m "Mount per-worktree homes and shared cache volumes"
```

---

### Task 3: Mise `up` task — seed home, create volumes

**Files:**
- Modify: `.mise/config.toml` (the `[tasks.up]` run block, around line 176)

**Interfaces:**
- Consumes: `.docker-config/home-template/` (Task 1; may be empty on a fresh machine — the code must tolerate that).
- Produces: `.home/${CURRENT_WORKTREE_NAME}` exists before `docker compose up`; the six `${PROJECT_PREFIX}_*` volumes exist and are appuser-owned.

- [ ] **Step 1: Replace the mkdir line with home seeding**

In `[tasks.up]`, replace:

```bash
  mkdir -p {{config_root}}/.docker-config/home/.ssh {{config_root}}/.docker-config/home/.config
```

with:

```bash
  # Seed this worktree's home from the template if missing. Covers master
  # (create-worktree.sh never runs for it) and fresh clones; create-worktree.sh
  # does the same for new worktrees.
  home_dir="{{config_root}}/.home/${CURRENT_WORKTREE_NAME}"
  tmpl="{{config_root}}/.docker-config/home-template"
  if [ ! -d "$home_dir" ]; then
    mkdir -p "$home_dir"
    if [ -d "$tmpl" ]; then
      cp -a "$tmpl/." "$home_dir/"
    fi
    mkdir -p "$home_dir/.ssh" "$home_dir/.config"
  fi
```

- [ ] **Step 2: Extend volume creation**

Replace:

```bash
  for vol in "$GEM_VOLUME"; do
    docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
  done
```

with:

```bash
  for vol in "$GEM_VOLUME"; do
    docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
  done
  # Cross-worktree cache volumes, mounted inside the bind-mounted home. A
  # fresh named volume mounts root-owned and copy-from-image initialization
  # cannot fix that under a bind mount, so chown once at creation — never
  # recursively on an existing volume (warm caches stay untouched).
  for vol in npm_cache npm_global nvim_share playwright_browsers claude_plugins_cache claude_plugins_marketplaces; do
    name="${PROJECT_PREFIX}_${vol}"
    if ! docker volume inspect "$name" >/dev/null 2>&1; then
      docker volume create "$name" >/dev/null
      docker run --rm -v "$name":/v alpine chown "$(id -u):$(id -g)" /v
    fi
  done
```

- [ ] **Step 3: Verify TOML parses and the task is intact**

```bash
mise tasks --json >/dev/null && echo TOML_OK
```

Expected: `TOML_OK`.

- [ ] **Step 4: Verify seeding logic by dry run**

```bash
bash -c '
  set -euo pipefail
  config_root=$(pwd)
  CURRENT_WORKTREE_NAME=__seedtest
  home_dir="$config_root/.home/${CURRENT_WORKTREE_NAME}"
  tmpl="$config_root/.docker-config/home-template"
  if [ ! -d "$home_dir" ]; then
    mkdir -p "$home_dir"
    if [ -d "$tmpl" ]; then cp -a "$tmpl/." "$home_dir/"; fi
    mkdir -p "$home_dir/.ssh" "$home_dir/.config"
  fi
  test -d "$home_dir/.ssh" && echo SEED_OK
  rm -rf "$config_root/.home/__seedtest"
'
```

Expected: `SEED_OK`.

- [ ] **Step 5: Commit**

```bash
git add .mise/config.toml
git commit -m "Seed per-worktree home and create cache volumes in up task"
```

---

### Task 4: `create-worktree.sh` seeds the home

**Files:**
- Modify: `.scripts/create-worktree.sh` (after the node_modules pre-create block, around line 125)

**Interfaces:**
- Consumes: `${root}` and `${clean_name}` variables already defined in the script; `.docker-config/home-template/`.
- Produces: `.home/<slug>/` exists when `mise run wt` finishes.

- [ ] **Step 1: Add the seeding block**

Directly after:

```bash
# Pre-create node_modules so Docker doesn't create it as root when
# mounting the node_modules volume over the bind-mounted worktree.
mkdir -p "${worktree_dir}/node_modules"
```

insert:

```bash
# --- Seed the per-worktree home from the template ---
home_dir="${root}/.home/${clean_name}"
home_template="${root}/.docker-config/home-template"
if [ ! -d "$home_dir" ]; then
  mkdir -p "$home_dir"
  if [ -d "$home_template" ]; then
    cp -a "${home_template}/." "$home_dir/"
  fi
  mkdir -p "${home_dir}/.ssh" "${home_dir}/.config"
  echo "Seeded home: .home/${clean_name}"
fi
```

- [ ] **Step 2: Syntax check**

```bash
bash -n .scripts/create-worktree.sh && echo SYNTAX_OK
```

Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add .scripts/create-worktree.sh
git commit -m "Seed per-worktree home in create-worktree"
```

---

### Task 5: `remove-worktree.sh` removes the home

**Files:**
- Modify: `.scripts/remove-worktree.sh` (the `.claude-worktrees` cleanup, around line 149)

**Interfaces:**
- Consumes: `${root}` and `${clean_name}` variables already defined in the script.
- Produces: `mise run wt:rm <slug>` deletes `.home/<slug>`.

- [ ] **Step 1: Replace the old cleanup**

Replace:

```bash
# Drop this worktree's claude config dir. It holds a live OAuth refresh token
# valid for weeks, so an orphaned dir is a stale credential, not just clutter.
# The global plugins/agents/hooks inside it are symlinks; rm removes the links.
rm -rf "${root}/.docker-config/home/.claude-worktrees/${clean_name}"
```

with:

```bash
# Drop this worktree's home. Its ~/.claude holds a live OAuth refresh token
# valid for weeks, so an orphaned home is a stale credential, not just
# clutter. Guard the path: only a plain name directly under .home/ may go.
case "$clean_name" in
  ''|.|..|*/*)
    echo "warn: suspicious worktree name '${clean_name}'; not removing its home" >&2
    ;;
  *)
    rm -rf "${root}/.home/${clean_name}"
    ;;
esac
```

This runs after the compose project is downed (the script downs it earlier), which matches the spec's ordering requirement.

- [ ] **Step 2: Syntax check**

```bash
bash -n .scripts/remove-worktree.sh && echo SYNTAX_OK
```

Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add .scripts/remove-worktree.sh
git commit -m "Remove per-worktree home in remove-worktree"
```

---

### Task 6: Simplify `entrypoint-claude.sh`

**Files:**
- Modify: `.docker-config/entrypoint-claude.sh`

**Interfaces:**
- Consumes: per-worktree home mounted at `/home/appuser` (Task 2); plugin cache/marketplaces volumes mounted inside `~/.claude/plugins/` (Task 2).
- Produces: the entrypoint works with plain `~/.claude` and no shared dir.

- [ ] **Step 1: Replace the config-dir setup**

Replace everything from:

```bash
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SHARED_DIR="$HOME/.claude"
```

down to and including the whole plugins split block (the block that ends with):

```bash
  for record in known_marketplaces.json installed_plugins.json; do
    if [ ! -f "$CONFIG_DIR/plugins/$record" ] && [ -f "$SHARED_DIR/plugins/$record" ]; then
      sed "s|$SHARED_DIR/plugins|$CONFIG_DIR/plugins|g" \
        "$SHARED_DIR/plugins/$record" > "$CONFIG_DIR/plugins/$record"
    fi
  done
fi
```

with:

```bash
# The home directory is per-worktree (.home/<slug> on the host), so the
# default ~/.claude is already isolated: credentials, sessions and plugin
# records never cross worktrees. The plugin cache and marketplaces are
# cross-worktree volumes mounted inside ~/.claude/plugins by compose.
CONFIG_DIR="$HOME/.claude"
mkdir -p "$CONFIG_DIR"
```

- [ ] **Step 2: Fix the stale comment on the MCP section**

Replace:

```bash
# Configure MCP servers idempotently — .claude.json is per-worktree now, but
# the guard still earns its keep by not rewriting the file on every boot.
```

with:

```bash
# Configure MCP servers idempotently — the guard avoids rewriting the file
# on every boot.
```

- [ ] **Step 3: Verify no `SHARED_DIR` or `CLAUDE_CONFIG_DIR` remains**

```bash
grep -n 'SHARED_DIR\|CLAUDE_CONFIG_DIR' .docker-config/entrypoint-claude.sh || echo CLEAN
bash -n .docker-config/entrypoint-claude.sh && echo SYNTAX_OK
```

Expected: `CLEAN` then `SYNTAX_OK`. (Note: `rtk init` honours `$CLAUDE_CONFIG_DIR` but falls back to `~/.claude` when unset — no change needed there.)

- [ ] **Step 4: Commit**

```bash
git add .docker-config/entrypoint-claude.sh
git commit -m "Drop the CLAUDE_CONFIG_DIR split from the claude entrypoint"
```

---

### Task 7: `sync-claude-template.sh` (promote + apply)

**Files:**
- Create: `.scripts/sync-claude-template.sh` (mode `0755`)
- Delete: `.scripts/promote-claude-plugins.sh`

**Interfaces:**
- Consumes: `find_project_root` from `.scripts/lib.sh`; `.home/<slug>/` homes; `.docker-config/home-template/`.
- Produces: `sync-claude-template.sh promote <worktree> [--replace] [--yes]` and `sync-claude-template.sh apply <worktree>|--all [--yes]`. Task 8 wires mise tasks to these exact argument forms.

- [ ] **Step 1: Write the script**

Create `.scripts/sync-claude-template.sh`:

```bash
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
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

root=$(find_project_root)
template="$root/.docker-config/home-template"
stamp=$(date +%Y%m%d-%H%M%S)

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
```

- [ ] **Step 2: Delete the old script**

```bash
git rm .scripts/promote-claude-plugins.sh
chmod 0755 .scripts/sync-claude-template.sh
```

- [ ] **Step 3: Syntax check and usage smoke test**

```bash
bash -n .scripts/sync-claude-template.sh && echo SYNTAX_OK
.scripts/sync-claude-template.sh --help | head -3
.scripts/sync-claude-template.sh promote 2>&1 | head -3 || true
```

Expected: `SYNTAX_OK`; the help text prints; the bare `promote` prints usage and exits non-zero.

- [ ] **Step 4: Functional test with a throwaway home**

```bash
bash -c '
  set -euo pipefail
  root=$(pwd)
  fake="$root/.home/__synctest"
  mkdir -p "$fake/.claude/plugins" "$fake/.claude/agents"
  echo "agent-a" > "$fake/.claude/agents/a.md"
  echo "{}" > "$fake/.claude/settings.json"
  printf "%s" "{\"m1\":{\"installLocation\":\"/home/appuser/.claude/plugins/marketplaces/m1\"}}" > "$fake/.claude/plugins/known_marketplaces.json"
  printf "%s" "{\"plugins\":{\"p1\":[{\"scope\":\"user\"},{\"scope\":\"project\"}]}}" > "$fake/.claude/plugins/installed_plugins.json"
  printf "%s" "{\"oauthAccount\":{},\"projects\":{\"/app-x\":{}}}" > "$fake/.claude.json"

  .scripts/sync-claude-template.sh promote __synctest --yes >/dev/null

  test -f .docker-config/home-template/.claude/agents/a.md || { echo FAIL_agents; exit 1; }
  jq -e ".plugins.p1 | length == 1" .docker-config/home-template/.claude/plugins/installed_plugins.json >/dev/null || { echo FAIL_strip; exit 1; }
  jq -e "has(\"projects\") | not" .docker-config/home-template/.claude.json >/dev/null || { echo FAIL_sanitize; exit 1; }

  rm -rf "$fake"
  mkdir -p "$fake/.claude"
  printf "%s" "{\"projects\":{\"/app-y\":{\"hasTrustDialogAccepted\":true}}}" > "$fake/.claude.json"
  echo "secret" > "$fake/.claude/.credentials.json"

  .scripts/sync-claude-template.sh apply __synctest --yes >/dev/null

  test -f "$fake/.claude/agents/a.md" || { echo FAIL_apply; exit 1; }
  jq -e ".projects[\"/app-y\"].hasTrustDialogAccepted == true" "$fake/.claude.json" >/dev/null || { echo FAIL_merge; exit 1; }
  test "$(cat "$fake/.claude/.credentials.json")" = "secret" || { echo FAIL_credentials; exit 1; }
  echo TEST_OK
  rm -rf "$fake"
'
```

Expected: `TEST_OK`.

- [ ] **Step 5: Clean test artifacts from the template, then commit**

```bash
rm -rf .docker-config/home-template/.claude .docker-config/home-template/.claude.json
git add .scripts/sync-claude-template.sh
git commit -m "Replace promote-claude-plugins with sync-claude-template"
```

(The template is untracked, so cleaning it never shows in git status. The real template content arrives in Task 9.)

---

### Task 8: Mise tasks `claude:template:promote` / `claude:template:apply`

**Files:**
- Modify: `.mise/config.toml` (replace the `[tasks."claude:plugins:promote"]` block, around line 314)

**Interfaces:**
- Consumes: `sync-claude-template.sh promote|apply` argument forms from Task 7.
- Produces: `mise run claude:template:promote [...]` and `mise run claude:template:apply [...]`, both defaulting to the current worktree.

- [ ] **Step 1: Replace the task block**

Replace the whole `[tasks."claude:plugins:promote"]` block with:

```toml
[tasks."claude:template:promote"]
description = "Promote this worktree's Claude config set (agents, hooks, skills, settings, plugin records) to the template that seeds new worktrees. Merges plugin records unless --replace; pass a worktree name to promote another worktree."
usage = 'arg "[args]…" var=#true default=""'
run = """
  args="${usage_args:-}"
  [ "$args" = "''" ] && args=
  set -- $args
  case "${1:-}" in
    ""|-*) set -- "$CURRENT_WORKTREE_NAME" "$@" ;;
  esac
  exec {{config_root}}/.scripts/sync-claude-template.sh promote "$@"
"""

[tasks."claude:template:apply"]
description = "Copy the template's Claude config set onto this worktree's home (or --all for every home). Never touches credentials, sessions or other state."
usage = 'arg "[args]…" var=#true default=""'
run = """
  args="${usage_args:-}"
  [ "$args" = "''" ] && args=
  set -- $args
  case "${1:-}" in
    ""|-*) set -- "$CURRENT_WORKTREE_NAME" "$@" ;;
  esac
  case "$*" in
    *--all*) set -- --all $(printf '%s\\n' "$@" | grep -v -e "^$CURRENT_WORKTREE_NAME$" -e "^--all$" | tr '\\n' ' ') ;;
  esac
  exec {{config_root}}/.scripts/sync-claude-template.sh apply "$@"
"""
```

Note on the `apply` wrapper: if the user passes `--all`, the injected current-worktree default must not also be sent (the script treats a name plus `--all` as an error). The `case "$*"` block strips the injected name and keeps remaining flags (e.g. `--yes`).

- [ ] **Step 2: Verify**

```bash
mise tasks --json >/dev/null && echo TOML_OK
mise tasks | grep -c 'claude:template' | grep -q 2 && echo TASKS_OK
mise tasks | grep 'claude:plugins:promote' || echo OLD_GONE
```

Expected: `TOML_OK`, `TASKS_OK`, `OLD_GONE`.

- [ ] **Step 3: Commit**

```bash
git add .mise/config.toml
git commit -m "Wire claude:template:promote and claude:template:apply tasks"
```

---

### Task 9: Migration script

**Files:**
- Create: `.scripts/migrate-per-worktree-homes.sh` (mode `0755`)

**Interfaces:**
- Consumes: the old shared home at `.docker-config/home`; `ports.registry` (slug list); the volume names from Global Constraints.
- Produces: `.docker-config/home-template/` populated; `.home/<slug>/` for master and every registered worktree; cache volumes seeded. The old home is left in place.

- [ ] **Step 1: Write the script**

Create `.scripts/migrate-per-worktree-homes.sh`:

```bash
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
if [ -f "$old/.claude.json" ] && [ ! -f "$template/.claude.json" ]; then
  jq 'del(.projects)' "$old/.claude.json" > "$template/.claude.json"
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
```

- [ ] **Step 2: Syntax check**

```bash
bash -n .scripts/migrate-per-worktree-homes.sh && echo SYNTAX_OK
chmod 0755 .scripts/migrate-per-worktree-homes.sh
```

Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add .scripts/migrate-per-worktree-homes.sh
git commit -m "Add one-time migration to per-worktree homes"
```

---

### Task 10: Run the migration and smoke-test (USER CHECKPOINT)

**Files:** none (operational task).

**Interfaces:**
- Consumes: everything from Tasks 1–9.

> **STOP — coordinate with the user before this task.** It requires stopping every running worktree stack, and it touches the user's live Claude sessions/credentials layout.

- [ ] **Step 1: Stop all worktree stacks** (user or executor, per user's go-ahead)

In each worktree with a running stack: `mise run down` (or `docker compose down`). Verify:

```bash
docker ps --format '{{.Names}}' | grep "^${PROJECT_PREFIX}-" || echo ALL_DOWN
```

Expected: `ALL_DOWN`.

- [ ] **Step 2: Run the migration**

```bash
mise exec -- .scripts/migrate-per-worktree-homes.sh
```

Confirm the prompt. Expected: template lines, one `== <slug>: building home` per registered worktree plus master, and one `== Seeding volume ...` per non-empty cache.

- [ ] **Step 3: Verify the homes**

```bash
ls .home/
test -f .home/master/.zshrc && echo ZSHRC_OK
test -d .home/master/.claude && echo CLAUDE_OK
ls .home/master/.claude/plugins/
```

Expected: one directory per worktree plus `master`; `ZSHRC_OK`; `CLAUDE_OK`; plugin records present, `cache`/`marketplaces` as plain dirs.

- [ ] **Step 4: Boot the master stack and smoke-test**

```bash
cd master && mise run up
mise exec -- docker compose exec rails sh -c 'ls ~/.zshrc && touch ~/.npm/.writetest && rm ~/.npm/.writetest && echo RAILS_HOME_OK'
```

Expected: `RAILS_HOME_OK` (home mounted, npm volume writable by appuser).

- [ ] **Step 5: Smoke-test the claude container** (user drives — needs their session)

User starts the claude container as usual and verifies: no trust dialog, plugins load (no "not cached" errors), `claude --version` runs, previous sessions resume. If credentials were carried over, no `/login` needed.

- [ ] **Step 6: Confirm and leave cleanup to the user**

The old `.docker-config/home` stays until the user has run every worktree they care about. Cleanup command (user runs later, not part of this plan):

```bash
rm -rf .docker-config/home
```

---

### Task 11: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: the final behavior from Tasks 1–9.

- [ ] **Step 1: Update the stale statements**

Search and fix each of these (exact current text may wrap differently — locate by grep):

1. `grep -n 'npm cache shared via home bind mount' AGENTS.md` — replace that clause with: `npm cache shared via the ${PROJECT_PREFIX}_npm_cache volume`.
2. `grep -n 'claude:plugins:promote\|plugins:promote' AGENTS.md` — replace mentions with `claude:template:promote` / `claude:template:apply` and a one-line description: "sync the Claude config set between a worktree home and .docker-config/home-template".
3. `grep -n 'docker-config/home\|home bind\|shared home\|CLAUDE_CONFIG_DIR\|claude-worktrees' AGENTS.md` — update every hit to describe the new layout:
   - homes live in `.home/<slug>/`, seeded from `.docker-config/home-template/` by `create-worktree.sh` and the `up` task;
   - `wt:rm` deletes `.home/<slug>`;
   - caches shared across worktrees via `${PROJECT_PREFIX}_*` external volumes (npm_cache, npm_global, nvim_share, playwright_browsers, claude_plugins_cache, claude_plugins_marketplaces);
   - the claude container uses plain `~/.claude` (no `CLAUDE_CONFIG_DIR`).
4. In the directory-layout list (near the top), update the `.docker-config/` line to mention `home-template/` and add a `.home/` line: `- .home/ — (git-ignored) per-worktree container home dirs, seeded from .docker-config/home-template/.`

Keep AGENTS.md's existing terse style.

- [ ] **Step 2: Verify nothing stale remains**

```bash
grep -n 'claude:plugins:promote\|claude-worktrees\|CLAUDE_CONFIG_DIR' AGENTS.md || echo DOCS_CLEAN
```

Expected: `DOCS_CLEAN`.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "Document per-worktree homes in AGENTS.md"
```

---

## Execution notes

- Tasks 1–9 are safe while stacks run: nothing consumes the new paths until `mise run up`, `wt`, or the migration executes. Task 10 is the cutover and needs all stacks down.
- If a worktree stack starts between Task 2 and Task 10, its `up` will seed a fresh `.home/<slug>` from a still-empty template and mount it — sessions/config for the claude container would look empty until migration runs. Avoid `mise run up` in any worktree between Task 2 landing and Task 10 completing, or just run Tasks 1–9 back-to-back and migrate immediately.
- Rollback before Task 10: `git revert` the commits; the old `.docker-config/home` is untouched throughout Tasks 1–9.
