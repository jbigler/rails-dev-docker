#!/bin/zsh
set -euo pipefail
# No -x by default: it was the only entrypoint of the four that traced, and the
# trace interleaves with its own output -- a diagnostic line came out as
# "nvim_entries=+...> ls -A", which defeats the point of having one. The
# container log is where you read these now, so keep it readable.
[[ -n "${ENTRYPOINT_DEBUG:-}" ]] && set -x

mkdir -p ~/.config
mkdir -p ~/.local

# --no-fund --no-audit are output-only: these run on every container start and
# the funding and audit blurbs were most of the log.
for pkg in mcp-hub@latest @herb-tools/language-server @agentclientprotocol/claude-agent-acp; do
	npm install -g --no-fund --no-audit "$pkg"
done

export GIT_TERMINAL_PROMPT=0

# Editor tooling that is a gem rather than an npm package. Installed here for
# the same reason the npm ones are: it belongs to the editor, not to the app, so
# it has no business in the app Gemfile.
#
# It lands in /usr/local/bundle -- the GEM_VOLUME mount, shared across every
# worktree on this ruby -- so the install happens once per ruby version and not
# once per container. `gem list -i` first, matching how test:rails_watcher
# handles retest: an install on every start would add seconds to every attach.
#
# --no-document because nobody reads rdoc in a container, and it is most of the
# install time.
for g in ruby-lsp; do
	gem list -i "$g" >/dev/null 2>&1 || gem install "$g" --no-document
done

# gh extensions live in the per-worktree home, so a fresh home has none.
# --force installs when missing, upgrades when stale, no-ops when current.
gh extension install github/gh-stack --force >/dev/null 2>&1 || true

# Two config modes, and an empty directory means opposite things in each.
# NVIM_CONFIG_SOURCE comes from units-env.sh, which chose the mount -- inferring
# it here from writability was wrong under root and fragile anyway.
#   volume, empty -> expected on first run; configure nvim in place, it persists
#   host,   empty -> the mount did not land, or points at the wrong directory
nvim_entries=$(ls -A ~/.config/nvim 2>/dev/null | wc -l)
case "${NVIM_CONFIG_SOURCE:-unknown}" in
	volume)
		if (( nvim_entries == 0 )); then
			echo "nvim config: shared volume, empty. Configure nvim in here and it" >&2
			echo "             persists across every worktree. To use your host config" >&2
			echo "             read-only instead, set NVIM_CONFIG_DIR in the" >&2
			echo "             workspace-root mise.local.toml." >&2
		else
			echo "nvim config: shared volume, ${nvim_entries} entries (writable)" >&2
		fi
		;;
	host)
		if (( nvim_entries == 0 )); then
			echo "WARN: NVIM_CONFIG_DIR is set but ~/.config/nvim is empty -- the bind" >&2
			echo "      mount did not land. Check the path, then:" >&2
			echo "      mise run units:env && mise run units:install" >&2
		elif [[ ! -f ~/.config/nvim/init.lua && ! -f ~/.config/nvim/init.vim ]]; then
			echo "WARN: host config mounted but has no init.lua or init.vim." >&2
			echo "      Contents: $(ls -A ~/.config/nvim | tr '\n' ' ')" >&2
		else
			echo "nvim config: host config (read-only), ${nvim_entries} entries" >&2
		fi
		;;
	*)
		echo "WARN: NVIM_CONFIG_SOURCE unset -- regenerate the unit env file:" >&2
		echo "      mise run units:env" >&2
		;;
esac

# Plugins are a separate axis: ~/.local/share/nvim is its own named volume.
if [[ -z "$(ls -A ~/.local/share/nvim 2>/dev/null)" ]]; then
	echo "note: ~/.local/share/nvim is empty, so no plugins are installed yet." >&2
	echo "      Your plugin manager installs them when the server first loads the" >&2
	echo "      config; a headless server may need it driven explicitly, e.g." >&2
	echo "      podman exec -it \$(hostname) nvim --headless '+Lazy! sync' +qa" >&2
fi

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"
