#!/bin/bash
set -euo pipefail

# Run firewall setup as root via sudo (allowed by /etc/sudoers.d/firewall)
sudo /usr/local/bin/init-firewall.sh

# Configure Pencil MCP server
HOST_IP=$(ip route | awk '/default/ {print $3}')
claude mcp remove pencil -s user 2>/dev/null || true
claude mcp add --transport sse -s user pencil "http://${HOST_IP}:8089/sse" 2>/dev/null || true

# Initialize RTK
rtk init -g --auto-patch

# If first arg starts with '-' or no args given, run claude with skip-permissions
# Otherwise run the given command directly (e.g., /bin/zsh)
if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  exec claude --dangerously-skip-permissions "$@"
fi

exec "$@"
