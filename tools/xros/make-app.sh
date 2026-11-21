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
# XEMU_BUILD names another build directory, for putting a binary from a
# second tree (an A/B against an older state) through the same assembly.
BUILD="${XEMU_BUILD:-$ROOT/third_party/xemu/build-xros}"
# The relocated UTM sysroot itself, the folder holding lib/ and Frameworks/.
# The same variable and default as gen-cross.sh and configure-xemu-xros.sh.
SYSROOT="${XROS_SYSROOT:-$ROOT/tools/xros/sysroot}"
APP="$ROOT/build-app/Xbawks.app"
# The app's own identifier. It can be overridden for one run, which is how
# an existing install keeps its data container: a different bundle id is a
# different app to installd, with an empty Documents folder, so a headset
# that already holds the BIOS, the disc images and the hard disk image with
# its saves can be built against the old id until its files are moved.
BUNDLE_ID="${XEMU_BUNDLE_ID:-com.acervantez.xbawks}"

BIN="$BUILD/qemu-system-i386"
[[ -f "$BIN" ]] || { echo "no visionOS binary. See tools/xros/README.md" >&2; exit 1; }

# Checked before anything is assembled. A missing sysroot used to produce an
# app with an empty Frameworks folder, and an IPA of it, that dyld kills
# before main() without a crash report.
[[ -d "$SYSROOT/lib" ]] || {
	echo "no sysroot at $SYSROOT. Run tools/xros/fetch-sysroot.sh, or set XROS_SYSROOT" >&2
	exit 1; }

# Rebuild first, always. Three runs in this project were read as results
# while the device was running a previous build, because the bundle was
# assembled from a binary that had not finished relinking. It costs seconds
# to be sure and a cycle to be wrong.
if [[ -f "$BUILD/build.ninja" ]]; then
	ninja -C "$BUILD" qemu-system-i386 >/dev/null || {
		echo "build failed" >&2; exit 1; }
fi

rm -rf "$APP"; mkdir -p "$APP/Frameworks"
cp "$BIN" "$APP/Xbawks"

cmp -s "$BIN" "$APP/Xbawks" || { echo "copy mismatch" >&2; exit 1; }

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Xbawks</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>Xbawks</string>
	<key>CFBundleDisplayName</key><string>XBAWKS</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>XROS</string></array>
	<key>MinimumOSVersion</key><string>26.0</string>
	<!-- Game controllers. SpatialGamepad first, for the PSVR2 Sense
	     controllers, one device per hand, as every shipping visionOS app that
	     uses them declares it (ALVR, Klepton, the GoldenEye port). With only
	     ExtendedGamepad, visionOS stood in a combined "(L/R)" device when both
	     were on at launch and handed over only the right hand when they were
	     turned on later. ExtendedGamepad for a DualSense or PS4 pad. -->
	<key>GCSupportsControllerUserInteraction</key><true/>
	<key>GCSupportedGameControllers</key>
	<array>
		<dict><key>ProfileName</key><string>SpatialGamepad</string></dict>
		<dict><key>ProfileName</key><string>ExtendedGamepad</string></dict>
	</array>
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

# Dylibs it loads, plus MoltenVK. Everything else comes from the OS. Every
# one is required: skipping a missing one quietly is how an app that cannot
# launch got built and wrapped as an IPA.
missing=()
for lib in libglib-2.0.0.dylib libslirp.0.dylib libusb-1.0.0.dylib \
           libgobject-2.0.0.dylib libgmodule-2.0.0.dylib libgthread-2.0.0.dylib \
           libintl.8.dylib libiconv.2.dylib libffi.8.dylib libpixman-1.0.dylib; do
	if [[ -f "$SYSROOT/lib/$lib" ]]; then
		cp -L "$SYSROOT/lib/$lib" "$APP/Frameworks/"
	else
		missing+=("lib/$lib")
	fi
done
if [[ -d "$SYSROOT/Frameworks/MoltenVK.framework" ]]; then
	cp -R "$SYSROOT/Frameworks/MoltenVK.framework" "$APP/Frameworks/"
else
	missing+=("Frameworks/MoltenVK.framework")
