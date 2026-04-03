#!/bin/bash
set -euo pipefail

# Run firewall setup as root
/usr/local/bin/init-firewall.sh

# Fix ownership of external volumes
chown -R appuser:appgroup /home/appuser/.claude /home/appuser/.npm-global /commandhistory

# Configure Pencil MCP server
HOST_IP=$(ip route | awk '/default/ {print $3}')
gosu appuser claude mcp remove pencil -s user 2>/dev/null || true
gosu appuser claude mcp add --transport sse -s user pencil "http://${HOST_IP}:8089/sse" 2>/dev/null || true

# Drop to appuser for the actual command
exec gosu appuser "$@"
