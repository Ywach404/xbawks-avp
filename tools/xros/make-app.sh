#!/usr/bin/env bash
# Wrap the visionOS binary in a minimal app bundle.
#
# Deliberately not a UIKit app. An iOS-family bundle needs an Info.plist and
# an executable, and nothing says that executable has to call
# UIApplicationMain. This one runs the emulator headless, writes a frame into
# its own Documents and exits, which is enough to answer the only question
# that matters right now: does any of this run on the headset.
#
# The real app, with a compositor and a window, is S3.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
BUILD="$ROOT/third_party/xemu/build-xros"
SYSROOT="${XROS_SYSROOT:-$ROOT/../_scratch/xros-sysroot}"
APP="$ROOT/build-app/XemuHost.app"
# Reusing an App ID that already has a provisioning profile on disk. Issuing
# a new one needs Apple's servers, which is a dependency worth not having:
# a free account gets ten App IDs a week and gsa.apple.com returns 503 often
# enough to stop an evening dead. JITProbe's App ID is free, since S0 is
# answered and the app is uninstalled.
BUNDLE_ID="${XEMU_BUNDLE_ID:-local.jitprobe.s0}"

BIN="$BUILD/qemu-system-i386"
[[ -f "$BIN" ]] || { echo "no visionOS binary. See tools/xros/README.md" >&2; exit 1; }

# Rebuild first, always. Three runs in this project were read as results
# while the device was running a previous build, because the bundle was
# assembled from a binary that had not finished relinking. It costs seconds
# to be sure and a cycle to be wrong.
if [[ -f "$BUILD/build.ninja" ]]; then
	ninja -C "$BUILD" qemu-system-i386 >/dev/null || {
		echo "build failed" >&2; exit 1; }
fi

rm -rf "$APP"; mkdir -p "$APP/Frameworks"
cp "$BIN" "$APP/XemuHost"

cmp -s "$BIN" "$APP/XemuHost" || { echo "copy mismatch" >&2; exit 1; }

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>XemuHost</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>Xbawks</string>
	<key>CFBundleDisplayName</key><string>XBAWKS</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>XROS</string></array>
	<key>MinimumOSVersion</key><string>26.0</string>
	<!-- Game controllers: let a paired DualSense drive the app directly. -->
	<key>GCSupportsControllerUserInteraction</key><true/>
	<key>GCSupportedGameControllers</key>
	<array><dict><key>ProfileName</key><string>ExtendedGamepad</string></dict></array>
	<key>UIDeviceFamily</key><array><integer>7</integer></array>
	<!-- Plane detection, so the console can be put down on a real table
	     instead of hovering through it. Without this string the
	     authorisation request is denied before the user ever sees it. -->
	<key>NSWorldSensingUsageDescription</key>
	<string>Finds tables and floors so the console can rest on them.</string>
	<!-- Oxanium, SIL OFL 1.1. The licence travels in Fonts/OFL.txt. -->
	<key>UIAppFonts</key>
	<array>
		<string>Fonts/Oxanium-Regular.ttf</string>
		<string>Fonts/Oxanium-Medium.ttf</string>
		<string>Fonts/Oxanium-SemiBold.ttf</string>
		<string>Fonts/Oxanium-Bold.ttf</string>
	</array>
	<!-- So the frame it writes can be pulled off with devicectl, and seen
	     in Files without a cable. -->
	<key>UIFileSharingEnabled</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<!-- The entry point is a SwiftUI App: a small launcher window that opens
	     a mixed immersive space and dismisses itself. Spatial controllers are
	     only the app's while a space is open and no window of the app is
	     being looked at, and the icon needs a window scene to bring back
	     (both measured 2026-10-29). -->
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><true/>
		<key>UIApplicationPreferredDefaultSceneSessionRole</key><string>UIWindowSceneSessionRoleApplication</string>
	</dict>
</dict>
</plist>
PLIST

# Dylibs it loads, plus MoltenVK. Everything else comes from the OS.
SR="$SYSROOT/sysroot-visionos-arm64/sysroot-visionos-arm64"
for lib in libglib-2.0.0.dylib libslirp.0.dylib libusb-1.0.0.dylib \
           libgobject-2.0.0.dylib libgmodule-2.0.0.dylib libgthread-2.0.0.dylib \
           libintl.8.dylib libiconv.2.dylib libffi.8.dylib libpixman-1.0.dylib; do
	[[ -f "$SR/lib/$lib" ]] && cp -L "$SR/lib/$lib" "$APP/Frameworks/" || true
done
if [[ -d "$SR/Frameworks/MoltenVK.framework" ]]; then
	cp -R "$SR/Frameworks/MoltenVK.framework" "$APP/Frameworks/"
fi