fi
if (( ${#missing[@]} )); then
	rm -rf "$APP" "$ROOT/build-app/Xbawks.ipa"
	echo "the sysroot at $SYSROOT is missing:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "fetch a fresh one with tools/xros/fetch-sysroot.sh --force" >&2
	exit 1
fi

# An iOS-family bundle has Frameworks beside the executable, not above it.
install_name_tool -add_rpath "@executable_path/Frameworks" "$APP/Xbawks" 2>/dev/null || true
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
for f in "$APP/Xbawks" "$APP/Frameworks"/*.dylib; do
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
otool -l "$APP/Xbawks" | awk '/LC_RPATH/{f=1;next} f&&/path /{print $2;f=0}' | while read -r rp; do
	case "$rp" in
		@*) continue ;;
		*) install_name_tool -delete_rpath "$rp" "$APP/Xbawks" 2>/dev/null || true ;;
	esac
done

# Oxanium, the interface face. SIL OFL 1.1, which permits embedding and
# redistribution provided the licence travels with it, so OFL.txt goes in
# beside the fonts rather than being referenced from somewhere else.
#
# The files live in tools/xros/fonts/, which is ignored, and are fetched on
# first use from google/fonts at a pinned commit, the last one that still
# carried the static cuts. The variable font that replaced them does not
# answer to the four PostScript names the interface asks for. Each file is
# checked against its hash, so a moved or changed upstream fails here rather
# than in the headset's text. A face already installed in ~/Library/Fonts
# is the fallback when there is no network, which is how this worked before.
FONTS="$ROOT/tools/xros/fonts"
FONTS_URL="https://raw.githubusercontent.com/google/fonts/becd3517c582fa68f041364b02bc597ee822ef1c/ofl/oxanium"
fetch_font() {   # <file in FONTS> <path under FONTS_URL> <sha256> <fallback>
	local dst="$FONTS/$1"
	if [[ ! -f "$dst" ]]; then
		mkdir -p "$FONTS"
		if curl -fsSL -o "$dst.part" "$FONTS_URL/$2" \
			&& echo "$3  $dst.part" | shasum -a 256 -c --status; then
			mv "$dst.part" "$dst"
		else
			rm -f "$dst.part"
			[[ -f "$4" ]] && cp "$4" "$dst"
		fi
	fi
	[[ -f "$dst" ]]
}
mkdir -p "$APP/Fonts"
while read -r f sum; do
	fetch_font "Oxanium-$f.ttf" "static/Oxanium-$f.ttf" "$sum" "$HOME/Library/Fonts/Oxanium-$f.ttf" \
		&& cp "$FONTS/Oxanium-$f.ttf" "$APP/Fonts/" \
		|| echo "  warning: Oxanium-$f.ttf could not be fetched; the interface falls back to the system face"
done <<SUMS
Regular  2b9c2a53ee0a8248ab901463838cc81075b410724046a09683b3cc91870fe52a
Medium   d0676de4894cd22591b4bb538dae5b8e06c44e0fb943300a7cff3945fe643689
SemiBold e2d77ec4ee67b0152166adf5d6393360550a012c2066e0d4589053e14a733cdc
Bold     15a44f661fd962c64cabe069a5f9f6fab85a412188f028d3e04da2ff917e37cc
SUMS
fetch_font OFL.txt OFL.txt fe17c0f2581d71b4e1ea7e636e7f4877c29223e11bb1dd1a871e8c3f2a86336b \
	"$HOME/Library/Fonts/_licences/Oxanium-OFL.txt" \
	&& cp "$FONTS/OFL.txt" "$APP/Fonts/OFL.txt" \
	|| { rm -f "$APP/Fonts/"*.ttf
	     echo "  warning: no Oxanium licence, so the fonts are left out; the OFL requires it to travel with them"; }

# The icon. Three layers in tools/xros/Assets.xcassets, compiled the way
# Xcode would compile them, and the CFBundleIcons entry actool reports
# merged into the Info.plist written above. Without that entry the
# Assets.car is in the bundle but nothing points the home view at it.
ICONS="$ROOT/build-app/icons"
rm -rf "$ICONS"; mkdir -p "$ICONS"
xcrun actool "$ROOT/tools/xros/Assets.xcassets" --compile "$APP" \
	--platform xros --minimum-deployment-target 26.0 --target-device vision \
	--app-icon AppIcon --output-partial-info-plist "$ICONS/partial.plist" \
	--output-format human-readable-text >/dev/null
/usr/libexec/PlistBuddy -c "Merge $ICONS/partial.plist" "$APP/Info.plist" >/dev/null

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
	rm -f "$ROOT/build-app/Xbawks.ipa"
	echo
	echo "  no IPA: the bundle carries media ($(ls "$APP/media" | tr '\n' ' '))"
	echo "  install the .app directly:"
	echo "    tools/xros/sign-install.sh"
	echo "    xcrun devicectl device install app --device <udid> $APP"
	echo "  built $APP"
	exit 0
fi
IPA="$ROOT/build-app/Xbawks.ipa"
rm -rf "$ROOT/build-app/Payload" "$IPA"
mkdir -p "$ROOT/build-app/Payload"
cp -R "$APP" "$ROOT/build-app/Payload/"
( cd "$ROOT/build-app" && zip -qry "$IPA" Payload )
rm -rf "$ROOT/build-app/Payload"
echo "  ipa: $IPA ($(du -h "$IPA" | awk '{print $1}'))"
