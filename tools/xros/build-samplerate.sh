#!/usr/bin/env bash
# libsamplerate for arm64-apple-xros.
#
# Needed by the MCPX APU and hw/audio/es1370.c. Like SDL3 this leaves with
# S4's audio work, but five translation units include samplerate.h
# unconditionally and a link needs them today. It is a small, portable C
# library with no platform assumptions, so it cross-compiles unchanged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/libsamplerate"
OUT="$HERE/samplerate-xros"

rm -rf "$HERE/build/samplerate" "$OUT"
cmake -S "$SRC" -B "$HERE/build/samplerate" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$HERE/xros.cmake" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$OUT" \
	-DBUILD_SHARED_LIBS=OFF \
	-DLIBSAMPLERATE_EXAMPLES=OFF \
	-DLIBSAMPLERATE_INSTALL=ON \
	-DBUILD_TESTING=OFF \
	> "$HERE/build/samplerate-configure.log" 2>&1 || {
		grep -iE 'error|CMake Error' "$HERE/build/samplerate-configure.log" | head -8 >&2; exit 1; }

cmake --build "$HERE/build/samplerate" --parallel > "$HERE/build/samplerate-build.log" 2>&1 || {
	grep -E 'error:' "$HERE/build/samplerate-build.log" | sort -u | head -8 >&2; exit 1; }
cmake --install "$HERE/build/samplerate" > /dev/null

echo "installed to $OUT"
ls "$OUT/lib" | sed 's/^/  /'
