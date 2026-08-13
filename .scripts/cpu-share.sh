#!/usr/bin/env sh
# Prints a percentage of the host's CPU count, for the compose services'
# deploy.resources cpu limits: `cpu-share.sh 75`, `50`, `25`. Hardcoded limits
# mean a 32-core desktop leaves cores idle while a 4-core laptop
# oversubscribes; scaling with the machine keeps one worktree's stack from
# eating the whole host either way.
#
# Floored to a whole core and never below 1 (compose rejects "0"). getconf
# _NPROCESSORS_ONLN works on both Linux and macOS, unlike nproc.
set -eu

percent="${1:-50}"
case "$percent" in
  '' | *[!0-9]*) echo "cpu-share.sh: bad percentage '$percent'" >&2; exit 1 ;;
esac

cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
case "$cpus" in
  '' | *[!0-9]*) cpus=4 ;;
esac

share=$((cpus * percent / 100))
[ "$share" -lt 1 ] && share=1

echo "$share"
