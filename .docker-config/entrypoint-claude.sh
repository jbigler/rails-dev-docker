#!/bin/bash
set -euo pipefail

# Run firewall setup as root via sudo (allowed by /etc/sudoers.d/firewall)
sudo /usr/local/bin/init-firewall.sh

# Configure Pencil MCP server
HOST_IP=$(ip route | awk '/default/ {print $3}')
claude mcp remove pencil -s user 2>/dev/null || true
claude mcp add --transport sse -s user pencil "http://${HOST_IP}:8089/sse" 2>/dev/null || true

# Bridge the playwright container's interactive-Chromium CDP endpoint onto loopback.
# Chrome's DevTools HTTP server rejects non-localhost/non-IP Host headers (DNS-rebinding
# guard), so chrome-devtools-mcp must connect via 127.0.0.1 rather than http://playwright.
# The browser itself is watchable/clickable at http://vnc.${DOMAIN}.
socat TCP-LISTEN:9222,bind=127.0.0.1,fork,reuseaddr TCP:playwright:9223 >/dev/null 2>&1 &

# Configure chrome-devtools MCP server against the bridged browser
claude mcp remove chrome-devtools -s user 2>/dev/null || true
claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222 2>/dev/null || true

# Initialize RTK
rtk init -g --auto-patch

# If first arg starts with '-' or no args given, run claude with skip-permissions
# Otherwise run the given command directly (e.g., /bin/zsh)
if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  exec claude --dangerously-skip-permissions "$@"
fi

ln -sf /usr/bin/claude /home/appuser/.local/bin/claude

exec "$@"
