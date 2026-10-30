#!/usr/bin/env bash
# Relocate a UTM Sysroot-* artifact so it works from a local path.
#
# UTM's CI bakes its own runner prefix into two places, and both are silent
# failures if left alone:
#
#   1. every lib/pkgconfig/*.pc has
#      prefix=/Users/runner/actions/runner-4/_work/UTM/UTM/sysroot-visionOS-arm64
#      so pkg-config hands out -I and -L for directories that do not exist.
#
#   2. every lib/*.dylib carries that same absolute path as its LC_ID_DYLIB
#      and in each LC_LOAD_DYLIB. A binary linked against them records the
#      runner path and cannot launch anywhere. (The Frameworks/ copies are
#      already @rpath; only the bare dylibs are wrong.)
#
# Both are rewritten in place. The untouched originals stay in download/*.zip.
#
# Usage: ./relocate-sysroot.sh <sysroot-dir>
set -euo pipefail

ROOT="${1:?usage: relocate-sysroot.sh <sysroot-dir>}"
ROOT="$(cd "$ROOT" && pwd)"
[[ -d "$ROOT/lib/pkgconfig" ]] || { echo "not a sysroot: $ROOT" >&2; exit 1; }

# Find the baked prefix by looking at every .pc, not just one: a partially
# relocated tree would otherwise report itself finished. Symlinked .pc files
# are skipped because sed -i refuses them and their target is in the list too.
OLD="$(cat "$ROOT"/lib/pkgconfig/*.pc "$ROOT"/share/pkgconfig/*.pc 2>/dev/null \
	| sed -n 's/^prefix=//p' | grep -v "^$ROOT\$" | sort -u | head -1 || true)"

if [[ -z "$OLD" ]]; then
	echo "no foreign prefix left in .pc files"
else
	echo "baked prefix: $OLD"
	echo "new   prefix: $ROOT"
	n=0
	for pc in "$ROOT"/lib/pkgconfig/*.pc "$ROOT"/share/pkgconfig/*.pc; do
		[[ -f "$pc" ]] || continue
		[[ -L "$pc" ]] && continue
		if grep -qF "$OLD" "$pc"; then
			sed -i '' "s|$OLD|$ROOT|g" "$pc"
			n=$((n + 1))
		fi
	done
	echo "rewrote $n .pc files"
fi

# Install names. Point every bare dylib at @rpath/<basename> so the consuming
# app can carry them in its own bundle and resolve them with one LC_RPATH.
n=0
for dylib in "$ROOT"/lib/*.dylib; do
	[[ -f "$dylib" ]] || continue
	# Skip the unversioned symlinks (libfoo.dylib -> libfoo.2.dylib).
	# install_name_tool follows them, so processing both leaves the real
	# file with an unversioned id while its siblings still reference the
	# versioned name, which only fails later at bundling time.
	[[ -L "$dylib" ]] && continue
	base="$(basename "$dylib")"
	cur="$(otool -D "$dylib" | tail -1)"
	if [[ "$cur" != "@rpath/$base" ]]; then
		install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || continue
	fi
	# Any absolute dependency that is not an OS library is a sibling in this
	# sysroot recorded with the CI path. Keyed on shape, not on the literal
	# prefix, so a re-run or a different runner layout is handled too.
	while read -r dep; do
		case "$dep" in
		/usr/lib/* | /System/* | @*) ;;
		/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dylib" 2>/dev/null || true ;;
		esac
	done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
	codesign --remove-signature "$dylib" 2>/dev/null || true
	codesign --force --sign - "$dylib" 2>/dev/null || true
	n=$((n + 1))
done
echo "rewrote install names on $n dylibs"

echo "done. verify with:"
echo "  PKG_CONFIG_LIBDIR=$ROOT/lib/pkgconfig pkg-config --cflags --libs glib-2.0"
