#!/bin/bash
set -euo pipefail

# Run firewall setup as root via sudo (allowed by /etc/sudoers.d/firewall)
sudo /usr/local/bin/init-firewall.sh

# The home directory is per-worktree (.home/<slug> on the host), so the
# default ~/.claude is already isolated: credentials, sessions and plugin
# records never cross worktrees. The plugin cache and marketplaces are
# cross-worktree volumes mounted inside ~/.claude/plugins by compose.
CONFIG_DIR="$HOME/.claude"
mkdir -p "$CONFIG_DIR"

# Configure MCP servers idempotently — the guard avoids rewriting the file
# on every boot. Claude reads this from the home root (~/.claude.json), not
# the config dir, when CLAUDE_CONFIG_DIR is unset.
CLAUDE_JSON="$HOME/.claude.json"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

# Record the install method — the image pins a native binary under
# /opt/claude-code, but nothing ever wrote that into the config, so /doctor
# warns "install method is 'not set'" in every fresh home.
if ! jq -e '.installMethod == "native"' "$CLAUDE_JSON" >/dev/null 2>&1; then
  tmp="${CLAUDE_JSON}.tmp.$$"
  jq '.installMethod = "native"' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
fi

# Pre-trust this worktree's project dir. The mount point is per-worktree
# (/app-<slug>), so without this every new worktree's first interactive
# session stops at the "Do you trust the files in this folder?" dialog.
if ! jq -e --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted == true' "$CLAUDE_JSON" >/dev/null 2>&1; then
  tmp="${CLAUDE_JSON}.tmp.$$"
  jq --arg p "$PWD" \
    '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})' \
    "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
fi

# Pencil MCP server (reconfigure only when the host IP changed)
HOST_IP=$(ip route | awk '/default/ {print $3}')
PENCIL_URL="http://${HOST_IP}:8089/sse"
if [ "$(jq -r '.mcpServers.pencil.url // empty' "$CLAUDE_JSON" 2>/dev/null)" != "$PENCIL_URL" ]; then
  claude mcp remove pencil -s user 2>/dev/null || true
  claude mcp add --transport sse -s user pencil "$PENCIL_URL" 2>/dev/null || true
fi

# Bridge the playwright container's interactive-Chromium CDP endpoint onto loopback.
# Chrome's DevTools HTTP server rejects non-localhost/non-IP Host headers (DNS-rebinding
# guard), so chrome-devtools-mcp must connect via 127.0.0.1 rather than http://playwright.
# The browser itself is watchable/clickable at http://vnc.${DOMAIN}.
socat TCP-LISTEN:9222,bind=127.0.0.1,fork,reuseaddr TCP:playwright:9223 >/dev/null 2>&1 &

# Configure chrome-devtools MCP server against the bridged browser
if ! jq -e '.mcpServers["chrome-devtools"]' "$CLAUDE_JSON" >/dev/null 2>&1; then
  claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222 2>/dev/null || true
fi

# Register the status hook (claude badge on the wt.localhost dashboard)
# idempotently — only touch settings.json when the hook is missing.
SETTINGS_JSON="$CONFIG_DIR/settings.json"
[ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
if ! grep -q claude-status-hook "$SETTINGS_JSON"; then
  tmp="${SETTINGS_JSON}.tmp.$$"
  jq '
    def entry: {hooks: [{type: "command", command: "/usr/local/bin/claude-status-hook.sh", timeout: 5}]};
    .hooks = reduce ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd") as $e
      (.hooks // {}; .[$e] = ((.[$e] // []) + [entry]))
  ' "$SETTINGS_JSON" > "$tmp" && mv "$tmp" "$SETTINGS_JSON"
fi

# Refresh global memory from the committed copy (.docker-config/CLAUDE.md).
# Plain copy, not a bind mount at this path: rtk init rewrites CLAUDE.md via
# temp-file + rename, which fails on a file that is itself a mount point.
cp /opt/claude/CLAUDE.md "$CONFIG_DIR/CLAUDE.md"

# Initialize RTK (regenerates RTK.md inside this worktree's dir and re-adds
# the @RTK.md reference to the fresh CLAUDE.md copy)
rtk init -g --auto-patch

# gh extensions live in the per-worktree home, so a fresh home has none.
# --force installs when missing, upgrades when stale, no-ops when current.
gh extension install github/gh-stack --force >/dev/null 2>&1 || true

# ~/.local/bin/claude keeps PATH and /doctor's native-install check happy; a
# freshly seeded per-worktree home has no .local/bin, so create both every
# boot (previously this ran only on the non-interactive branch, after exec).
mkdir -p /home/appuser/.local/bin
ln -sf /usr/bin/claude /home/appuser/.local/bin/claude

# If first arg starts with '-' or no args given, run claude with skip-permissions
# Otherwise run the given command directly (e.g., /bin/zsh)
if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  exec claude --dangerously-skip-permissions "$@"
fi

exec "$@"
