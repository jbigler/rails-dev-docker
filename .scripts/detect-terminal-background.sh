#!/usr/bin/env bash
# Print "dark" or "light" for the host terminal's current background, for the
# nvim container to pick up as NVIM_BACKGROUND.
#
# The container runs `nvim --headless --listen` and clients attach later with
# `nvim --remote-ui`. Neovim's builtin background detection only runs when a UI
# with `stdout_tty` is already attached at startup (see the `if tty then` guard
# in runtime/lua/vim/_core/defaults.lua), so the headless server skips it
# entirely and 'background' stays at its default of "dark" forever. Detecting on
# the host instead and passing the answer in works around that.
#
# kitty-specific: asks kitty for its live colors over its remote-control socket.
# Anything else (no kitty, socket refused, non-kitty terminal, CI) falls back to
# "dark". Never fails — a broken detector must not break `docker compose up`.
set -uo pipefail

# Respect an explicit override from the shell or mise.local.toml.
case "${NVIM_BACKGROUND:-}" in
  dark | light)
    echo "$NVIM_BACKGROUND"
    exit 0
    ;;
esac

# `kitten @` needs no --to: kitty exports KITTY_LISTEN_ON into the shells it
# spawns. Requires `allow_remote_control yes` in kitty.conf.
bg=$(kitten @ get-colors 2>/dev/null | awk '$1 == "background" { print $2; exit }') || bg=""

# Classify by luminance, the same weights Neovim uses on an OSC 11 reply.
mode=$(awk -v hex="$bg" 'BEGIN {
  if (hex !~ /^#[0-9a-fA-F]{6}$/) exit 1
  r = strtonum("0x" substr(hex, 2, 2)) / 255
  g = strtonum("0x" substr(hex, 4, 2)) / 255
  b = strtonum("0x" substr(hex, 6, 2)) / 255
  print (0.299 * r + 0.587 * g + 0.114 * b) < 0.5 ? "dark" : "light"
}') || mode=""

echo "${mode:-dark}"
