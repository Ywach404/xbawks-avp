#!/usr/bin/env bash
# Run by launchd, weekly. Silent unless something actually moved.
#
# check-sdk.sh exits 0 for no change, 1 for a change worth acting on, and 2
# when it cannot find an SDK at all. Only 1 is worth interrupting anyone
# over: 2 usually means Xcode was moved or xcode-select points somewhere
# new, which is a local problem and not news about visionOS.
set -uo pipefail
cd "$(dirname "$0")"

LOG="$HOME/Library/Logs/xemu-avp-jitwatch.log"
mkdir -p "$(dirname "$LOG")"

out="$(./check-sdk.sh 2>&1)"
rc=$?

printf '[%s] exit=%s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$out" >> "$LOG"

case "$rc" in
0) exit 0 ;;
1)
	osascript -e 'display notification "The visionOS SDK JIT annotations changed. Rerun the probe on device before believing it." with title "xemu-avp: S0 may be unblocked" sound name "Submarine"' >/dev/null 2>&1
	# A notification is easy to miss and easy to dismiss. Leave something
	# on disk that is still there next week.
	printf '%s\n\n%s\n' "$(date)" "$out" > "$HOME/Desktop/XEMU-AVP-CHECK-THIS.txt"
	exit 1
	;;
*)
	# No SDK found. Log it and stay quiet.
	exit 0
	;;
esac
