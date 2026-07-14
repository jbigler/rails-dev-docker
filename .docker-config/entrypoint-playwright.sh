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

# Lock down egress before anything network-facing starts (entrypoint runs as root).
/usr/local/bin/init-firewall-playwright.sh

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

# Interactive Chromium for the claude container's chrome-devtools MCP server.
# Launched headed into the same Xvfb display as the test browser, so it is visible
# (and clickable) on the same noVNC page. It exposes CDP on $CDP_PORT, which headed
# Chrome binds to loopback only — socat republishes it on $CDP_PUBLIC_PORT for other
# containers. This instance is independent of the launchServer browser below: tests
# and the MCP session never share pages or fight over contexts.
CDP_PORT="${CDP_PORT:-9222}"
CDP_PUBLIC_PORT="${CDP_PUBLIC_PORT:-9223}"
CHROME_PROFILE_DIR="${CHROME_PROFILE_DIR:-/tmp/claude-chrome-profile}"
# Rails dev only authorizes hosts in DOMAIN/DEV_HOSTS; "rails" is allowed via DEV_HOSTS.
CHROME_START_URL="${CHROME_START_URL:-http://rails:3000}"
CHROME_BIN="$(node -e 'console.log(require("/usr/lib/node_modules/playwright-core").chromium.executablePath())')"

# Clear stale singleton locks left by an unclean shutdown (same reason as the X locks).
rm -f "${CHROME_PROFILE_DIR}/SingletonLock" "${CHROME_PROFILE_DIR}/SingletonSocket" "${CHROME_PROFILE_DIR}/SingletonCookie"
# The profile survives restarts in /tmp; drop recorded dynamic-HSTS / https
# upgrade decisions so past upgrades can't keep forcing https on the dev host.
rm -f "${CHROME_PROFILE_DIR}/Default/TransportSecurity"

# Throwaway profile: reset prefs every boot to keep the password manager (and its
# "save password" bubble) off — there is no flag for this, only profile preferences.
mkdir -p "${CHROME_PROFILE_DIR}/Default"
cat > "${CHROME_PROFILE_DIR}/Default/Preferences" <<'PREFS'
{"credentials_enable_service":false,"profile":{"password_manager_enabled":false,"password_manager_leak_detection":false}}
PREFS

# Keep Chromium off https for the plain-http dev server. Managed policy instead
# of --disable-features: the feature names churn across Chromium versions
# (HttpsUpgrades, HttpsFirstBalancedMode*, ...) while the policy API is stable.
# BuiltInDnsClientEnabled=false forces the system resolver (Docker DNS) — the
# async DNS client's direct upstream queries hit the egress firewall and stall
# navigation until they time out.
# Both dirs covered — Chromium reads /etc/chromium, Chrome-branded builds
# /etc/opt/chrome.
for policy_dir in /etc/chromium/policies/managed /etc/opt/chrome/policies/managed; do
  mkdir -p "$policy_dir"
  cat > "$policy_dir/no-https-upgrades.json" <<'POLICY'
{
  "HttpsOnlyMode": "disallowed",
  "HttpsUpgradesEnabled": false,
  "HttpAllowlist": ["rails"],
  "BuiltInDnsClientEnabled": false
}
POLICY
done

# Restart loop: an MCP client can legitimately close the browser (Browser.close);
# relaunch so the endpoint comes back without a container restart.
# --test-type suppresses the "unsupported command-line flag: --no-sandbox"
# warning bar (--disable-infobars alone no longer covers it).
(
  while true; do
    "$CHROME_BIN" \
      --no-sandbox \
      --no-first-run \
      --no-default-browser-check \
      --hide-crash-restore-bubble \
      --disable-infobars \
      --test-type \
      --user-data-dir="$CHROME_PROFILE_DIR" \
      --remote-debugging-port="$CDP_PORT" \
      --password-store=basic \
      --window-position=0,0 \
      --window-size=1600,950 \
      "$CHROME_START_URL" >/dev/null 2>&1 || true
    sleep 1
  done
) &

socat TCP-LISTEN:"$CDP_PUBLIC_PORT",fork,reuseaddr TCP:127.0.0.1:"$CDP_PORT" &

# Host the browser server. The browser is launched into $DISPLAY when a client connects;
# clients reach it at ws://playwright:${PLAYWRIGHT_PORT}/connect (see PLAYWRIGHT_HOST).
exec node -e '
  const { chromium } = require("/usr/lib/node_modules/playwright-core");
  chromium.launchServer({
    headless: process.env.HEADLESS_BOOL === "true",
    args: ["--no-sandbox"],
    // Playwright >= 1.60 binds loopback by default; other containers (rails,
    // host-published port) must reach the server, so bind all interfaces.
    host: "0.0.0.0",
    port: parseInt(process.env.PLAYWRIGHT_PORT, 10),
    wsPath: "connect",
  }).then((server) => {
    console.log("Browser server (headless=" + (process.env.HEADLESS_BOOL === "true") + ") listening at " + server.wsEndpoint());
  }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
'
