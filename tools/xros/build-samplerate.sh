#!/usr/bin/env bash
# libsamplerate for arm64-apple-xros.
#
# Needed by the MCPX APU and hw/audio/es1370.c. Like SDL3 this leaves with
# S4's audio work, but five translation units include samplerate.h
# unconditionally and a link needs them today. It is a small, portable C
# library with no platform assumptions, so it cross-compiles unchanged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# 0.2.2, the current release, pinned by commit rather than by tag.
# The pinned source revision; SAMPLERATE_REV names another for one run.
REV=c96f5e3de9c4488f4e6c97f59f5245f22fda22f7
if [[ -n "${SAMPLERATE_REV:-}" ]]; then REV="$SAMPLERATE_REV"; fi
SRC="$HERE/src/libsamplerate"
OUT="$HERE/samplerate-xros"

if [[ ! -d "$SRC/.git" ]]; then
	echo "== fetching libsamplerate =="
	mkdir -p "$SRC"
	git -C "$SRC" init -q
	git -C "$SRC" remote add origin https://github.com/libsndfile/libsamplerate
fi
git -C "$SRC" fetch -q --depth 1 origin "$REV"
git -C "$SRC" checkout -q "$REV"
echo "== libsamplerate at $(git -C "$SRC" rev-parse --short HEAD) =="

rm -rf "$HERE/build/samplerate" "$OUT"
mkdir -p "$HERE/build"
# 0.2.2 declares cmake_minimum_required(VERSION 3.1..3.18), and CMake 4
# removed compatibility with anything below 3.5, so without the policy floor
# a current Homebrew cmake refuses to configure it at all.
cmake -S "$SRC" -B "$HERE/build/samplerate" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$HERE/xros.cmake" \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
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
