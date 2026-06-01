# Ruby on Rails Docker-based Development Environment

## Requirements

- Docker
- Mise
- Neovim (optional)
- Github CLI (optional, set GH_TOKEN securely in your environment)

## Installation

`curl -fsSL https://raw.githubusercontent.com/jbigler/rails-dev-docker/main/.scripts/bootstrap.sh | sh -s -- [-p prefix] user/repo`

- `prefix` = optional name for project/folder (will use repo name by default)
- `user/repo` = Github user/repo (or a full URL to git repository)

### Adopt an existing local checkout

If you already have the Rails app checked out and want to keep that folder in place
(branches, uncommitted work, untracked files), use `adopt.sh` instead of `bootstrap.sh`.
It **symlinks** your existing checkout in as the base worktree rather than cloning a fresh copy.

```sh
# 1. Clone this wrapper next to your app
git clone https://github.com/jcarlos7121/rails-dev-docker.git ~/code/rails-dev

# 2. From the wrapper root, adopt your existing checkout
cd ~/code/rails-dev
./.scripts/adopt.sh [-p <prefix>] /path/to/your/existing/checkout
```

- `-p <prefix>` = optional Docker volume/network prefix (defaults to the checkout's folder name)
- `<path>` = path to an existing Rails checkout (must be a git repo root)

What it does (all non-destructive; the original folder is never moved):

- Creates a symlink `./<app-basename> -> /path/to/your/existing/checkout` as the base worktree (ID 0).
  The symlink **must** match the checkout's real folder name — git resolves it to the real path, and
  the Docker bind-mount is derived from that name.
- Writes a git-ignored `mise.local.toml` at the wrapper root with `PROJECT_PREFIX`, volume names,
  `DEV_DB_NAME` (auto-detected from `config/database.yml`, falling back to `<prefix>_development`),
  and `NVIM_CONFIG_DIR`.
- Renders the base worktree's `mise.local.toml` (ports/URLs) and locally git-ignores it in the app repo.
- Creates the external Docker volumes.

Then:

```sh
cd ~/code/rails-dev && mise trust && mise install
cd ~/code/rails-dev/<app-basename> && mise trust && mise install && mise run up
```

Notes:

- **Per-worktree files:** list untracked files (e.g. `.env.local`, `config/master.key`) in
  `.docker-config/worktree-seed.txt`; each new worktree gets its own copy from the base worktree.
- **Symlinked nvim configs:** if your `~/.config/nvim` contains symlinks (e.g. into a dotfiles repo),
  set `NVIM_CONFIG_DIR` in `mise.local.toml` to the real directory so the in-container mount doesn't
  dangle.

## Mise tasks

Run from a worktree directory unless noted otherwise. Aliases shown in parentheses.

_Tip: Set a shell alias for "mise run" to "mr"._

### Lifecycle

- `mise run up` (`u`) — start the app (ensures external volumes, brings up the proxy first)
- `mise run proxy:up` (`proxy`) — start the shared Traefik proxy
- `mise run proxy:down` — stop the proxy
- `mise run proxy:logs` — tail proxy logs
- `mise run destroy` — remove every docker resource for this project and delete the project folder (run from project root or a worktree; prompts for confirmation)

### Worktrees

- `mise run wt <branch | PR# | new-branch>` — create a new git worktree with its own mise.local.toml and ports
- `mise run wt:ls` — list all worktrees
- `mise run wt:open [browser]` — open the current worktree URL (`xdg-open` by default)

### Development

- `mise run rails` — open a zsh shell in the running app container
- `mise run console` (`c`) — Rails console
- `mise run nvim` (`v`) — connect to the in-container Neovim via `--remote-ui`
- `mise run claude` (`ai`) — run Claude Code in the `claude` container (new Kitty tab if running inside Kitty, otherwise in the current terminal)
- `mise run claude:rebuild` — rebuild the Claude container with the latest Claude Code

### Tests / CI

- `mise run test` (`t`) — Retest watcher
- `mise run rails_tests [args]` (`rt`) — `bin/rails test`
- `mise run rails_sytem_tests [args]` (`rst`) — `bin/rails test:system`
- `mise run ci` — full CI lint + test pass (`rake ci:build:commit`)

### Database / RustFS snapshots

- `mise run db:dump` — dump dev DB and RustFS data into `.docker-config/db-dumps/` for fast container restarts
- `mise run db:dump:clear` — remove dump files so the next start does a full `db:prepare`
