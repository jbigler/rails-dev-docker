# AGENTS.md — filial-rails-core

This repo is **not** the Rails app. It is a thin orchestration wrapper that manages the
Filial Rails app, checked out as git **worktrees**, and provides per-worktree Docker
dev/test stacks driven by **mise** tasks behind a shared **Traefik** proxy. This repo's
git history is unrelated to the app's git history.

> Read this before touching `.mise/`, `.scripts/`, or `.docker-config/`.

## Layout

- `master/` — base worktree (has a `.git` **directory**); the canonical app checkout.
- `<slug>/` — linked worktrees (have a `.git` **file**), one dir per branch/PR.
- `.scripts/` — bash helpers (worktree create/remove, bootstrap/adopt, lib).
- `.mise/config.toml` — all mise tasks + base env; `.mise/local.toml.template` is rendered per worktree.
- `.mise/tasks/` — file-based tasks: `wt/rm`, `tags`.
- `.docker-config/` — `compose.yml` (per-worktree stack), `proxy/compose.yml` (shared Traefik), `Dockerfile`, `Dockerfile.playwright`, entrypoints, `.env`, `initdb/`, `db-dumps/`, `init-firewall.sh`.
- `mise.local.toml` (root, git-ignored) — sets `PROJECT_PREFIX=filial`, `GEM_VOLUME_BASE`, secrets.
- `ports.registry` — `slug:WORKTREE_ID` lines; source of truth for port allocation.

## Worktree lifecycle

