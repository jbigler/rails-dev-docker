# Configurable light/dark mode for the Neovim container

Date: 2026-08-03

## Problem

The `nvim` container always starts in dark mode. When the host terminal is in
light mode, the editor stays dark until `background` is set by hand.

## Root cause

Neovim detects the terminal's background by writing OSC 11 and classifying the
luminance of the reply. That detection lives in
`/usr/share/nvim/runtime/lua/vim/_core/defaults.lua`, and the whole block is
guarded on a UI with `stdout_tty` being attached *already*:

```lua
-- defaults.lua:790
local tty = nil
for _, ui in ipairs(vim.api.nvim_list_uis()) do
  if ui.stdout_tty then
    tty = ui
    break
  end
end

if tty then
  -- ... OSC 11 query, TermResponse handler, 'background' assignment
end
```

The container runs `nvim --headless --listen 0.0.0.0:7777`
(`.docker-config/Dockerfile:186`) and clients attach later with
`nvim --remote-ui` (`.mise/config.toml:27`). At server startup there is no UI at
all, so `tty` is `nil`, the block is skipped, and `background` keeps its default
of `dark` permanently. The query is never sent and no `TermResponse` handler is
ever registered.

Confirmed by direct measurement: a headless server with no UI attached reports
`background=dark` regardless of the connecting terminal.

## Design

Detect the host terminal's background on the host at container start, pass it in
as `NVIM_BACKGROUND`, and have the Neovim config apply it before the colorscheme
loads.

### 1. `.scripts/detect-terminal-background.sh` (new)

Prints `dark` or `light` on stdout. Always exits 0.

- If `$NVIM_BACKGROUND` is already `dark` or `light`, echo it and exit. Lets a
  shell env var or `mise.local.toml` override detection.
- Otherwise ask kitty for its current background over its remote-control socket:
  `kitten @ get-colors`, take the `background` field, compute luminance
  `0.299r + 0.587g + 0.114b` over the parsed hex, `< 0.5` is `dark`.
- Any failure (no kitty, socket refused, non-kitty terminal, CI, `kitten` not on
  `PATH`) prints `dark`.

`kitten @` needs no arguments: kitty exports `KITTY_LISTEN_ON` into every shell
it spawns, and `allow_remote_control yes` / `listen_on unix:@mykitty` are already
set (`~/.config/kitty/kitty.conf:1205,1232`). Verified working: returns
`#fffcf0`, classified `light`.

This detector is kitty-specific. That is an accepted trade — the setup is
already kitty-committed (`TERM=xterm-kitty` in `.docker-config/.env`, plus the
`kitty-scrollback.nvim` and `vim-kitty-navigator` plugins) — and it degrades to
`dark` everywhere else rather than failing.

### 2. `.mise/config.toml` `[env]`

```toml
NVIM_BACKGROUND = "{{ exec(command = config_root ~ '/.scripts/detect-terminal-background.sh') }}"
```

Same shape as the existing `UID = "{{exec(command='id -u')}}"` at line 2. Runs
on every `mise` invocation; cost is one unix-socket round trip.

### 3. `.docker-config/compose.yml`

Add to the `nvim` service's `environment:` block (line 162):

```yaml
NVIM_BACKGROUND: ${NVIM_BACKGROUND:-dark}
```

Not added to `.docker-config/.env`, because the value is per-host and per-session
rather than a project constant. The `:-dark` default keeps a bare
`docker compose up` outside mise working.

### 4. `~/.config/nvim/lua/plugins/background.lua` (new)

Follows the established pattern in `lua/plugins/osc52.lua`: set the option at
spec-evaluation time, return an empty spec.

```lua
local bg = vim.env.NVIM_BACKGROUND

if bg == "dark" or bg == "light" then vim.o.background = bg end

-- plus :BackgroundToggle, then
return {}
```

Plugin spec files are evaluated while lazy.nvim collects specs, which is before
AstroUI applies the colorscheme. So the value is in place for the first paint —
no repaint hook and no flash of the wrong theme.

No headless/remote gate is needed. `NVIM_BACKGROUND` only exists inside the
container, so a local `nvim` sees `nil`, skips the assignment, and keeps
Neovim's builtin detection untouched.

### 5. `BackgroundSet()` and `:BackgroundToggle`

A global `_G.BackgroundSet(mode)` owns the assignment. It ignores anything that
is not `"dark"`/`"light"`, no-ops when the mode already matches, and returns the
mode in effect. `:BackgroundToggle` flips via it, and the `mise run nvim` task
calls it over RPC (section 6).

Global rather than local because `--remote-expr` needs to reach it as
`v:lua.BackgroundSet('dark')`. Call sites use the explicit `_G.` prefix so selene
doesn't flag an undefined variable.

