#!/bin/sh
# Claude Code hook: record this worktree's claude session state so the
# wt.localhost dashboard can show a live status badge. Registered for several
# hook events by entrypoint-claude.sh; the event name arrives in the JSON
# payload on stdin. Writes /status/<worktree>.json — a bind mount of
# .docker-config/status/, which the proxy's home container serves at /status/.
set -eu

[ -n "${WORKTREE_NAME:-}" ] && [ -d /status ] || exit 0

event=$(jq -r '.hook_event_name // empty' 2>/dev/null || true)
case "$event" in
  UserPromptSubmit | PreToolUse | PostToolUse) state="working" ;;
  SessionStart | Stop | Notification) state="waiting" ;;
  SessionEnd) state="offline" ;;
  *) exit 0 ;;
esac

# Temp + rename so the dashboard never reads a half-written file. The dotfile
# prefix keeps it out of the nginx autoindex listing the dashboard consumes.
tmp="/status/.${WORKTREE_NAME}.tmp"
printf '{"state":"%s","ts":"%s"}\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
mv "$tmp" "/status/${WORKTREE_NAME}.json"
