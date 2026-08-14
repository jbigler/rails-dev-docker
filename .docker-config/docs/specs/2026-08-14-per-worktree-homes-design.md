# Per-worktree container homes

**Date:** 2026-08-14
**Status:** Approved design, pending implementation plan

## Problem

`.docker-config/home` is bind-mounted as `/home/appuser` into the rails, nvim,
and claude containers of **every** worktree's compose stack. One home shared
across all services and all worktrees causes cross-worktree clobbering (shell
histories, `.zcompdump` races, `.claude.json`) and has already forced a
workaround: the claude container's per-worktree `CLAUDE_CONFIG_DIR` plus
symlink/sed gymnastics in `entrypoint-claude.sh`.

## Decision

One home directory **per worktree**, shared by that worktree's services.
Heavy caches and install-state stay shared across worktrees via external
Docker volumes.

## Layout

- `.docker-config/home` is renamed to `.docker-config/home-template` and
  pruned to a skeleton:
  - Dotfiles: `.zshrc`, `.zimrc`, `.gitconfig`, `.irbrc`, `.config` skeleton.
  - `.zim/` (29M) is kept — re-bootstrapping zim requires network the
    firewalled claude container may not have.
  - Empty mount-point dirs so bind/volume mounts land on appuser-owned
    directories: `.ssh`, `.npm`, `.npm-global`, `.config/nvim`,
    `.local/share/nvim`, `.cache/ms-playwright`,
    `.claude/plugins/cache`, `.claude/plugins/marketplaces`.
  - `.claude/plugins/known_marketplaces.json` and
    `.claude/plugins/installed_plugins.json` — the shared plugin default that
    new worktrees are seeded from (project-scoped install records stripped).
    Paths inside them are plain `~/.claude/plugins/...`, valid verbatim in
    every worktree.
  - Excluded: histories, `.claude.json`, `.zcompdump*`, `.claude-worktrees/`,
    all cache contents.
  - Template contents stay untracked (only `.gitkeep`), as today.
- New `.home/` directory at repo root (covered by the `/*` gitignore rule).
  `.home/<slug>/` is the home for worktree `<slug>`, including
  `.home/master/`.
- `.gitignore`: the `.docker-config/home/*` rules become
  `.docker-config/home-template/*`.

## Compose changes (`.docker-config/compose.yml`)

- rails, nvim, claude: `../.docker-config/home:/home/appuser` becomes
  `../.home/${CURRENT_WORKTREE_NAME}:/home/appuser`.
- Delete the dead `home:` named volume.
- New **external** shared volumes (cross-worktree, `${PROJECT_PREFIX}_`
  names, declared `external: true` like `shared_gems`):

  | Volume | Mount | Services |
  |--------|-------|----------|
  | `npm_cache` | `/home/appuser/.npm` | rails, nvim, claude |
  | `npm_global` | `/home/appuser/.npm-global` | rails, nvim, claude |
  | `nvim_share` | `/home/appuser/.local/share/nvim` | nvim |
  | `playwright_browsers` | `/home/appuser/.cache/ms-playwright` | rails |
  | `claude_plugins_cache` | `/home/appuser/.claude/plugins/cache` | claude |
  | `claude_plugins_marketplaces` | `/home/appuser/.claude/plugins/marketplaces` | claude |

- Volumes are created in the same mise hook that creates `GEM_VOLUME`
  (`.mise/config.toml`), and chowned to `${UID}:${GID}` via a one-off
  container right after creation (a fresh named volume mounts root-owned).

`NVIM_CONFIG_DIR` (host bind, `:ro`) is unchanged. The nvim share dir is a
volume, not a host bind: treesitter parsers and Mason binaries built on the
Arch host would not be guaranteed to load in the Debian container (glibc
mismatch), so container-produced artifacts stay in a container-only volume.

## Worktree lifecycle

- `create-worktree.sh`: new step — `mkdir -p .home/<slug>` and
  `cp -a .docker-config/home-template/. .home/<slug>/`.
- `remove-worktree.sh`: `rm -rf` of `.home/<slug>`, path-guarded (refuse
  anything not directly under `.home/`), after the compose project is down.

## Claude entrypoint simplification (`entrypoint-claude.sh`)

- Remove `CLAUDE_CONFIG_DIR` from the compose claude service; the config dir
  is plain `~/.claude`, per-worktree by construction.
- Delete the now-dead blocks guarded by `CONFIG_DIR != SHARED_DIR`: first-boot
  seeding from the shared dir, `agents`/`hooks` symlinks, the plugins
  symlink/sed-rewrite split. Plugin sharing is handled by the two volume
  mounts; `installed_plugins.json` / `known_marketplaces.json` live in the
  per-worktree home with real paths (`~/.claude/plugins/...`) that need no
  rewriting.
- The rest (firewall, MCP registration, trust pre-seed, status hook, rtk,
  CLAUDE.md refresh) is unchanged.

## `claude:plugins:promote` task (`promote-claude-plugins.sh`)

The task keeps its purpose — push one worktree's plugin set back to the
default that seeds new worktrees — but simplifies:

- The shared default moves from `.docker-config/home/.claude/plugins/` to
  `.docker-config/home-template/.claude/plugins/`.
- The promotion source moves from
  `.docker-config/home/.claude-worktrees/<slug>/plugins/` to
  `.home/<slug>/.claude/plugins/`.
- All prefix sed-rewriting is deleted: every worktree and the template use
  the same container path (`/home/appuser/.claude/plugins`). Promote is a
  plain jq merge/replace; `--reseed` is a plain copy into the other
  `.home/<slug>/.claude/plugins/` dirs.
- Project-scoped install records are still stripped (they key on the
  per-worktree `/app-<slug>` path).
- The pre-split whole-directory-symlink guard is deleted.

## Migration (one-time)

For each existing worktree plus `master`:

1. Copy template skeleton to `.home/<slug>`.
2. Move `.docker-config/home/.claude-worktrees/<slug>` to
   `.home/<slug>/.claude` (preserves sessions, credentials, settings);
   rewrite paths inside `installed_plugins.json` / `known_marketplaces.json`
   (`.claude-worktrees/<slug>/plugins` → `.claude/plugins`).
3. Optionally copy histories (`.zhistory`, `.irb_history`, `.psql_history`);
   they are disposable.

Once, globally:

4. Seed the shared volumes from the old home: `.npm`, `.npm-global`,
   `.local/share/nvim`, `.cache/ms-playwright`, `.claude/plugins/cache`,
   `.claude/plugins/marketplaces`.
5. Keep `.docker-config/home` untouched until the new layout is confirmed
   working, then delete its contents (the template was split off in step 1
   of implementation).

## Out of scope

Per-worktree `node_modules` volume, `shared_gems`, the db/redis/rustfs/
playwright services, the proxy stack, and the `/status` dashboard wiring are
all unchanged.
