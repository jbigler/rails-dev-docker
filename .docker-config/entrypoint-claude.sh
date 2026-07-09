#!/bin/bash
set -euo pipefail

# Run firewall setup as root via sudo (allowed by /etc/sudoers.d/firewall)
sudo /usr/local/bin/init-firewall.sh

# Configure MCP servers idempotently — the user-scope config lives in the
# home bind mount shared by every worktree's claude container, so a blind
# remove/re-add on each boot races concurrent boots.
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

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
# idempotently — settings.json lives in the same shared home mount, so only
# touch it when the hook is missing.
SETTINGS_JSON="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
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
cp /opt/claude/CLAUDE.md /home/appuser/.claude/CLAUDE.md

# Initialize RTK (also regenerates ~/.claude/RTK.md and re-adds the @RTK.md
# reference to the fresh CLAUDE.md copy)
rtk init -g --auto-patch

# If first arg starts with '-' or no args given, run claude with skip-permissions
# Otherwise run the given command directly (e.g., /bin/zsh)
if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  exec claude --dangerously-skip-permissions "$@"
fi

ln -sf /usr/bin/claude /home/appuser/.local/bin/claude

exec "$@"
