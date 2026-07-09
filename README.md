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

If you already have the Rails app checked out (branches, uncommitted work, untracked files)
and don't want to re-clone, use `adopt.sh` instead of `bootstrap.sh`. It **moves** your
existing checkout in as the base worktree and leaves a **backward symlink** at the original
location, so your old path keeps working everywhere (editor, terminals, scripts).

```sh
# 1. Clone this wrapper next to your app
git clone https://github.com/jcarlos7121/rails-dev-docker.git ~/code/rails-dev

# 2. From the wrapper root, adopt your existing checkout
cd ~/code/rails-dev
./.scripts/adopt.sh [-p <prefix>] [-b <base-name>] /path/to/your/existing/checkout
```

- `-p <prefix>` = Docker volume/network prefix (defaults to the checkout's folder name)
- `-b <base-name>` = base worktree directory name (defaults to the folder name; set to your
  default branch, e.g. `-b master`, to match the clone-time convention)
- `<path>` = path to an existing Rails checkout (must be a git repo root)

What it does:

- **Moves** `/path/to/your/existing/checkout` to `./<base-name>` (physically under the wrapper
  root — required, since mise resolves config by physical path and the base must inherit the
  wrapper's `.mise` config + tasks), then symlinks the original path to it so it keeps resolving.
  A *forward* symlink (leaving the app in place) does **not** work: the base would resolve outside
  the root and mise couldn't find `PROJECT_PREFIX`/tasks.
- Writes a git-ignored `mise.local.toml` at the wrapper root with `PROJECT_PREFIX`, volume names,
  `DEV_DB_NAME` (auto-detected from `config/database.yml`, falling back to `<prefix>_development`),
  and `NVIM_CONFIG_DIR`.
- Renders the base worktree's `mise.local.toml` (ports/URLs) and locally git-ignores it in the app repo.
- Creates the external Docker volumes.

Then:

```sh
cd ~/code/rails-dev && mise trust && mise install
cd ~/code/rails-dev/<base-name> && mise trust && mise install && mise run up
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
- `mise run down` — tear down the current worktree's docker resources including its volumes (keeps the worktree folder and built images); run from a worktree
- `mise run proxy:up` (`proxy`) — start the shared Traefik proxy
- `mise run proxy:down` — stop the proxy
- `mise run proxy:logs` — tail proxy logs
- `mise run destroy` — remove every docker resource for this project and delete the project folder (run from project root or a worktree; prompts for confirmation)

### Worktrees

- `mise run wt <branch | PR# | new-branch>` — create a new git worktree with its own mise.local.toml and ports
- `mise run wt:ls` — list all worktrees
- `mise run wt:open [browser]` — open the current worktree URL (`xdg-open` by default)
- `mise run wt:rm <branch | dir-name>` — fully remove a worktree: its docker resources (containers, volumes, images, networks), git worktree registration, ports.registry entry, and folder (refuses on the base worktree)

### Development

- `mise run rails` — open a zsh shell in the running app container
- `mise run console` (`c`) — Rails console
- `mise run nvim` (`v`) — connect to the in-container Neovim via `--remote-ui`
- `mise run claude` (`ai`) — run Claude Code in the `claude` container (new Kitty tab if running inside Kitty, otherwise in the current terminal)
- `mise run claude:rebuild` — rebuild the Claude container with the latest Claude Code

### Tests / CI

- `mise run test` (`t`) — Retest watcher
- `mise run rails_tests [args]` (`rt`) — `bin/rails test`
- `mise run rails_system_tests [args]` (`rst`) — `bin/rails test:system`
- `mise run ci` — full CI lint + test pass (`rake ci:build:commit`)

### Database / RustFS snapshots

- `mise run db:dump` — dump dev DB and RustFS data into `.docker-config/db-dumps/` for fast container restarts
- `mise run db:dump:clear` — remove dump files so the next start does a full `db:prepare`

### Host-side Rails DB commands

You can run `bin/rails db:migrate`, `bin/rails console`, `bin/rails test`, `psql`, etc. **directly on the host** (not via `docker compose run`) and have them hit this worktree's containerized Postgres — while the app server stays containerized and browser-reachable.

How it works: each worktree's `db` container publishes Postgres on a per-worktree host port (`127.0.0.1:${DB_PORT}` where `DB_PORT = 55432 + WORKTREE_ID`), and `mise.local.toml` sets host-shell `PGHOST=127.0.0.1`, `PGPORT=${DB_PORT}`, `PGUSER`, `PGPASSWORD`. These `PG*` vars are host-only — they never enter the container (the `app` service reads `PGHOST` from `env_file`, the internal socket), so the container keeps using its socket. Rails picks development vs test automatically from `RAILS_ENV` (both databases live in the same container Postgres).

Requirements / notes:

- **A host bundle**: host-side `bin/rails` needs the gems installed for your host Ruby (`bundle install` on the host). The `pg` gem needs libpq (e.g. Homebrew `libpq`).
- The bind-mounted Postgres **UNIX socket does not work from the macOS host** (Docker Desktop VM boundary), which is why this uses a published TCP port.
- Per-worktree ports (55432, 55433, …) let multiple worktrees' databases run concurrently without collisions.
- After migrating, keep the test schema in sync (`bin/rails db:test:prepare`, or `RAILS_ENV=test bin/rails db:migrate`).