Re-applying the colorscheme is required — changing `background` alone does not
repaint. It works for flexoki specifically because
`~/.local/share/nvim/lazy/flexoki/colors/flexoki.lua` clears the palette module
cache before reloading:

```lua
package.loaded["flexoki.palette"] = nil
require("flexoki").colorscheme()
```

and `flexoki/palette.lua:79` picks the variant off `vim.o.background`. AstroUI
reapplies its own highlight overrides on the `ColorScheme` event.

### 6. Push the current mode on attach, in the `nvim` mise task

`NVIM_BACKGROUND` is baked into the container's environment at start, so a server
that has been up since before an OS theme flip holds a stale value, and attaching
does not re-read it. Before running `--remote-ui`, push the freshly detected mode
into the running server:

```bash
if [ -n "${NVIM_BACKGROUND:-}" ]; then
  nvim --server localhost:{{ env.NVIM_PORT }} \
    --remote-expr "v:lua.BackgroundSet('$NVIM_BACKGROUND')" >/dev/null 2>&1 || true
fi
nvim --remote-ui --server localhost:{{ env.NVIM_PORT }}
```

`$NVIM_BACKGROUND` is current here because mise re-evaluates `[env]` — and so
re-runs the detector — on every invocation. Reusing the variable rather than
calling the script again keeps the attach-time value identical to the one the
container would have been started with.

Best effort by design: the push is silenced and `|| true`'d, because if the server
isn't up the `--remote-ui` on the next line reports that far better than a failed
`--remote-expr` would.

This also fixes containers started before this change, which have no
`NVIM_BACKGROUND` at all — they get the right mode on the next attach without
being recreated.

### 7. `.mise/config.toml:25`

The `nvim` task is described as "Connect to Neovim in the container with theme
sync." Nothing synced a theme. Correct the description.

## Trade-offs

- **Correct at attach, not continuously.** A theme flip while attached needs
  `:BackgroundToggle`, or a detach and reattach. No container restart either way.
- **kitty-only detection**, falling back to `dark`.
- Detection runs on every `mise` invocation, not only at `up`.
- A client that attaches without going through `mise run nvim` gets only the
  container-start value.

## Alternative considered and rejected

Query OSC 11 from the server on `UIEnter` via `nvim_ui_send`, and keep a
persistent `TermResponse` handler so the terminal can push updates.

This works, and was verified end to end against real ptys before being rejected:

| Check | Result |
| --- | --- |
| `--remote-ui` client probes and enables DEC mode 2031, same as a local TUI | yes, both |
| Headless server, no UI attached | `dark` |
| Client forwards the server's `nvim_ui_send` OSC 11 query to its tty | yes |
| Server `background` after a light reply | `light` |
| Server `background` after an *unsolicited* dark push | `dark` |

It is terminal-agnostic and tracks live theme changes, including kitty's
`auto_color_scheme` pushes and the TUI's re-query on suspend/resume. Rejected
anyway: live switching is rare, and it costs ~40 lines of hex parsing and
autocmd wiring in the Neovim config versus ~10 lines of shell. `nvim_ui_send`
also requires Neovim 0.12+, while the container builds `--branch stable`
(`.docker-config/Dockerfile:13`) and may lag.

Also rejected: reading the OS preference instead of the terminal's colors. Both
`gsettings get org.gnome.desktop.interface color-scheme` and the
`org.freedesktop.portal.Settings` `color-scheme` key report no preference on this
host (`'default'` / `uint32 0`), so neither can distinguish light from dark here.

## Verification

1. `.scripts/detect-terminal-background.sh` prints `light` in a light kitty
   window and `dark` in a dark one.
2. It prints `dark` with `KITTY_LISTEN_ON` unset and with `PATH=/nonexistent`,
   and exits 0 in both cases.
3. `NVIM_BACKGROUND=light .scripts/detect-terminal-background.sh` prints
   `light`; an invalid value falls through to detection.
4. `mise env | grep NVIM_BACKGROUND` shows the detected value.
5. `docker compose config` shows `NVIM_BACKGROUND` on the `nvim` service.
6. From a light terminal: recreate the `nvim` service, `mise run nvim`, confirm
   flexoki dawn on first paint with no dark flash.
7. `:BackgroundToggle` switches to moon and back.
8. A local `nvim` outside the container still auto-detects and still switches
   live on an OS theme flip.
9. `v:lua.BackgroundSet('dark')` over `--remote-expr` against a server started
   with `NVIM_BACKGROUND=light` flips `background` and repaints `Normal` from
   `#fffcf0` to `#100f0f`, and returns the mode applied.
10. The same call with `purple` or an empty string leaves `background` untouched.
11. Flip the OS theme with a server already running, then `mise run nvim`: the
    session comes up in the new mode without recreating the container.
