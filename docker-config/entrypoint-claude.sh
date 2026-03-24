#!/bin/bash
set -euo pipefail

# Run firewall setup as root
/usr/local/bin/init-firewall.sh

# Fix ownership of external volumes
chown -R appuser:appgroup /home/appuser/.claude /commandhistory

# Drop to appuser for the actual command
exec gosu appuser "$@"
