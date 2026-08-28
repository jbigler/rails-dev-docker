#!/usr/bin/env bash
# Launch the Claude container outside the current shell, preferring a tab of the
# terminal we are already running in. Escalation ladder:
#
#   1. a new tab in the detected terminal (if it can be driven from the CLI)
#   2. a new window of the detected terminal
#   3. a new window of any terminal emulator we can find
#   4. the current window (only when there is no usable emulator/display)
set -euo pipefail

WORKDIR="$PWD"
# CLAUDE_RUN_OPTS carries the `-e CLAUDE_CODE_OAUTH_TOKEN` passthrough set by the
# claude mise task (empty under claude:notoken). Unquoted: it is a flag list.
CMD=(docker compose run --rm ${CLAUDE_RUN_OPTS:-} claude "$@")

# Emulators tried, in order, when the detected terminal cannot give us a tab or
# a window of its own.
FALLBACK_TERMINALS=(kitty wezterm ghostty alacritty foot konsole gnome_terminal
                    xfce4_terminal terminator xterm)

# Single shell-quoted string for the terminals whose flags take a command line
# rather than an argv list (xfce4-terminal --command, xterm -e sh -c, osascript).
quoted_cmd() {
  local out="" arg
  for arg in "${CMD[@]}"; do
    out+="${out:+ }$(printf '%q' "$arg")"
  done
  printf '%s' "$out"
}

run_here() {
  exec "${CMD[@]}"
}

# Detach a new terminal instance: those launchers stay in the foreground for the
# lifetime of their window, which would pin the shell we were called from.
spawn_bg() {
  nohup "$@" >/dev/null 2>&1 &
  disown
}

# Executable that owns each terminal id used below.
binary_for() {
  case "$1" in
    gnome_terminal) echo gnome-terminal ;;
    xfce4_terminal) echo xfce4-terminal ;;
    iterm2|apple_terminal) echo osascript ;;
    *) echo "$1" ;;
  esac
}

have_terminal() {
  command -v "$(binary_for "$1")" >/dev/null 2>&1
}

# $TERMINAL may hold a path and/or a hyphenated binary name; the ids used here
# are bare and underscored (gnome_terminal, not /usr/bin/gnome-terminal).
normalize_terminal() {
  printf '%s' "${1##*/}" | tr '-' '_'
}

# A GUI emulator needs somewhere to draw. macOS has no DISPLAY, hence the uname
# escape hatch.
have_display() {
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "$(uname -s)" = Darwin ]
}

# Name of the terminal emulator hosting this shell. Environment fingerprints are
# checked first because they are exact; the process tree is the fallback for
# terminals that leave no marker in the environment.
detect_terminal() {
  [ -n "${TMUX:-}" ] && { echo tmux; return; }
  [ -n "${KITTY_PID:-}" ] && { echo kitty; return; }
  [ -n "${WEZTERM_PANE:-}" ] && { echo wezterm; return; }
  [ -n "${KONSOLE_VERSION:-}" ] && { echo konsole; return; }
  [ -n "${TERMINATOR_UUID:-}" ] && { echo terminator; return; }
  [ -n "${ALACRITTY_WINDOW_ID:-}" ] && { echo alacritty; return; }
  [ -n "${GHOSTTY_RESOURCES_DIR:-}${GHOSTTY_BIN_DIR:-}" ] && { echo ghostty; return; }

  case "${TERM_PROGRAM:-}" in
    iTerm.app) echo iterm2; return ;;
    Apple_Terminal) echo apple_terminal; return ;;
    vscode) echo vscode; return ;;
  esac

  local pid name
  pid=$PPID
  # Walk up until we run out of numeric parents (init/kernel or a dead pid).
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||; s/^-//; s/[[:space:]]*$//') || name=
    case "$name" in
      kitty) echo kitty; return ;;
      wezterm|wezterm-gui) echo wezterm; return ;;
      konsole) echo konsole; return ;;
      gnome-terminal|gnome-terminal-server) echo gnome_terminal; return ;;
      xfce4-terminal) echo xfce4_terminal; return ;;
      terminator) echo terminator; return ;;
      tmux|tmux:server) echo tmux; return ;;
      alacritty) echo alacritty; return ;;
      foot|footclient) echo foot; return ;;
      ghostty) echo ghostty; return ;;
      xterm) echo xterm; return ;;
      Terminal) echo apple_terminal; return ;;
      iTerm2) echo iterm2; return ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || pid=
  done

  echo unknown
}

