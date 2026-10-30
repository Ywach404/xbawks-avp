#!/usr/bin/env bash
# SDL3 for arm64-apple-xros.
#
# Not in UTM's sysroot, because UTM has its own UI and does not use SDL. The
# xemu tree still needs it in ten files: the MCPX APU audio path, the Live
# Communicator, xemu-input, and vl.c. All of that is S3 and S4 work that
# replaces SDL with GameController and AVAudioEngine, but a link needs it
# today, and SDL3 supports visionOS properly through its UIKit video backend.
#
# Static: one consumer, nothing dlopens it, and a static archive keeps the
# app bundle simpler.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/SDL"
OUT="$HERE/sdl3-xros"

[[ -d "$SRC" ]] || { echo "no SDL source at $SRC" >&2; exit 1; }

rm -rf "$HERE/build/sdl3" "$OUT"
cmake -S "$SRC" -B "$HERE/build/sdl3" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$HERE/xros.cmake" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$OUT" \
	-DSDL_SHARED=OFF \
	-DSDL_STATIC=ON \
	-DSDL_TESTS=OFF \
	-DSDL_EXAMPLES=OFF \
	-DSDL_INSTALL_TESTS=OFF \
	> "$HERE/build/sdl3-configure.log" 2>&1 || {
		echo "configure failed:" >&2
		grep -iE 'error|CMake Error' "$HERE/build/sdl3-configure.log" | head -10 >&2
		exit 1
	}

cmake --build "$HERE/build/sdl3" --parallel > "$HERE/build/sdl3-build.log" 2>&1 || {
	echo "build failed:" >&2
	grep -E 'error:' "$HERE/build/sdl3-build.log" | sort -u | head -10 >&2
	exit 1
}
cmake --install "$HERE/build/sdl3" > /dev/null

echo "installed to $OUT"
ls "$OUT/lib" | sed 's/^/  /'
otool -l "$OUT/lib/libSDL3.a" 2>/dev/null | grep -A2 LC_BUILD_VERSION | head -3 || \
  lipo -info "$OUT/lib/libSDL3.a" | sed 's/^/  /'
