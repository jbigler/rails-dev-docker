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
  entrypoints, .env, initdb/, db-dumps/, init-firewall.sh, home-template/ (seeds .home/<slug>).
- .home/ — (git-ignored) per-worktree container home dirs, seeded from .docker-config/home-template/.
- .docker-config/claude-memory/ — (git-ignored) Claude's file memory, shared by every worktree
  container and by host sessions (which symlink to it); outside .home/ so wt:rm can't delete it.
- mise.local.toml — (root, git-ignored) set PROJECT_PREFIX, GEM_VOLUME_BASE, secrets.
- ports.registry — slug:WORKTREE_ID; source for port assignment.

## Worktree lifecycle

mise run wt <branch|PR#|new-branch> → .scripts/create-worktree.sh:

1. Resolve branch (PR# via gh), sanitize name (lower, no-alphanum→-, cap 40; hash suffix for collision).
2. git worktree add (local/remote branch or new from HEAD).
3. Allocate next WORKTREE_ID = max(registry)+1, append slug:ID to ports.registry (only after add succeeds).
4. Render mise.local.toml from .mise/local.toml.template (WORKTREE_ID).
5. Pre-create node_modules/ (prevent root ownership on mount).
6. Seed untracked files from master/ per .docker-config/worktree-seed.txt.
7. mise trust -y && mise install in new dir.

mise run wt:rm <branch|dir> → .scripts/remove-worktree.sh: reject base;  
reject dirty worktree unless FORCE=1; down compose project (down -v --rmi local);  
force-remove lingering containers/volumes/networks/images via label; delete .home/<slug>  
(guarded — holds a live Claude OAuth token, not just clutter); delete ports.registry line;  
remove mise trust symlinks; scoped `git worktree remove --force`  
(never a blanket `git worktree prune` — see Gotchas). Aborts up front if any registered worktree  
dir is missing (partial filesystem view, e.g. the container).

mise run wt:ls list worktrees; mise run wt:open [browser] open link.

mise run wt:share / wt:unshare → .scripts/share-worktree.sh: expose ONE worktree over the tailnet for
phone testing. tailscale serve fronts the rails (:443) and rustfs (:8443) containers by docker IP —
no published ports, Traefik bypassed. A /tmp compose override (injected via COMPOSE_FILE) sets DOMAIN
to the ts.net name, DEV_HOSTS to WORKTREE_HOST so the desktop .localhost URL keeps working, and
RUSTFS_ENDPOINT to the tailnet S3 host so presigned URLs resolve off-box. Overrides must be container
env, not .env.development: compose.yml already sets DOMAIN/RUSTFS_ENDPOINT and dotenv never overwrites
an existing ENV var. Re-run after `down && up` — container IPs move. `off` calls `tailscale serve
reset`, which clears every serve on the machine, not just these.

## Identity / Ports (from local.toml.template, ID = WORKTREE_ID)

- COMPOSE_PROJECT_NAME = filial-<slug> — isolate stacks.
- WORKTREE_HOST = <slug>.localhost; S3 = s3.<slug>.localhost; RustFS = s3-ui.<slug>.localhost; VNC =  
  vnc.<slug>.localhost. Traefik routes all.
- COMPOSE_FILE = base .docker-config/compose.yml + worktree .dev/compose.yml (if present).
- Ports: DB 55432+ID, Ruby debug 33000+ID, Neovim 17000+ID, Playwright 18888+ID.
- GEM*VOLUME = filial_shared_gems_ruby*<ver> (common across worktrees). node_modules per worktree  
  (compose-prefixed volume); npm cache shared via the ${PROJECT_PREFIX}_npm_cache volume.
- DEV_DB_NAME from config/database.yml via .scripts/dev-db-name.sh (postgres; empty → manual).

## Docker stack (.docker-config/compose.yml)

- rails — build rails target; mount ../<slug>:/app + base .git (ro); shared volumes; db/redis over TCP  
  (PGHOST=db, REDIS_URL=redis://redis:6379/1 in .env); Traefik route WORKTREE_HOST→:3000; entrypoint  
  entrypoint-app.sh then bin/dev.  
  rails/nvim/playwright/claude use shared image: tags (${PROJECT_PREFIX}/rails:ruby<ver>-node<ver> etc.) —  
  one image per runtime combo across worktrees, not one per compose project.
- db — postgres:16, optimized (fsync off, autovacuum off); port 127.0.0.1:${DB_PORT}:5432; initdb/restore-dump.sh
  run on init.
- redis — TCP 6379 on the dev network only, not published to the host; no persistence (--save '' --appendonly no).
- playwright — Dockerfile.playwright; run chromium.launchServer (headed via Xvfb + x11vnc+noVNC);  
  HEADLESS_SYSTEM_TESTS=1 for headless. server-side logic decides mode. Publish  
  127.0.0.1:${PLAYWRIGHT_HOST_PORT}:8888. Also run second interactive Chromium (always headed, same  
  display → same VNC page) with CDP :9222 loopback, socat republish :9223 for claude chrome-devtools MCP.  
  Egress firewalled (init-firewall-playwright.sh, NET_ADMIN): loopback + RFC1918 only — browser can't  
  reach internet (else it bypasses claude's firewall).
- rustfs — S3 storage, Traefik-routed.
- claude — claude target, profile do_not_start; NET_ADMIN/NET_RAW; worktree mounted at /app-<slug>  
  (not /app — kept so host paths differ per worktree in prompts/logs, even though homes are  
  per-worktree now); home is a per-worktree bind mount (../.home/<slug>:/home/appuser), plain  
  ~/.claude (no override env var); entrypoint: init-firewall.sh, add MCP  
  (pencil; chrome-devtools via socat loopback bridge 127.0.0.1:9222→playwright:9223 — CDP rejects  
  non-localhost Host header), rtk init, then claude --dangerously-skip-permissions.  
  Global memory: committed .docker-config/CLAUDE.md mounted ro → /home/appuser/.claude/CLAUDE.md  
  (browser/MCP + rtk instructions); imports optional CLAUDE.local.md (gitignored  
  .home/<slug>/.claude/) for user-local instructions.  
  File memory: ../.docker-config/claude-memory bind-mounted over  
  ~/.claude/projects/-app-<slug>/memory — the one dir every worktree and host session shares.

Volume shared_gems is external; node_modules is per-worktree. Networks: dev (bridge,  
MTU 1400) + proxy (external, ${PROJECT_PREFIX}\_proxy).

## Proxy (.docker-config/proxy/compose.yml)

One Traefik v3.7 stack (COMPOSE_PROJECT_NAME=filial-proxy).  
Docker provider, exposedByDefault=false, entrypoint web:80, dashboard :8080. Preserve encoded URL chars (S3).  
wt.localhost home page; wt.localhost/api→Traefik API; logs.localhost→Dozzle (live logs, all project  
containers, DOZZLE_FILTER=name=${PROJECT_PREFIX}). mise run up start proxy via depends=["proxy:up"].  
wt.localhost cards show claude badge (working/waiting): claude-status-hook.sh (hook events, registered  
idempotently by entrypoint-claude.sh into shared settings.json) writes .docker-config/status/<slug>.json  
(git-ignored); home nginx serves it at /status/ (JSON autoindex, home-nginx.conf). wt:rm cleans the file.  
Host ports (80/8080, also nvim/ruby-debug in worktree stack) bind 127.0.0.1 only — Host-header routing would  
otherwise expose all worktrees + password-less VNC to LAN. Containers can't reach loopback-bound host ports, so  
Traefik has static IP TRAEFIK_IP (default 10.213.0.2, subnet PROXY_SUBNET) on proxy net; worktree extra_hosts  
point WORKTREE_HOST/S3/UI there instead of host-gateway.

## mise tasks (.mise/config.toml)

- up(u)/down/stop(s)/destroy: lifecycle. up check external volumes + start proxy. down  
  remove volumes. destroy nuke all filial[-_]\* resources + folder (confirm prompt).
- rails/console(c)/ci: exec into the rails service or docker compose run. Add  
  --label traefik.enable=false for non-routed tasks (avoid 502).
- test(t) = test:rails then test:javascript, sequential (array run, not depends — depends is parallel).  
  test:rails(tr)/test:rails_watcher(trw, retest)/test:rails_system(trs) forward args to bin/rails;  
  test:javascript(tj)/test:javascript_watcher(tjw) forward args to npx vitest (Vitest + jsdom, no DB, so no depends=up).  
  All exec into a running rails service, else docker compose run --rm.
- nvim(v), claude(ai)/claude:newterm(ai:newterm)/claude:rebuild, db:dump/db:dump:clear, tags, proxy:\*.
- log:trim: truncate (never unlink — a container may hold it open) any */log/\*.log over 100 MB across
  every worktree. log/test.log is appended by every run and never rotated; a depends of the test:rails\*
  tasks. Container stdout is capped separately by the x-logging anchor (json-file, 20m x 3) in both
  compose files — json-file is unbounded by default. Applies on the next up (recreate), not stop/start.
- claude:template:promote/claude:template:apply: sync the Claude config set (agents, hooks, skills,  
  settings, plugin records) between a worktree home and .docker-config/home-template — promote pushes  
  this worktree's config to the template (merges plugin records unless --replace); apply copies the  
  template onto this worktree's home (or --all for every home); apply never touches credentials,  
  sessions, or other state.
- claude runs in the current window; CLAUDE_NEW_TERM=1 or claude:newterm delegates to
  .scripts/claude-newterm.sh, which detects the host terminal (env fingerprint, then process tree) then
  escalates: new tab (tmux/kitty/wezterm/konsole/gnome-terminal/xfce4-terminal/terminator/iTerm2) → new
  window of that same terminal → new window of any emulator found ($TERMINAL first, then kitty, wezterm,
  ghostty, alacritty, foot, konsole, gnome-terminal, xfce4-terminal, terminator, xterm) → current window
  only when nothing is launchable (no emulator, or no DISPLAY/WAYLAND_DISPLAY off macOS).

## Host-side Rails DB access

db publishes on 127.0.0.1:${DB_PORT}. Template sets host-shell only                                               
PGHOST=127.0.0.1/PGPORT=${DB_PORT}/PGUSER/PGPASSWORD. Host bin/rails/psql reach container DB via TCP. Inside  
containers, .docker-config/.env wins (PGHOST=db over the dev network). System tests run on host against container browser  
(PLAYWRIGHT_HOST=ws://localhost:port, APP_HOST=host.docker.internal).

## System tests (Playwright over VNC)

Use capybara-playwright-driver to Playwright browser server in playwright service. Container runs Xvfb + x11vnc +
noVNC; watch at http://vnc.<worktree>.localhost.

- Playwright >= 1.54: connect_to_playwright_server removed. Use connect_to_browser_server. Headless/Headed  
  decided server-side via chromium.launchServer.
- HEADLESS_SYSTEM_TESTS drives both paths: container launchServer (env) and client headless option (local).
- PLAYWRIGHT_HOST (.docker-config/.env) = ws://playwright:8888/connect; /connect matches entrypoint launchServer.
- Playwright version derived per worktree from Gemfile.lock (playwright-version.sh → PLAYWRIGHT_VERSION →  
  image tag v<ver>-noble + npm playwright-core). Gem bump → next `up` builds the matching image. `up` warns  
  when PLAYWRIGHT_VERSION is empty (stale mise.local.toml).
- Infra changes require build & up for playwright.

## Conventions

- Dockerfile per service: if custom image needed, use .docker-config/Dockerfile.<service> and build: { context:  
  ., dockerfile: ... }. No multi-stage additions to base Dockerfile. Mount entrypoint scripts via volume. Keep  
  images decoupled.
- Env vars in Ruby: use ENV.fetch("KEY", default). Avoid ENV["KEY"] or .presence unless empty string specifically
  needed. Consistent ENV.fetch in config/initializers.

## Gotchas

- Worktree removal must stay scoped. `git worktree prune` deletes the admin entry of every worktree whose dir  
  isn't found on disk — from a partial filesystem view (e.g. a container mounting only master/ + one worktree)  
  that is ALL of them, purging the whole registry and disconnecting every worktree from its branch. wt:rm uses  
  scoped `git worktree remove` and aborts on a partial view; keep it that way, never a blanket prune. To recover  
  a purged registry: rebuild each master/.git/worktrees/<name>/ (commondir `../..`, gitdir → the worktree's .git  
  file, HEAD → its branch), then `git worktree repair` and `git reset` in each worktree.
- ssh-agent into nvim/claude: SSH_AGENT_SOCK (.mise/config.toml) picks the host socket per OS — $SSH_AUTH_SOCK on  
  Linux, /run/host-services/ssh-auth.sock on macOS (host sockets don't cross the Docker Desktop VM boundary;  
  Docker Desktop re-exposes the agent at that fixed path). Mac users must load the key into the host agent  
  (ssh-add --apple-use-keychain ~/.ssh/id_rsa). No agent → /dev/null mount, containers still start, ssh just  
  reports no agent and falls back to a passphrase prompt.
- mise resolution: base worktree must live under wrapper root (adopt.sh moves + symlinks).
- init-firewall.sh: allowlist egress; codeload.github.com added for non-standard infra domains.
