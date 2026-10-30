#!/usr/bin/env bash
# Modes 2 and 3: the process under a debugger, and the same process after the
# debugger lets go.
#
# This is the mode the whole project rests on. On iOS a process that has been
# ptraced carries CS_DEBUGGED for the rest of its life, and the JIT permission
# that comes with it is not taken back at detach. That is the mechanism behind
# every sideloaded emulator with working JIT. Whether visionOS 27 does the
# same is what nobody here has measured.
#
# WHY THIS SCRIPT DOES NOT DRIVE THE DEBUGGER ITSELF.
#
# `devicectl device process launch --start-stopped` suspends a process, but
# suspension is not ptrace and does not set CS_DEBUGGED, so start-stopped
# followed by `devicectl device process resume` would measure mode 1 with a
# pause in it and look like a pass for the wrong reason. Driving lldb at a
# headset by hand means `platform select remote-xros` plus a platform connect,
# which was not verified on hardware before this was written and is not worth
# guessing at inside a script you would be running half awake.
#
# Xcode's Run button does ptrace the process, reliably, every time. So this
# installs the build, then hands over with exact instructions.
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
echo "installed $BUNDLE"

cat <<'TXT'

== modes 2 and 3, by hand, about two minutes ==

  1. open JITProbe.xcodeproj
  2. choose the JITProbe-Attached scheme (NOT plain JITProbe: that one has
     the debugger switched off, which is mode 1 and you have already run it)
  3. choose your headset as the run destination, and press Run
  4. put the headset on. The window appears and probes once.

     That is MODE 2, attached. It should report CS_DEBUGGED: YES.
     Expect it to pass. It is the control, not the answer.

     XCODE WILL BREAK ON EXC_BAD_ACCESS. That is not a crash. With a
     debugger attached, a fault is a Mach exception that lldb catches
     before the probe's own signal guard runs. Two paths fault on
     purpose. Press Continue until the window updates; two stops per
     faulting path is normal. To halve that, paste this into the lldb
     console first:

       process handle SIGBUS SIGSEGV SIGILL -s false -n false -p true

  5. back in Xcode: Debug > Detach  (NOT Stop, which kills the process)
  6. in the headset, press  Run again

     That is MODE 3, and it is the one that decides the project.
     Read two lines: whether any path EXECUTED, and whether CS_DEBUGGED
     is still YES after the detach.

  7. press  Copy report  and paste it into DEVLOG.md under S0.

If the app dies instead of reporting, run `make journal` to pull the last
step it reached off the device.

TXT

echo "opening Xcode"
open JITProbe.xcodeproj
