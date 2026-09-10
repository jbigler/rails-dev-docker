#!/usr/bin/env bash
# Remove every podman object this project owns, the rendered systemd units, and
# the project folder. The nuclear option; `clean` is the surgical one.
#
# Two things this has to do that the compose version did not. The containers
# belong to systemd, so the units are stopped first -- otherwise
# Restart=on-failure races the removal. And the rendered unit files in
# ~/.config/containers/systemd outlive the project folder, so they go too, or
# the next login leaves systemd generating units for a workspace that no longer
# exists.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

: "${PROJECT_PREFIX:?PROJECT_PREFIX is unset; refusing to destroy}"
P="$PROJECT_PREFIX"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

if [ -f .mise/config.toml ]; then
  target=$(pwd)
elif [ -f ../.mise/config.toml ]; then
  target=$(cd .. && pwd)
else
  echo "Not at the project root or a worktree; refusing to destroy" >&2
  exit 1
fi

# [-_] catches containers, volumes and networks (podman-dev-master-rails,
# podman-dev_npm_cache); the images are localhost/<prefix>/<name>, so they need
# their own pattern rather than a third separator in this one.
pattern="^${P}[-_]"
image_pattern="^localhost/${P}/"

units=$(cd "$DEST" 2>/dev/null && ls "${P}-"* 2>/dev/null || true)

echo "This will remove:"
echo "  - every podman container, network and volume matching ${pattern}"
echo "  - every image matching ${image_pattern}"
[ -n "$units" ] && echo "  - the rendered units in ${DEST} ($(printf '%s' "$units" | wc -w) files)"
echo "  - the project folder: ${target}"
echo ""
printf "Type 'destroy' to confirm: "
read -r confirm
[ "$confirm" = "destroy" ] || { echo "Aborted."; exit 1; }

# Stop everything before removing anything. --all rather than a name list: at
# this point the intent is total, and a unit missed here would fight the sweep.
running_units=$(systemctl --user list-units --all --plain --no-legend "${P}-*" 2>/dev/null | awk '{print $1}' || true)
if [ -n "$running_units" ]; then
  echo "Stopping units:"; for u in $running_units; do echo "  $u"; done
  # shellcheck disable=SC2086
  systemctl --user stop $running_units 2>/dev/null || true
fi

sweep() {
  local kind="$1" lister="$2" remover="$3" pat="$4" found
  found=$(eval "$lister" | grep -E "$pat" || true)
  [ -n "$found" ] || return 0
  echo "Removing ${kind}:"; for x in $found; do echo "  $x"; done
  # shellcheck disable=SC2086
  eval "$remover $found" >/dev/null 2>&1 || true
}

sweep containers "podman ps -a --format '{{.Names}}'"      "podman rm -f"        "$pattern"
sweep networks   "podman network ls --format '{{.Name}}'"  "podman network rm -f" "$pattern"
sweep volumes    "podman volume ls --format '{{.Name}}'"   "podman volume rm -f"  "$pattern"
sweep images     "podman images --format '{{.Repository}}:{{.Tag}}'" "podman rmi -f" "$image_pattern"

if [ -n "$units" ]; then
  echo "Removing rendered units from ${DEST}"
  rm -f "$DEST/${P}-"*
  systemctl --user daemon-reload
fi

echo "Removing project folder: ${target}"
cd "$HOME"
rm -rf "$target"

echo ""
echo "Done. Your shell may be in a removed directory; run: cd ~"
