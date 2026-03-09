#!/bin/zsh
set -xeuo pipefail

mkdir -p ~/.config
mkdir -p ~/.local

export GIT_TERMINAL_PROMPT=0

if [[ ! -f ~/.config/nvim/init.lua ]]; then
	git clone --depth 1 https://github.com/jbigler/AstroNvim ~/.config/nvim
else
	git -C ~/.config/nvim remote set-url origin https://github.com/jbigler/AstroNvim.git
	git -C ~/.config/nvim pull --ff-only
fi

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"
