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

# Neovim config arrives read-only from a host bind mount (${NVIM_CONFIG_DIR}),
# and plugins install into ~/.local/share/nvim -- a named volume, so empty on a
# new workspace. "Comes up bare" has those two very different causes and the old
# check could not tell them apart: it tested only init.lua, so an init.vim config
# warned spuriously, and it said nothing about the plugin dir at all.
if [[ -z "$(ls -A ~/.config/nvim 2>/dev/null)" ]]; then
	echo "WARN: ~/.config/nvim is empty or missing inside the container." >&2
	echo "      The bind mount did not land. Check that NVIM_CONFIG_DIR points at" >&2
	echo "      a real directory on the host, then: mise run units:env && mise run units:install" >&2
elif [[ ! -f ~/.config/nvim/init.lua && ! -f ~/.config/nvim/init.vim ]]; then
	echo "WARN: ~/.config/nvim has no init.lua or init.vim, so nvim will load no config." >&2
	echo "      Contents: $(ls -A ~/.config/nvim | tr '\n' ' ')" >&2
else
	echo "nvim config mounted: $(ls -A ~/.config/nvim | wc -l) entries" >&2
fi

# Plugins are the other reason for a bare editor, and the fix is different.
if [[ -z "$(ls -A ~/.local/share/nvim 2>/dev/null)" ]]; then
	echo "note: ~/.local/share/nvim is empty, so no plugins are installed yet." >&2
	echo "      Your plugin manager installs them when the server first loads the" >&2
	echo "      config; a headless server may need it driven explicitly, e.g." >&2
	echo "      mise run exec nvim --headless '+Lazy! sync' +qa" >&2
fi

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"
