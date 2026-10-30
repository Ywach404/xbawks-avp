#!/usr/bin/env bash
# The tripwire. Run this after any Xcode update. It needs no headset, no
# signing, no build, and takes about a second.
#
# S0 found that visionOS 27 refuses every way of executing freshly written
# machine code. That is a policy, not physics, so the project is paused
# rather than abandoned. This checks the one place a change would show up
# first: Apple's own availability annotations in the visionOS SDK headers.
#
# The leading indicator is pthread_jit_write_protect_supported_np. Apple
# shipped it to iOS 17.4 and marked it __API_UNAVAILABLE on visionOS. If
# visionos ever leaves that list, or the toggle itself becomes available,
# something has moved and the real probe is worth rerunning:
#
#   DEV_TEAM=XXXXXXXXXX make run
set -euo pipefail

SDK="$(xcrun --sdk xros --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK" ]]; then
	echo "no visionOS SDK found via xcrun. Is Xcode selected?" >&2
	exit 2
fi

echo "SDK: $SDK"
echo

PTHREAD="$SDK/usr/include/pthread/pthread.h"
TOGGLE="$(grep -B2 'void pthread_jit_write_protect_np' "$PTHREAD" | grep '__API_' | tr '\n' ' ' | tr -s ' ')"
QUERY="$(grep -B2 'int pthread_jit_write_protect_supported_np' "$PTHREAD" | grep '__API_' | tr '\n' ' ' | tr -s ' ')"

echo "pthread_jit_write_protect_np:           $TOGGLE"
echo "pthread_jit_write_protect_supported_np: $QUERY"
echo

CHANGED=0

# Baseline recorded 2026-10-22 against XROS27.0: the query names visionos in
# its unavailable list, and the toggle is macOS only.
if grep -q 'visionos' <<<"$QUERY"; then
	echo "unchanged: the support query is still unavailable on visionOS"
else
	echo "*** CHANGED: visionos is no longer in the query's unavailable list ***"
	CHANGED=1
fi

if grep -q 'macos' <<<"$TOGGLE" && ! grep -q 'ios' <<<"$TOGGLE"; then
	echo "*** CHANGED: the toggle is no longer marked unavailable on iOS-family ***"
	CHANGED=1
else
	echo "unchanged: the toggle is still macOS only"
fi

echo
if (( CHANGED )); then
	cat <<'TXT'
Something moved. Rerun the real probe on device before believing it:

  DEV_TEAM=XXXXXXXXXX make run        # mode 1, plain launch
  DEV_TEAM=XXXXXXXXXX make run-debug  # modes 2 and 3

A header annotation is a hint, not a result. S0 was decided on hardware and
so is any reversal of it: visionOS 27 let mprotect(READ|EXEC) return success
and still refused the first instruction fetch, which no header would have
told you.
TXT
	exit 1
fi

echo "No change. The project stays paused. See ../../DEVLOG.md under S0."