# New tab in an already-running instance. Returns non-zero when the terminal has
# no CLI tab support (alacritty, foot, ghostty, vscode) or the spawn failed
# (kitty without allow_remote_control, no running instance, ...).
launch_tab() {
  have_terminal "$1" || return 1
  case "$1" in
    tmux)
      # A tmux window is the closest thing to a tab, and it works no matter
      # which emulator tmux itself is drawn in.
      tmux new-window -c "$WORKDIR" -n Claude -- "${CMD[@]}"
      ;;
    kitty)
      kitty @ launch --type=tab --cwd="$WORKDIR" --tab-title=Claude \
        --copy-env=yes -- "${CMD[@]}"
      ;;
    wezterm)
      wezterm cli spawn --cwd "$WORKDIR" -- "${CMD[@]}"
      ;;
    konsole)
      konsole --new-tab --workdir "$WORKDIR" -e "${CMD[@]}"
      ;;
    gnome_terminal)
      gnome-terminal --tab --title=Claude --working-directory="$WORKDIR" -- "${CMD[@]}"
      ;;
    xfce4_terminal)
      xfce4-terminal --tab --title=Claude --working-directory="$WORKDIR" \
        --command="$(quoted_cmd)"
      ;;
    terminator)
      terminator --new-tab --working-directory="$WORKDIR" -x "${CMD[@]}"
      ;;
    iterm2)
      osascript \
        -e 'tell application "iTerm2" to tell current window to create tab with default profile' \
        -e "tell application \"iTerm2\" to tell current session of current window to write text \"cd $(printf '%q' "$WORKDIR") && $(quoted_cmd)\""
      ;;
    *) return 1 ;;
  esac
}

# New window/instance of the given terminal, cwd set to the project directory.
launch_window() {
  have_terminal "$1" || return 1
  have_display || return 1
  case "$1" in
    kitty)          spawn_bg kitty --directory "$WORKDIR" -- "${CMD[@]}" ;;
    wezterm)        spawn_bg wezterm start --cwd "$WORKDIR" -- "${CMD[@]}" ;;
    ghostty)        spawn_bg ghostty --working-directory="$WORKDIR" -e "${CMD[@]}" ;;
    alacritty)      spawn_bg alacritty --working-directory "$WORKDIR" -e "${CMD[@]}" ;;
    foot)           spawn_bg foot -D "$WORKDIR" "${CMD[@]}" ;;
    konsole)        spawn_bg konsole --workdir "$WORKDIR" -e "${CMD[@]}" ;;
    gnome_terminal) spawn_bg gnome-terminal --window --title=Claude \
                      --working-directory="$WORKDIR" -- "${CMD[@]}" ;;
    xfce4_terminal) spawn_bg xfce4-terminal --title=Claude \
                      --working-directory="$WORKDIR" --command="$(quoted_cmd)" ;;
    terminator)     spawn_bg terminator --working-directory="$WORKDIR" -x "${CMD[@]}" ;;
    xterm)          spawn_bg xterm -title Claude \
                      -e sh -c "cd $(printf '%q' "$WORKDIR") && exec $(quoted_cmd)" ;;
    iterm2)
      spawn_bg osascript \
        -e 'tell application "iTerm2" to create window with default profile' \
        -e "tell application \"iTerm2\" to tell current session of current window to write text \"cd $(printf '%q' "$WORKDIR") && $(quoted_cmd)\""
      ;;
    apple_terminal)
      # Terminal.app has no scriptable "new tab"; `do script` opens a window.
      spawn_bg osascript \
        -e "tell application \"Terminal\" to do script \"cd $(printf '%q' "$WORKDIR") && $(quoted_cmd)\""
      ;;
    *) return 1 ;;
  esac
}

TERMINAL_NAME=$(detect_terminal)

launch_tab "$TERMINAL_NAME" && exit 0
launch_window "$TERMINAL_NAME" && exit 0

for candidate in ${TERMINAL:-} "${FALLBACK_TERMINALS[@]}"; do
  term=$(normalize_terminal "$candidate")
  [ "$term" = "$TERMINAL_NAME" ] && continue
  if launch_window "$term"; then
    echo "claude:newterm: $TERMINAL_NAME gave us no tab or window; opened $term instead." >&2
    exit 0
  fi
done

echo "claude:newterm: no terminal emulator could be launched; running in the current window." >&2
run_here
