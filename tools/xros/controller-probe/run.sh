#!/usr/bin/env bash
# Build, bundle, sign, install and launch the controller probe. It reuses
# the XemuHost bundle id and profile, so it replaces XemuHost on the device
# until make-app.sh and sign-install.sh put it back.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$(pwd)"
SDK="$(xcrun -sdk xros --show-sdk-path)"
APP="$ROOT/build-app/ControllerProbe.app"
BUNDLE_ID="${XEMU_BUNDLE_ID:-local.jitprobe.s0}"
# The first physical Vision Pro devicectl knows about, unless told otherwise.
UDID="${XROS_UDID:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /Vision Pro/ {print $(NF-4); exit}')}"
[[ -n "$UDID" ]] || { echo "no Vision Pro found; set XROS_UDID" >&2; exit 1; }
rm -rf "$APP" && mkdir -p "$APP"
xcrun -sdk xros swiftc -target arm64-apple-xros26.0 -O -parse-as-library \
	tools/xros/controller-probe/ControllerProbe.swift -o "$APP/ControllerProbe"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>ControllerProbe</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>ControllerProbe</string>
	<key>CFBundleDisplayName</key><string>ControllerProbe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>XROS</string></array>
	<key>MinimumOSVersion</key><string>26.0</string>
	<key>UIDeviceFamily</key><array><integer>7</integer></array>
	<key>GCSupportsControllerUserInteraction</key><true/>
	<key>UIApplicationSceneManifest</key><dict>
		<key>UIApplicationSupportsMultipleScenes</key><true/>
		<key>UIApplicationPreferredDefaultSceneSessionRole</key><string>UIWindowSceneSessionRoleApplication</string>
	</dict>
</dict></plist>
PLIST
XEMU_APP="$APP" tools/xros/sign-install.sh | tail -1
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | grep -E "installationURL|ERROR"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1 | tail -1
