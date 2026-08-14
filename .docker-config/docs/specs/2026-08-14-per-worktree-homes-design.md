# Per-worktree container homes

**Date:** 2026-08-14
**Status:** Approved design, pending implementation plan

## Problem

The compose stack of every worktree bind-mounts `.docker-config/home` as
`/home/appuser` into the rails, nvim, and claude containers. All services and
all worktrees share one home directory. This causes cross-worktree clobbering
(shell histories, `.zcompdump` races, `.claude.json`). It also forced a
workaround: the per-worktree `CLAUDE_CONFIG_DIR` in the claude container,
plus symlink and sed rewrites in `entrypoint-claude.sh`.

## Decision

Each worktree gets one home directory, shared by the services of that
worktree.
Heavy caches and install-state stay shared across worktrees through external
Docker volumes.

## Layout

- Rename `.docker-config/home` to `.docker-config/home-template` and prune it
  to a skeleton:
  - Dotfiles: `.zshrc`, `.zimrc`, `.gitconfig`, `.irbrc`, `.config` skeleton.
  - Keep `.zim/` (29M) — a zim re-bootstrap needs network access, and the
    firewalled claude container may not have it.
  - Empty mount-point directories, so bind and volume mounts attach to
    directories that appuser owns: `.ssh`, `.npm`, `.npm-global`,
    `.config/nvim`, `.config/git` (the `~/.config/git/ignore` bind needs it),
    `.local/share/nvim`, `.cache/ms-playwright`, `.claude/plugins/cache`,
    `.claude/plugins/marketplaces`.
  - The Claude config set (see the template manifest below).
  - Excluded: histories, `.zcompdump*`, `.claude-worktrees/`, `.bundle`
    (bundler cache — it rebuilds), all cache contents.
  - Template contents stay untracked (only `.gitkeep`), as today.
- Add a new `.home/` directory at the repo root (the `/*` gitignore rule
  covers it). `.home/<slug>/` is the home directory for worktree `<slug>`,
  including `.home/master/`.
- `.gitignore`: change the `.docker-config/home/*` rules to
  `.docker-config/home-template/*`.

## Compose changes (`.docker-config/compose.yml`)

- rails, nvim, claude: change `../.docker-config/home:/home/appuser` to
  `../.home/${CURRENT_WORKTREE_NAME}:/home/appuser`.
- Delete the dead `home:` named volume.
- Add new **external** shared volumes (cross-worktree, `${PROJECT_PREFIX}_`
  names, declared `external: true` like `shared_gems`):

  | Volume | Mount | Services |
  |--------|-------|----------|
  | `npm_cache` | `/home/appuser/.npm` | rails, nvim, claude |
  | `npm_global` | `/home/appuser/.npm-global` | rails, nvim, claude |
  | `nvim_share` | `/home/appuser/.local/share/nvim` | nvim |
  | `playwright_browsers` | `/home/appuser/.cache/ms-playwright` | rails |
  | `claude_plugins_cache` | `/home/appuser/.claude/plugins/cache` | claude |
  | `claude_plugins_marketplaces` | `/home/appuser/.claude/plugins/marketplaces` | claude |

- The mise hook that creates `GEM_VOLUME` (`.mise/config.toml`) also creates
  these volumes. A fresh named volume mounts root-owned, and the usual
  copy-from-image initialization does not work under a bind-mounted home.
  Thus the hook chowns each volume to `${UID}:${GID}` with a one-off
  container immediately after creation. The chown runs only when the hook
  first creates the volume — never a recursive chown on an existing volume —
  so warm caches stay untouched:
  `docker volume inspect || { docker volume create && docker run --rm ... chown }`.

`NVIM_CONFIG_DIR` (host bind, `:ro`) is unchanged. The nvim share directory
is a volume, not a host bind. Treesitter parsers and Mason binaries built on
the Arch host can fail to load in the Debian container (glibc
mismatch). Thus artifacts that the container produces stay in a
container-only volume.

## Worktree lifecycle

- `create-worktree.sh`: add a step — `mkdir -p .home/<slug>` and
  `cp -a .docker-config/home-template/. .home/<slug>/`.
- The mise setup hook (`.mise/config.toml`, which creates `GEM_VOLUME`)
  currently also runs `mkdir -p` on `.docker-config/home/.ssh` and
  `.config`. That line dies. Instead, the hook seeds
  `.home/${CURRENT_WORKTREE_NAME}` from the template if the directory is
  missing. This step creates `.home/master` (no `wt` run ever covers it),
  heals a fresh clone on a new machine, and covers the case where
  `create-worktree.sh` did not run.
- `remove-worktree.sh`: run `rm -rf` on `.home/<slug>` after the compose
  project is down. Guard the path — refuse anything not directly under
  `.home/`. This replaces the existing cleanup of
  `.docker-config/home/.claude-worktrees/<slug>` (line 149).

## Claude entrypoint simplification (`entrypoint-claude.sh`)

- Remove `CLAUDE_CONFIG_DIR` from the compose claude service. The config
  directory is plain `~/.claude`, per-worktree by construction.
