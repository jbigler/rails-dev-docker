#!/bin/zsh
set -xeuo pipefail

mkdir -p ~/.config
mkdir -p ~/.local

npm install -g mcp-hub@latest
npm install -g @herb-tools/language-server
npm install -g @agentclientprotocol/claude-agent-acp

export GIT_TERMINAL_PROMPT=0

# gh extensions live in the per-worktree home, so a fresh home has none.
# --force installs when missing, upgrades when stale, no-ops when current.
gh extension install github/gh-stack --force >/dev/null 2>&1 || true

# Neovim config is provided read-only by a host bind mount (${NVIM_CONFIG_DIR}).
# Plugins (lazy.nvim) install into the container's data dir on first launch.
if [[ ! -f ~/.config/nvim/init.lua ]]; then
	echo "WARN: ~/.config/nvim/init.lua not found — check NVIM_CONFIG_DIR mount" >&2
fi

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"
