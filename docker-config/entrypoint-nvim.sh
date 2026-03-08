#!/bin/zsh
set -xeuo pipefail

mkdir -p ~/.config
mkdir -p ~/.local

if [[ ! -f ~/.config/nvim/init.lua ]]; then
	git clone --depth 1 https://github.com/jbigler/AstroNvim ~/.config/nvim
else
	git -C ~/.config/nvim pull
fi

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"
