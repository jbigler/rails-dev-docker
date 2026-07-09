#!/usr/bin/env bash
# Print the Playwright version pinned by a Rails Gemfile.lock.
#
# playwright-ruby-client tracks upstream Playwright releases, so its locked
# version drives the browser-server image tag and the npm playwright-core
# version (see Dockerfile.playwright). Best-effort: prints nothing (exit 0)
# when the lock or the gem is missing, so compose can fall back to its
# default tag.
#
# Usage: playwright-version.sh [path-to-Gemfile.lock]   (default: Gemfile.lock)
set -euo pipefail

lock="${1:-Gemfile.lock}"
[ -f "$lock" ] || exit 0

# The spec line is exactly four-space indented: "    playwright-ruby-client (1.60.0)".
# The dependency line ("      playwright-ruby-client (>= 1.16.0)") is indented deeper.
grep -E '^ {4}playwright-ruby-client \(' "$lock" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
  | head -n1 || true
