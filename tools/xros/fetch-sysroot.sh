#!/usr/bin/env bash
# Fetch UTM's visionOS sysroot and make it usable from this checkout.
#
# The sysroot is not in this repo: it is 1.5 GB and it is not ours. UTM
# builds one on every push to main and publishes it as a public GitHub
# Actions artifact, so this takes the newest one that has not expired,
# unpacks it, and relocates it.
#
#   ./fetch-sysroot.sh              device, into $XROS_SYSROOT (default ./sysroot)
#   ./fetch-sysroot.sh simulator    into $XROS_SIMULATOR_SYSROOT (default ./sysroot-simulator)
#   ./fetch-sysroot.sh --force      replace one that is already there
#
# Needs gh, logged in. The artifact is public but GitHub still refuses to
# hand out an artifact zip without a token, which is the first thing a fresh
# machine trips on.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VARIANT=device
FORCE=0
for arg in "$@"; do
	case "$arg" in
	device | simulator) VARIANT="$arg" ;;
	--force) FORCE=1 ;;
	*) echo "usage: fetch-sysroot.sh [device|simulator] [--force]" >&2; exit 1 ;;
	esac
done

case "$VARIANT" in
device)    NAME=Sysroot-visionos-arm64;           DEST="${XROS_SYSROOT:-$HERE/sysroot}" ;;
simulator) NAME=Sysroot-visionos_simulator-arm64; DEST="${XROS_SIMULATOR_SYSROOT:-$HERE/sysroot-simulator}" ;;
esac

if [[ -d "$DEST/lib/pkgconfig" && "$FORCE" != 1 ]]; then
	echo "sysroot already at $DEST (--force to replace it)"
	exit 0
fi

command -v gh >/dev/null || { echo "needs gh: brew install gh, then gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in. Run: gh auth login" >&2; exit 1; }

# Newest first, unexpired only. Artifacts expire after 90 days, and UTM's
# main branch moves often enough that there is normally one from this week.
read -r ID CREATED SIZE < <(gh api "repos/utmapp/UTM/actions/artifacts?name=$NAME&per_page=100" \
	--jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | last
	      | if . == null then "none" else "\(.id) \(.created_at) \(.size_in_bytes)" end') \
	|| { echo "could not list UTM's artifacts (gh api failed)" >&2; exit 1; }
if [[ "$ID" == none ]]; then
	echo "UTM has no unexpired $NAME artifact right now." >&2
	echo "Artifacts last 90 days; the next push to UTM's main makes a new one." >&2
	exit 1
fi
echo "== $NAME $ID, built $CREATED, $((SIZE / 1048576)) MB =="

# Unpacked beside the build directories, never inside the destination, so a
# failed download cannot leave half a sysroot where the scripts look for one.
WORK="$HERE/build/sysroot-download-$VARIANT"
rm -rf "$WORK"; mkdir -p "$WORK/unpack"
gh api "repos/utmapp/UTM/actions/artifacts/$ID/zip" > "$WORK/artifact.zip"
unzip -q "$WORK/artifact.zip" -d "$WORK/zip"

# The zip has held a sysroot.tgz so far. Take a bare tree too, in case that
# ever changes, rather than failing on a layout detail.
if [[ -f "$WORK/zip/sysroot.tgz" ]]; then
	tar xzf "$WORK/zip/sysroot.tgz" -C "$WORK/unpack"
else
	mv "$WORK/zip" "$WORK/unpack/zip"
fi
TOP="$(find "$WORK/unpack" -maxdepth 3 -type d -path '*/lib/pkgconfig' | head -1)"
[[ -n "$TOP" ]] || { echo "no lib/pkgconfig anywhere in the artifact; layout has changed" >&2; exit 1; }
TOP="$(dirname "$(dirname "$TOP")")"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TOP" "$DEST"
rm -rf "$WORK"

# The .pc files and the dylib install names carry UTM's CI path until this
# runs, and both fail quietly if left alone. It writes absolute paths, so
# moving the sysroot later means running it again.
"$HERE/relocate-sysroot.sh" "$DEST"
echo "== sysroot at $DEST =="