`mise run wt <branch|PR#|new-branch>` → `.scripts/create-worktree.sh`:
1. Resolves branch (PR# via `gh`), sanitizes name (lowercase, non-alnum→`-`, cap 40 chars; hash-suffix on dir collision).
2. Allocates next `WORKTREE_ID` = max(registry)+1, appends `slug:ID` to `ports.registry`.
3. `git worktree add` (existing local/remote branch, or new branch off current HEAD).
4. Renders `mise.local.toml` from `.mise/local.toml.template` (substitutes `WORKTREE_ID`).
5. Pre-creates `node_modules/` so the shared volume mount isn't root-owned.
6. Seeds untracked files from `master/` per `.docker-config/worktree-seed.txt` (`.env.local`, `config/master.key`, `config/credentials/*.key`, `.dev/compose.yml`).
7. `mise trust -y && mise install` in the new dir.

`mise run wt:rm <branch|dir>` → `.scripts/remove-worktree.sh`: refuses base worktree;
refuses dirty worktree unless `FORCE=1`; tears down the compose project (`down -v --rmi local`);
force-removes lingering containers/volumes/networks/images by compose-project label;
deletes the `ports.registry` line; removes mise trust symlinks; `rm -rf` dir; `git worktree prune`.

`mise run wt:ls` lists worktrees; `mise run wt:open [browser]` opens the worktree URL.

## Per-worktree identity / ports (from local.toml.template, ID = WORKTREE_ID)

- `COMPOSE_PROJECT_NAME` = `filial-<slug>` — isolates each stack.
- `WORKTREE_HOST` = `<slug>.localhost`; S3 = `s3.<slug>.localhost`; RustFS UI = `s3-ui.<slug>.localhost`; VNC = `vnc.<slug>.localhost`. All routed by Traefik (no published app port).
- `COMPOSE_FILE` = base `.docker-config/compose.yml` **plus** the worktree's `.dev/compose.yml` if present (local overrides).
- Per-worktree host ports: DB `55432+ID`, Ruby debug `33000+ID`, Neovim `17000+ID`, Playwright `18888+ID`.
- `GEM_VOLUME` = `filial_shared_gems_ruby_<ver>` (shared across worktrees per ruby version); same for node_modules.
- `DEV_DB_NAME` parsed from `config/database.yml` via `.scripts/dev-db-name.sh` (postgres only; empty → set manually).

## Docker stack (.docker-config/compose.yml services)

- `app` — built `rails` target; bind-mounts `../<slug>:/app` + base `.git` (ro); shared_gems + shared_node_modules volumes; redis/db unix sockets via `${SOCKET_DIR}`; Traefik labels route `WORKTREE_HOST`→:3000; runs `entrypoint-app.sh` then `bin/dev`.
- `db` — postgres:16, tuned for speed (fsync off, autovacuum off, etc.); publishes `127.0.0.1:${DB_PORT}:5432`; `initdb/restore-dump.sh` restores dumps on first init.
- `redis` — unix socket only (`--port 0`), clears stale socket on boot.
- `playwright` — `Dockerfile.playwright`; runs `chromium.launchServer` (headed by default into Xvfb, viewable via x11vnc+noVNC over the VNC host); `HEADLESS_SYSTEM_TESTS=1` for headless. launchServer decides headed/headless server-side, not the client. Publishes `127.0.0.1:${PLAYWRIGHT_HOST_PORT}:8888`.
- `rustfs` (+ `rustfs-init` restore) — S3-compatible storage, Traefik-routed.
- `claude` — `claude` target, profile `do_not_start` (only via `mise run claude`); `NET_ADMIN`/`NET_RAW`; entrypoint runs `init-firewall.sh` (egress allowlist), adds MCP servers, `rtk init`, then `claude --dangerously-skip-permissions`.

Volumes `shared_gems`, `shared_node_modules`, `claude_config`, `claude_bashhistory` are
**external** (created by `up`). Networks: `dev` (bridge, MTU 1400 for VPN) + `proxy`
(external, `${PROJECT_PREFIX}_proxy`).

## Proxy (.docker-config/proxy/compose.yml)

One shared Traefik v3.7 stack for all worktrees (`COMPOSE_PROJECT_NAME=filial-proxy`).
Docker provider, `exposedByDefault=false`, entrypoint web:80, dashboard :8080. Preserves
encoded URL chars (S3 signed URLs). `wt.localhost` serves a worktree home page;
`wt.localhost/api`→Traefik internal API. `mise run up` auto-starts it via `depends=["proxy:up"]`.

## Key mise tasks (.mise/config.toml)

- `up`(u)/`down`/`stop`(s)/`destroy` — lifecycle. `up` ensures external volumes + clears stale postgres socket + starts proxy. `down` removes volumes too. `destroy` nukes all `filial[-_]*` docker resources + the folder (confirm prompt).
- `rails`/`console`(c)/`test`(t)/`rails_tests`(rt)/`rails_sytem_tests`(rst)/`ci` — exec into running app or `docker compose run` if not running. One-offs add `--label traefik.enable=false` so Traefik doesn't round-robin onto them (else 502s).
- `nvim`(v), `claude`(ai)/`claude:rebuild`, `db:dump`/`db:dump:clear`, `tags`, `proxy:*`.

## Host-side Rails DB access

Each `db` publishes Postgres on `127.0.0.1:${DB_PORT}`; the template sets **host-shell only**
`PGHOST=127.0.0.1`/`PGPORT=${DB_PORT}`/`PGUSER`/`PGPASSWORD`, so host `bin/rails`/`psql`
reach this worktree's containerized DB over TCP. Inside containers `.docker-config/.env`
wins (unix socket `PGHOST=/var/run/postgresql`). System tests can run on the host against
the containerized browser (`PLAYWRIGHT_HOST`=ws://localhost:port, `APP_HOST`=host.docker.internal).

## System tests (Playwright over VNC)

System tests use `capybara-playwright-driver` connecting to a Playwright **browser server**
in the `playwright` service. The container runs Xvfb + x11vnc + noVNC; the run is watchable
live at `http://vnc.<worktree>.localhost` (the "system tests" link on the `wt.localhost` dashboard).

- **Playwright >= 1.54:** `connect_to_playwright_server` is removed — only `connect_to_browser_server` works, and it does **not** call `browser_type.launch`, so the client's `headless:` option is ignored. Headed/headless is decided server-side at `chromium.launchServer({ headless: ... })` time.
- `HEADLESS_SYSTEM_TESTS` drives both paths: the container's `launchServer` reads it (compose env, read at `mise run up` time; `=1` → headless, default `0`/headed for VNC), and the client `headless:` option uses it for local in-process Playwright.
- `PLAYWRIGHT_HOST` (`.docker-config/.env`) = `ws://playwright:8888/connect`; `/connect` matches the `wsPath` in the entrypoint's `launchServer`.
- Keep the Playwright version in lockstep across: image tag, `playwright-core`, `playwright-chromium` (package.json), `playwright-ruby-client` (Gemfile.lock).
- Infra changes (`.docker-config/*`) apply to all worktrees but need a per-worktree `docker compose build playwright && docker compose up -d playwright`.

## Conventions

- **Dockerfile per service:** when a compose service needs a custom image, create a dedicated `Dockerfile.<service>` in `.docker-config/` and reference it via `build: { context: ., dockerfile: ... }` — do **not** add another target stage to the shared multi-stage `Dockerfile` (which holds base/rails/nvim/claude). Mount runtime entrypoint scripts via compose volumes (the `entrypoint-app.sh` pattern) instead of COPYing them. Keeps unrelated images decoupled.
- **Env vars in Ruby:** use `ENV.fetch("KEY", default)` with the actual fallback as the second arg. Don't use `ENV["KEY"]` or layer `.presence ||` unless an explicit empty-string-set case truly needs handling. `config/environments/*.rb` and `config/initializers/*.rb` use `ENV.fetch` consistently.

## Gotchas

- macOS virtiofs: bind-mounted unix sockets can't be chowned → entrypoints clear stale postgres/redis/puma/X11 artifacts on boot.
- mise resolves config by **physical path**; the base worktree must live physically under the wrapper root (adopt.sh moves + back-symlinks).
- `init-firewall.sh` (claude container) allowlists egress; `codeload.github.com` was added (archive downloads use IPs outside GitHub meta web/api/git ranges).
