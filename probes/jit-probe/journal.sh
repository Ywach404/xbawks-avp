#!/usr/bin/env bash
# Pull the crash journal off the device.
#
# Worth doing when the app vanishes instead of reporting. The journal is
# rewritten before every step, so its last line names the step that killed
# the process, which a signal handler by definition could not report.
set -euo pipefail
cd "$(dirname "$0")"
source device.sh

BUNDLE="${1:?bundle id}"
jp_find_device

DEST="${2:-/tmp/jitprobe-journal.txt}"
xcrun devicectl device copy from \
	--device "$DEV" \
	--domain-type appDataContainer \
	--domain-identifier "$BUNDLE" \
	--source Documents/jitprobe-journal.txt \
	--destination "$DEST"
echo "== journal =="
cat "$DEST"
