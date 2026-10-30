#!/usr/bin/env bash
# Sign the app with a profile already on disk and install it. No Apple
# servers involved: issuing a profile needs them, using one does not.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
APP="${XEMU_APP:-$ROOT/build-app/XemuHost.app}"
BUNDLE_ID="${XEMU_BUNDLE_ID:-local.jitprobe.s0}"
# The first Apple Development identity in the keychain, unless told otherwise.
IDENTITY="${XEMU_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null \
	| grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"')}"
[[ -n "$IDENTITY" ]] || { echo "no Apple Development identity in the keychain; set XEMU_IDENTITY" >&2; exit 1; }
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

[[ -d "$APP" ]] || { echo "no app at $APP. Run make-app.sh" >&2; exit 1; }

# Find the profile for this App ID.
PROFILE=""
for p in "$PROFILES"/*.mobileprovision; do
	id="$(security cms -D -i "$p" 2>/dev/null | grep -A1 'application-identifier' \
	      | tail -1 | sed 's/.*<string>//;s|</string>.*||')"
	if [[ "$id" == *".$BUNDLE_ID" ]]; then PROFILE="$p"; break; fi
done
# A team wildcard profile (TEAMID.*) covers any bundle id; the renewal on
# 2026-10-29 came back as one, so accept it when nothing exact is on disk.
if [[ -z "$PROFILE" ]]; then
	for p in "$PROFILES"/*.mobileprovision; do
		id="$(security cms -D -i "$p" 2>/dev/null | grep -A1 'application-identifier' \
		      | tail -1 | sed 's/.*<string>//;s|</string>.*||')"
		if [[ "$id" == *".*" ]]; then PROFILE="$p"; break; fi
	done
fi
[[ -n "$PROFILE" ]] || { echo "no profile on disk for $BUNDLE_ID" >&2; exit 1; }
echo "profile: $(basename "$PROFILE")"

cp "$PROFILE" "$APP/embedded.mobileprovision"

# Sign with exactly the profile's own entitlements. Inventing them is how you
# get a silent install failure.
ENT="$(mktemp -t ent).plist"
security cms -D -i "$PROFILE" | plutil -extract Entitlements xml1 -o "$ENT" -
# A wildcard profile's entitlements say TEAMID.*; the app must be signed with
# its concrete id or installd rejects the upgrade ("does not match installed
# application's application-identifier", measured 2026-10-29).
TEAM="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$ENT" 2>/dev/null || true)"
if [[ -n "$TEAM" ]] && [[ "$(/usr/libexec/PlistBuddy -c "Print :application-identifier" "$ENT")" == "$TEAM.*" ]]; then
	/usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" "$ENT"
fi

# An emulator is heavy and jetsam is unforgiving. Every prepared JIT page is
# written and therefore resident dirty, and that is before guest RAM,
# MoltenVK and glib. Measured: at tb-size=128 the process is SIGKILLed with
# no crash handler firing and no signal; at 32 it survives one step longer.
# NOT added here. A profile authorises a fixed set of entitlements, and the
# one being reused does not include this, so adding it makes installd reject
# the signature with "A valid provisioning profile for this executable was
# not found". That failure is silent if you are not reading install output,
# and the device then keeps running the previous build, which looks exactly
# like a code change having no effect.
#
# Getting it properly means a profile that carries it, which means Apple's
# servers.
/usr/libexec/PlistBuddy -c "Print" "$ENT" | head -6 | sed 's/^/  /'

# Nested code first, outside in.
if [[ -d "$APP/Frameworks" ]]; then
	find "$APP/Frameworks" -name '*.dylib' -print0 | while IFS= read -r -d '' f; do
		codesign --force --timestamp=none --sign "$IDENTITY" "$f" >/dev/null 2>&1
	done
fi
if [[ -d "$APP/Frameworks/MoltenVK.framework" ]]; then
	codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Frameworks/MoltenVK.framework" >/dev/null 2>&1
fi
codesign --force --timestamp=none --entitlements "$ENT" --sign "$IDENTITY" "$APP"

echo "=== verify ==="
codesign -dv --entitlements - "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|application-identifier|get-task-allow' | sed 's/^/  /' | head -6
