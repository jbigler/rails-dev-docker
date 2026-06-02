#!/usr/bin/env bash
# Playwright browser server with a live VNC view of the headed browser.
#
# Clients (capybara-playwright-driver via browser_server_endpoint_url -> BrowserType.connect)
# attach to the browser server launched below. connect_to_browser_server is the only remote
# mode Playwright >= 1.54 supports, and it does NOT pass the client's launch options — so
# headed/headless is decided HERE, at launchServer time. We launch headed by default into
# the Xvfb display, which x11vnc + noVNC expose as a web page so the run can be watched live.
# Set HEADLESS_SYSTEM_TESTS=1 to launch headless instead (faster, nothing to view).
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1600x1000x24}"
VNC_WEB_PORT="${VNC_WEB_PORT:-8080}"
VNC_RFB_PORT="${VNC_RFB_PORT:-5900}"
export PLAYWRIGHT_PORT="${PLAYWRIGHT_PORT:-8888}"

# launchServer decides headed/headless; default headed for the VNC view.
# Accept 1/true (case-insensitive), matching the Ruby driver's parsing.
export HEADLESS_BOOL="false"
case "$(printf '%s' "${HEADLESS_SYSTEM_TESTS:-0}" | tr '[:upper:]' '[:lower:]')" in
  1 | true) HEADLESS_BOOL="true" ;;
esac

# Clear stale X locks left by an unclean shutdown — the container's /tmp survives
# restarts, and Xvfb refuses to start while the old lock exists.
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

# Virtual framebuffer the headed Chromium renders into.
Xvfb "$DISPLAY" -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp &

# Wait for the X server to accept connections before anything tries to draw.
for _ in $(seq 1 50); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# Expose the framebuffer over VNC. Dev-only and reachable solely on the internal
# docker proxy network, so no password is set.
x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -rfbport "$VNC_RFB_PORT" -bg

# Serve the noVNC web client and bridge its websocket to the VNC port.
websockify --web=/usr/share/novnc "$VNC_WEB_PORT" "localhost:${VNC_RFB_PORT}" &

# Host the browser server. The browser is launched into $DISPLAY when a client connects;
# clients reach it at ws://playwright:${PLAYWRIGHT_PORT}/connect (see PLAYWRIGHT_HOST).
exec node -e '
  const { chromium } = require("/usr/lib/node_modules/playwright-core");
  chromium.launchServer({
    headless: process.env.HEADLESS_BOOL === "true",
    args: ["--no-sandbox"],
    port: parseInt(process.env.PLAYWRIGHT_PORT, 10),
    wsPath: "connect",
  }).then((server) => {
    console.log("Browser server (headless=" + (process.env.HEADLESS_BOOL === "true") + ") listening at " + server.wsEndpoint());
  }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
'
