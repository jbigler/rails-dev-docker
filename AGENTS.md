# AGENTS.md — filial-rails-core

Not Rails app. Thin orchestration wrapper. Manages Filial Rails via git worktrees. Provides per-worktree Docker  
dev/test stacks via mise tasks + shared Traefik proxy. Repo history unrelated to app.

> Read before touch .mise/, .scripts/, or .docker-config/.

## Layout

- master/ — base worktree (has .git dir); canonical app.
- <slug>/ — linked worktrees (have .git file).
- .scripts/ — bash helpers (worktree actions, bootstrap, lib).
- .mise/config.toml — mise tasks + base env; local.toml.template rendered per worktree.
- .mise/tasks/ — task files: wt/rm, tags.
- .docker-config/ — compose.yml (worktree), proxy/compose.yml (Traefik), Dockerfile, Dockerfile.playwright,  
  entrypoints, .env, initdb/, db-dumps/, init-firewall.sh.
- mise.local.toml — (root, git-ignored) set PROJECT_PREFIX, GEM_VOLUME_BASE, secrets.
- ports.registry — slug:WORKTREE_ID; source for port assignment.

## Worktree lifecycle

mise run wt <branch|PR#|new-branch> → .scripts/create-worktree.sh:

1. Resolve branch (PR# via gh), sanitize name (lower, no-alphanum→-, cap 40; hash suffix for collision).
2. Allocate next WORKTREE_ID = max(registry)+1, append slug:ID to ports.registry.
3. git worktree add (local/remote branch or new from HEAD).
4. Render mise.local.toml from .mise/local.toml.template (WORKTREE_ID).
5. Pre-create node_modules/ (prevent root ownership on mount).
6. Seed untracked files from master/ per .docker-config/worktree-seed.txt.
7. mise trust -y && mise install in new dir.

mise run wt:rm <branch|dir> → .scripts/remove-worktree.sh: reject base;  
reject dirty worktree unless FORCE=1; down compose project (down -v --rmi local);  
force-remove lingering containers/volumes/networks/images via label;  
delete ports.registry line; remove mise trust symlinks; rm -rf dir; git worktree prune.

mise run wt:ls list worktrees; mise run wt:open [browser] open link.

## Identity / Ports (from local.toml.template, ID = WORKTREE_ID)

- COMPOSE_PROJECT_NAME = filial-<slug> — isolate stacks.
- WORKTREE_HOST = <slug>.localhost; S3 = s3.<slug>.localhost; RustFS = s3-ui.<slug>.localhost; VNC =  
  vnc.<slug>.localhost. Traefik routes all.
- COMPOSE_FILE = base .docker-config/compose.yml + worktree .dev/compose.yml (if present).
- Ports: DB 55432+ID, Ruby debug 33000+ID, Neovim 17000+ID, Playwright 18888+ID.
- GEM*VOLUME = filial_shared_gems_ruby*<ver> (common across worktrees); same for node.
- DEV_DB_NAME from config/database.yml via .scripts/dev-db-name.sh (postgres; empty → manual).

## Docker stack (.docker-config/compose.yml)

- app — build rails target; mount ../<slug>:/app + base .git (ro); shared volumes; redis/db unix sockets via  
  ${SOCKET_DIR}; Traefik route WORKTREE_HOST→:3000; entrypoint entrypoint-app.sh then bin/dev.
- db — postgres:16, optimized (fsync off, autovacuum off); port 127.0.0.1:${DB_PORT}:5432; initdb/restore-dump.sh
  run on init.
- redis — unix socket only (--port 0), clear stale on boot.
- playwright — Dockerfile.playwright; run chromium.launchServer (headed via Xvfb + x11vnc+noVNC);  
  HEADLESS_SYSTEM_TESTS=1 for headless. server-side logic decides mode. Publish  
  127.0.0.1:${PLAYWRIGHT_HOST_PORT}:8888. Also run second interactive Chromium (always headed, same  
  display → same VNC page) with CDP :9222 loopback, socat republish :9223 for claude chrome-devtools MCP.
- rustfs — S3 storage, Traefik-routed.
- claude — claude target, profile do_not_start; NET_ADMIN/NET_RAW; entrypoint: init-firewall.sh, add MCP  
  (pencil; chrome-devtools via socat loopback bridge 127.0.0.1:9222→playwright:9223 — CDP rejects  
  non-localhost Host header), rtk init, then claude --dangerously-skip-permissions.

Volumes shared_gems, shared_node_modules, claude_config, claude_bashhistory are external. Networks: dev (bridge,  
MTU 1400) + proxy (external, ${PROJECT_PREFIX}\_proxy).

## Proxy (.docker-config/proxy/compose.yml)

One Traefik v3.7 stack (COMPOSE_PROJECT_NAME=filial-proxy).  
Docker provider, exposedByDefault=false, entrypoint web:80, dashboard :8080. Preserve encoded URL chars (S3).  
wt.localhost home page; wt.localhost/api→Traefik API. mise run up start proxy via depends=["proxy:up"].

## mise tasks (.mise/config.toml)

- up(u)/down/stop(s)/destroy: lifecycle. up check external volumes + clear postgres socket + start proxy. down  
  remove volumes. destroy nuke all filial[-_]\* resources + folder (confirm prompt).
- rails/console(c)/test(t)/rails_tests(rt)/rails_sytem_tests(rst)/ci: exec into app or docker compose run. Add  
  --label traefik.enable=false for non-routed tasks (avoid 502).
- nvim(v), claude(ai)/claude:rebuild, db:dump/db:dump:clear, tags, proxy:\*.

## Host-side Rails DB access

db publishes on 127.0.0.1:${DB_PORT}. Template sets host-shell only                                               
PGHOST=127.0.0.1/PGPORT=${DB_PORT}/PGUSER/PGPASSWORD. Host bin/rails/psql reach container DB via TCP. Inside  
containers, .docker-config/.env wins (unix socket). System tests run on host against container browser  
(PLAYWRIGHT_HOST=ws://localhost:port, APP_HOST=host.docker.internal).

## System tests (Playwright over VNC)

Use capybara-playwright-driver to Playwright browser server in playwright service. Container runs Xvfb + x11vnc +
noVNC; watch at http://vnc.<worktree>.localhost.

- Playwright >= 1.54: connect_to_playwright_server removed. Use connect_to_browser_server. Headless/Headed  
  decided server-side via chromium.launchServer.
- HEADLESS_SYSTEM_TESTS drives both paths: container launchServer (env) and client headless option (local).
- PLAYWRIGHT_HOST (.docker-config/.env) = ws://playwright:8888/connect; /connect matches entrypoint launchServer.
- Keep Playwright version sync across image, packages, gems.
- Infra changes require build & up for playwright.

## Conventions

- Dockerfile per service: if custom image needed, use .docker-config/Dockerfile.<service> and build: { context:  
  ., dockerfile: ... }. No multi-stage additions to base Dockerfile. Mount entrypoint scripts via volume. Keep  
  images decoupled.
- Env vars in Ruby: use ENV.fetch("KEY", default). Avoid ENV["KEY"] or .presence unless empty string specifically
  needed. Consistent ENV.fetch in config/initializers.

## Gotchas

- macOS virtiofs: bound unix sockets can't be chowned → entrypoints clear stale artifacts on boot.
- mise resolution: base worktree must live under wrapper root (adopt.sh moves + symlinks).
- init-firewall.sh: allowlist egress; codeload.github.com added for non-standard infra domains.
