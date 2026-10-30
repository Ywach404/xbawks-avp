#!/usr/bin/env bash
# Mode 1: install and launch with NO debugger, and stream the log.
#
# This is the mode that decides whether the port can ship as an ordinary
# sideload. If JIT works here, nothing else about launching matters.
set -euo pipefail
cd "$(dirname "$0")"
source device.sh

BUNDLE="${1:?bundle id}"
SCHEME="${2:?scheme}"
DERIVED="${3:-build}"

jp_find_app "$SCHEME" "$DERIVED"
jp_find_device

echo "== installing =="
xcrun devicectl device install app --device "$DEV" "$APP" >/dev/null

echo "== launching detached, mode 1 of 3 =="
exec xcrun devicectl device process launch --device "$DEV" --console "$BUNDLE"
