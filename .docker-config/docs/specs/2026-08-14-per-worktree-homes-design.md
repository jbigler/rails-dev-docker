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
    directories: `.ssh`, `.npm`, `.npm-global`, `.config/nvim`, `.config/git`
    (the `~/.config/git/ignore` bind needs it), `.local/share/nvim`,
    `.cache/ms-playwright`, `.claude/plugins/cache`,
    `.claude/plugins/marketplaces`.
  - The Claude config set (see the template manifest below).
  - Excluded: histories, `.zcompdump*`, `.claude-worktrees/`, `.bundle`
    (bundler cache — rebuilds), all cache contents.
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
  container right after creation (a fresh named volume mounts root-owned;
  the usual copy-from-image initialization can't help under a bind-mounted
  home). The chown runs only when the volume is first created — never a
  recursive chown on existing volumes — so warm caches aren't touched:
  `docker volume inspect || { docker volume create && docker run --rm ... chown }`.

`NVIM_CONFIG_DIR` (host bind, `:ro`) is unchanged. The nvim share dir is a
volume, not a host bind: treesitter parsers and Mason binaries built on the
Arch host would not be guaranteed to load in the Debian container (glibc
mismatch), so container-produced artifacts stay in a container-only volume.

## Worktree lifecycle

- `create-worktree.sh`: new step — `mkdir -p .home/<slug>` and
  `cp -a .docker-config/home-template/. .home/<slug>/`.
- The mise setup hook (`.mise/config.toml`, where `GEM_VOLUME` is created —
  currently also `mkdir -p .docker-config/home/.ssh .config`, which dies)
  additionally seeds `.home/${CURRENT_WORKTREE_NAME}` from the template
  **if missing**. This is what creates `.home/master` (no `wt` run ever
  covers it), heals a fresh clone on a new machine, and backstops the
  explicit `create-worktree.sh` step.
- `remove-worktree.sh`: `rm -rf` of `.home/<slug>`, path-guarded (refuse
  anything not directly under `.home/`), after the compose project is down.
  Replaces the existing
  `rm -rf .docker-config/home/.claude-worktrees/<slug>` cleanup (line 149).

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

## Claude template manifest

What lives where in a worktree's `~/.claude` (plus the home-root
`.claude.json`):

**Config — in the template; moved by the `claude:template:*` tasks:**

- `agents/`, `hooks/`, `skills/` — user-defined subagents, hook scripts,
  installed skills.
- `settings.json`, `keybindings.json`, `statusline-command.sh`,
  `CLAUDE.local.md` (referenced by the committed CLAUDE.md).
- `plugins/known_marketplaces.json`, `plugins/installed_plugins.json` —
  bookkeeping only; the heavy `plugins/cache` + `plugins/marketplaces` are
  shared volumes. Paths inside are plain `~/.claude/plugins/...`, valid
  verbatim in every worktree. Project-scoped install records are stripped
  from the template copies (they key on the per-worktree `/app-<slug>`
  path).
- Home-root `.claude.json`, sanitized: account record, onboarding flags,
  user-scope MCP servers kept; `projects`, caches, history stripped. First
  boot of a new worktree then needs only `/login`.

**Per-worktree state — never in the template, untouched by `apply`,
preserved in migration:**

- `projects/` — session transcripts (`--resume` history) and auto-memory
  per project dir.
- `.credentials.json` — OAuth tokens; per-worktree by design (a shared
  refresh token is the bug the old CLAUDE_CONFIG_DIR split fixed).
- `history.jsonl`, `file-history/`, `sessions/`, `tasks/`, `jobs/`,
  `backups/`.

**Disposable — in neither; regenerates:**

- `cache/`, `paste-cache/`, `shell-snapshots/`, `session-env/`, `daemon*`,
  `stats-cache.json`, `gh-pr-status-cache.json`,
  `mcp-needs-auth-cache.json`, `policy-limits.json`,
  `remote-settings.json`, `settings.json.bak`.
- `CLAUDE.md`, `RTK.md` — the entrypoint rewrites both every boot.

## `claude:template:*` tasks (replace `claude:plugins:promote`)

`promote-claude-plugins.sh` grows into a template sync script with two mise
tasks. All prefix sed-rewriting and the pre-split symlink guard are deleted
— every worktree and the template use the same container path.

- **`claude:template:promote [worktree]`** — push a worktree's config set
  (manifest above) to `.docker-config/home-template/`. Plugin json files
  keep the jq merge-by-default / `--replace` semantics and the
  project-scope strip; `.claude.json` is sanitized on the way out; the
  rest (agents, hooks, skills, settings, keybindings, statusline,
  CLAUDE.local.md) copy wholesale. Defaults to the current worktree.
- **`claude:template:apply [worktree|--all]`** — copy the template's config
  set onto a worktree's `.home/<slug>` (replaces `--reseed`). Only the
  manifest's config set is written; state and `.credentials.json` are never
  touched. `.claude.json` is merged (template keys win, worktree's
  `projects`/trust entries survive) rather than replaced, so auth and trust
  aren't lost.
- Both keep timestamped `.bak-` copies of what they overwrite, and keep the
  confirmation prompt / `--yes`.

## Migration (one-time)

For each existing worktree plus `master`:

1. Copy template skeleton to `.home/<slug>`.
2. Move `.docker-config/home/.claude-worktrees/<slug>` to
   `.home/<slug>/.claude` (preserves sessions, credentials, settings);
   rewrite paths inside `installed_plugins.json` / `known_marketplaces.json`
   (`.claude-worktrees/<slug>/plugins` → `.claude/plugins`). The old
   `agents`/`hooks` symlinks into the shared home break on the move —
   replace them with real copies from the template.
3. Optionally copy histories (`.zhistory`, `.irb_history`, `.psql_history`);
   they are disposable.

Once, globally (the template build comes first — the per-worktree steps
copy from it):

- Build the template from the current shared home: skeleton dotfiles plus
  the Claude config set from `.docker-config/home/.claude` (agents, hooks,
  skills, settings.json, keybindings.json, statusline-command.sh,
  CLAUDE.local.md, plugin bookkeeping json with project-scoped records
  stripped) and a sanitized copy of the shared `.claude.json`.
- Seed the shared volumes from the old home: `.npm`, `.npm-global`,
  `.local/share/nvim`, `.cache/ms-playwright`, `.claude/plugins/cache`,
  `.claude/plugins/marketplaces`.
- Keep `.docker-config/home` untouched until the new layout is confirmed
  working, then delete its contents.

## Out of scope

Per-worktree `node_modules` volume, `shared_gems`, the db/redis/rustfs/
playwright services, the proxy stack, and the `/status` dashboard wiring are
all unchanged.
