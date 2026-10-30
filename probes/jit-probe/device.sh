# Sourced, not run. Sets DEV to a connected headset's identifier, or exits.
#
# Match the UUID shape on a line that names the device, but require the
# Reality column to say `physical`: booted simulators also report `connected`
# and `Apple Vision Pro` is their name too, so state alone picks the wrong one.
jp_find_device() {
	local re='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
	DEV="$(xcrun devicectl list devices 2>/dev/null \
		| grep -Ei 'vision pro' | grep -Ei 'physical' | grep -Ei 'connected|available' \
		| grep -Eo "$re" | head -1 || true)"
	if [[ -z "${DEV:-}" ]]; then
		echo "no connected headset found. Full device list:" >&2
		xcrun devicectl list devices >&2
		exit 1
	fi
	echo "device $DEV"
}

# Device products only. `make check` leaves a simulator build next door, and
# installing that onto a headset fails with an invalid-signature error that
# reads like a signing problem rather than the wrong-slice problem it is.
jp_find_app() {
	local scheme="$1" derived="$2"
	APP="$(find "$derived/Build/Products" -name "$scheme.app" -type d \
		-not -path '*simulator*' | head -1)"
	if [[ -z "$APP" ]]; then
		echo "no device build of $scheme.app under $derived" >&2
		echo "(a simulator build does not count: DEV_TEAM=... make device)" >&2
		exit 1
	fi
	echo "built $APP"
}