# An iOS-family bundle has Frameworks beside the executable, not above it.
install_name_tool -add_rpath "@executable_path/Frameworks" "$APP/XemuHost" 2>/dev/null || true
for f in "$APP/Frameworks"/*.dylib; do
	[[ -f "$f" ]] || continue
	install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
done
# Rewrite references, but ONLY to things we actually bundled.
#
# The obvious version of this loop rewrites anything matching */lib/lib*.dylib
# to @rpath, and that is wrong in a way that kills the app instantly with no
# crash report: UTM's sysroot ships its own copies of libSystem, libz, libc++
# and libobjc, so the link resolves them there, the pattern matches, and the
# binary ends up asking for @rpath/libSystem.B.dylib, which is not in
# Frameworks because it belongs to the OS. dyld gives up before main().
#
# So: bundled means @rpath, everything else goes back to /usr/lib.
for f in "$APP/XemuHost" "$APP/Frameworks"/*.dylib; do
	[[ -f "$f" ]] || continue
	otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
		base="$(basename "$dep")"
		case "$dep" in
			/System/*|/usr/lib/*) continue ;;
		esac
		if [[ -f "$APP/Frameworks/$base" ]]; then
			install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true
		else
			# Not ours: it is an OS library the sysroot happened to carry.
			install_name_tool -change "$dep" "/usr/lib/$base" "$f" 2>/dev/null || true
		fi
	done
done

# The link leaves an absolute rpath into the build-time sysroot. Harmless on
# this machine and meaningless on a headset.
otool -l "$APP/XemuHost" | awk '/LC_RPATH/{f=1;next} f&&/path /{print $2;f=0}' | while read -r rp; do
	case "$rp" in
		@*) continue ;;
		*) install_name_tool -delete_rpath "$rp" "$APP/XemuHost" 2>/dev/null || true ;;
	esac
done

# Oxanium, the interface face. SIL OFL 1.1, which permits embedding and
# redistribution provided the licence travels with it, so OFL.txt goes in
# beside the fonts rather than being referenced from somewhere else.
mkdir -p "$APP/Fonts"
for f in Regular Medium SemiBold Bold; do
	src="$HOME/Library/Fonts/Oxanium-$f.ttf"
	[[ -f "$src" ]] && cp "$src" "$APP/Fonts/" || echo "  warning: Oxanium-$f.ttf not installed"
done
[[ -f "$HOME/Library/Fonts/_licences/Oxanium-OFL.txt" ]] \
	&& cp "$HOME/Library/Fonts/_licences/Oxanium-OFL.txt" "$APP/Fonts/OFL.txt"

# Media: opt in, never by default.
#
# The app cannot boot without an MCPX ROM, a BIOS image and a hard disk
# image, so a device run needs them inside the bundle. That is also exactly
# what makes the resulting bundle undistributable: it would carry Microsoft
# firmware and, with a disc image, a game. So nothing is copied unless
# XEMU_MEDIA names a folder, and a bundle that has media in it refuses to
# become an IPA further down. Set it per run:
#
#   XEMU_MEDIA=~/path/to/media tools/xros/make-app.sh
#
MEDIA="${XEMU_MEDIA:-}"
if [[ -n "$MEDIA" && -d "$MEDIA" ]]; then
	mkdir -p "$APP/media"
	# The HDD is 2 GB and makes the bundle 2 GB with it. Worth it: without
	# something to boot into, the Xbox never tells NV2A to scan out and
	# there is no frame to capture at all.
	for f in mcpx-1.0.bin xbox_hdd.qcow2; do
		[[ -f "$MEDIA/$f" ]] && cp "$MEDIA/$f" "$APP/media/" || true
	done
	# The BIOS image goes in as bios.bin whatever it is called on disk:
	# XEMU_BIOS names it, else the one .bin in the media folder that is not
	# the MCPX ROM.
	BIOS="${XEMU_BIOS:-$(ls "$MEDIA"/*.bin 2>/dev/null | grep -v mcpx | head -1)}"
	[[ -n "$BIOS" && -f "$BIOS" ]] && cp "$BIOS" "$APP/media/bios.bin" || true
fi
# A game, if one is pointed at. Same rule: the owner's own file, never in
# the repo (*.iso is ignored), bundled read-only as the disc in the drive.
GAME="${XEMU_GAME:-}"
if [[ -n "$GAME" && -f "$GAME" ]]; then
	mkdir -p "$APP/media"
	cp "$GAME" "$APP/media/game.iso"
	echo "  game: $(basename "$GAME")"
fi

echo "built $APP"
du -sh "$APP" | awk '{print "  "$1}'
echo "  frameworks: $(ls "$APP/Frameworks" | wc -l | xargs)"

# Wrap as an IPA for Apparition, which signs with an Apple ID and installs.
#
# Refused outright when the bundle carries media. An IPA is the shape that
# gets uploaded and passed around, and one built over a bundle holding a
# boot ROM, a BIOS and a game would be distributing Microsoft firmware and
# somebody's game. A local device install does not need an IPA: use
# `xcrun devicectl device install app` on the .app directly.
if [[ -d "$APP/media" ]] && [[ -n "$(ls -A "$APP/media" 2>/dev/null)" ]]; then
	# And remove any IPA left from an earlier medialess build, so a stale
	# one cannot be picked up and uploaded in place of the refused one.
	rm -f "$ROOT/build-app/XemuHost.ipa"
	echo
	echo "  no IPA: the bundle carries media ($(ls "$APP/media" | tr '\n' ' '))"
	echo "  install the .app directly:"
	echo "    tools/xros/sign-install.sh"
	echo "    xcrun devicectl device install app --device <udid> $APP"
	echo "  built $APP"
	exit 0
fi
IPA="$ROOT/build-app/XemuHost.ipa"
rm -rf "$ROOT/build-app/Payload" "$IPA"
mkdir -p "$ROOT/build-app/Payload"
cp -R "$APP" "$ROOT/build-app/Payload/"
( cd "$ROOT/build-app" && zip -qry "$IPA" Payload )
rm -rf "$ROOT/build-app/Payload"
echo "  ipa: $IPA ($(du -h "$IPA" | awk '{print $1}'))"