- Delete the now-dead blocks that the `CONFIG_DIR != SHARED_DIR` guard
  protects: the first-boot seeding from the shared directory, the
  `agents`/`hooks` symlinks, and the plugins symlink and sed-rewrite split.
  The two volume mounts handle plugin sharing. `installed_plugins.json` and
  `known_marketplaces.json` live in the per-worktree home with real paths
  (`~/.claude/plugins/...`) that need no rewriting.
- The rest (firewall, MCP registration, trust pre-seed, status hook, rtk,
  CLAUDE.md refresh) is unchanged.

## Claude template manifest

What lives where in a worktree's `~/.claude` (plus the home-root
`.claude.json`):

**Config — lives in the template. The `claude:template:*` tasks move it:**

- `agents/`, `hooks/`, `skills/` — user-defined subagents, hook scripts,
  installed skills.
- `settings.json`, `keybindings.json`, `statusline-command.sh`,
  `CLAUDE.local.md` (the committed CLAUDE.md references it).
- `plugins/known_marketplaces.json`, `plugins/installed_plugins.json` —
  bookkeeping only. The heavy `plugins/cache` and `plugins/marketplaces` are
  shared volumes. Paths inside are plain `~/.claude/plugins/...`, valid
  verbatim in every worktree. The template copies have no project-scoped
  install records (those records key on the per-worktree `/app-<slug>`
  path).
- Home-root `.claude.json`, sanitized: the account record, onboarding flags,
  and user-scope MCP servers stay. `projects`, caches, and history go.
  First boot of a new worktree then needs only `/login`.

**Per-worktree state — never in the template. `apply` does not touch it.
Migration preserves it:**

- `projects/` — session transcripts (`--resume` history) and auto-memory
  per project directory.
- `.credentials.json` — OAuth tokens, per-worktree by design (a shared
  refresh token is the bug that the old CLAUDE_CONFIG_DIR split fixed).
- `history.jsonl`, `file-history/`, `sessions/`, `tasks/`, `jobs/`,
  `backups/`.

**Disposable — in neither. It regenerates:**

- `cache/`, `paste-cache/`, `shell-snapshots/`, `session-env/`, `daemon*`,
  `stats-cache.json`, `gh-pr-status-cache.json`,
  `mcp-needs-auth-cache.json`, `policy-limits.json`,
  `remote-settings.json`, `settings.json.bak`.
- `CLAUDE.md`, `RTK.md` — the entrypoint rewrites both at every boot.

## `claude:template:*` tasks (replace `claude:plugins:promote`)

`promote-claude-plugins.sh` becomes a template sync script with two mise
tasks. All prefix sed-rewriting and the pre-split symlink guard die — every
worktree and the template use the same container path.

- **`claude:template:promote [worktree]`** — copy the config set of a
  worktree (manifest above) to `.docker-config/home-template/`. The plugin json files
  keep the jq merge-by-default and `--replace` semantics, and the
  project-scope strip. The task sanitizes `.claude.json` on the way out.
  The rest (agents, hooks, skills, settings, keybindings, statusline,
  CLAUDE.local.md) copies unchanged. Defaults to the current worktree.
- **`claude:template:apply [worktree|--all]`** — copy the template's config
  set onto a worktree's `.home/<slug>` (replaces `--reseed`). The task
  writes only the manifest's config set. It never touches state or
  `.credentials.json`. It merges `.claude.json` (template keys win, the
  `projects` and trust entries of the worktree survive) rather than
  replaces it. Thus the task does not lose auth or trust.
- Both tasks keep timestamped `.bak-` copies of what they overwrite, and
  keep the confirmation prompt and `--yes`.

## Migration (one-time)

For each existing worktree plus `master`:

1. Copy the template skeleton to `.home/<slug>`.
2. Move `.docker-config/home/.claude-worktrees/<slug>` to
   `.home/<slug>/.claude` (this preserves sessions, credentials, and
   settings). Rewrite the paths inside `installed_plugins.json` and
   `known_marketplaces.json` (`.claude-worktrees/<slug>/plugins` →
   `.claude/plugins`). The move breaks the old `agents`/`hooks` symlinks
   into the shared home — replace them with real copies from the template.
3. Optionally copy the histories (`.zhistory`, `.irb_history`,
   `.psql_history`). They are disposable.

Once, globally (the template build comes first — the per-worktree steps
copy from it):

- Build the template from the current shared home: the skeleton dotfiles,
  the Claude config set from `.docker-config/home/.claude` (agents, hooks,
  skills, settings.json, keybindings.json, statusline-command.sh,
  CLAUDE.local.md, and the plugin bookkeeping json with project-scoped
  records stripped), and a sanitized copy of the shared `.claude.json`.
- Seed the shared volumes from the old home: `.npm`, `.npm-global`,
  `.local/share/nvim`, `.cache/ms-playwright`, `.claude/plugins/cache`,
  `.claude/plugins/marketplaces`.
- Keep `.docker-config/home` untouched until you confirm the new layout
  works. Then delete its contents.

## Out of scope

These stay unchanged: the per-worktree `node_modules` volume, `shared_gems`,
the db/redis/rustfs/playwright services, the proxy stack, and the `/status`
dashboard wiring.
