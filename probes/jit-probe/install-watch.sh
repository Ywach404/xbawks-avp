#!/usr/bin/env bash
# Install (or remove) the weekly check as a launchd user agent.
#
#   ./install-watch.sh           install and start
#   ./install-watch.sh --remove  stop and delete
#
# The plist lives in ~/Library/LaunchAgents and is deliberately NOT in this
# repo: it hardcodes an absolute path to this checkout, which is machine
# state rather than project state.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.acervantez.xemu-avp.jitwatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(pwd)/watch.sh"

if [[ "${1:-}" == "--remove" ]]; then
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	echo "removed $LABEL"
	exit 0
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$SCRIPT</string>
	</array>
	<!-- Monday mornings. The thing being watched only changes when Xcode
	     is updated, so anything more frequent is noise. -->
	<key>StartCalendarInterval</key>
	<dict>
		<key>Weekday</key><integer>1</integer>
		<key>Hour</key><integer>10</integer>
		<key>Minute</key><integer>0</integer>
	</dict>
	<!-- If the Mac was asleep at the scheduled time, run once on wake
	     rather than skipping the week entirely. -->
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/xemu-avp-jitwatch.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/xemu-avp-jitwatch.launchd.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL"
echo "  plist:  $PLIST"
echo "  script: $SCRIPT"
echo "  runs:   Mondays at 10:00 local"
echo "  log:    $HOME/Library/Logs/xemu-avp-jitwatch.log"
echo
echo "Test it now with:  launchctl kickstart -p gui/$(id -u)/$LABEL"
echo "Remove it with:    ./install-watch.sh --remove"
