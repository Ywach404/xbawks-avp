#!/usr/bin/env bash
# Configure the consuming tree for arm64-apple-xros.
#
# This drives QEMU's own ./configure rather than meson directly, the way UTM
# does: configure writes its own config-meson.cross from the environment and
# hands it to meson. That generated file is the one that says
# system = 'darwin', which QEMU's many host_os == 'darwin' branches need.
# xros-arm64.cross is passed as a *second* cross file so its properties
# (pkg_config_libdir, has_function_pipe2/dup3, the cmake toolchain) land on
# top. Meson merges cross files left to right, last writer wins.
#
# Runs against the reconstructed tree that tools/setup-tree.sh makes, or
# another one named with XEMU_TREE (an A/B against an older state).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TREE="${XEMU_TREE:-$ROOT/third_party/xemu}"
SYSROOT="${XROS_SYSROOT:-$HERE/sysroot}"
GLSLANG="$HERE/glslang-xros"
SDL3="$HERE/sdl3-xros"
SRATE="$HERE/samplerate-xros"
MINVER=26.0
SDKROOT="$(xcrun --sdk xros --show-sdk-path)"
BUILD="$TREE/build-xros"

[[ -d "$TREE" ]] || { echo "no tree at $TREE. Run: tools/setup-tree.sh --clone" >&2; exit 1; }
[[ -d "$SYSROOT/lib/pkgconfig" ]] || {
	echo "no sysroot at $SYSROOT. Run: tools/xros/fetch-sysroot.sh" >&2; exit 1; }
[[ -f "$HERE/xros-arm64-props.cross" ]] || {
	echo "no cross file. Run: tools/xros/gen-cross.sh device" >&2; exit 1; }

# Whatever python3 and cmake come first on PATH, not a Homebrew prefix:
# Homebrew is /usr/local on an Intel Mac and absent under MacPorts.
PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || { echo "needs python3 on PATH" >&2; exit 1; }

# PyYAML venv. scripts/gen_config.py imports yaml and pythondeps.toml never
# declares it; a venv passed in with --python= survives configure's --clear.
#
# Checked by import rather than by the venv existing, so a venv left by a
# run that failed half way is completed instead of trusted. And tomli: a
# python3 older than 3.11 has no tomllib, configure then demands tomli, and
# the first python3 on a Mac's PATH is often Xcode's 3.9.
VENV="$HERE/build-venv"
[[ -x "$VENV/bin/python3" ]] || "$PYTHON" -m venv "$VENV"
if ! "$VENV/bin/python3" -c 'import yaml' 2>/dev/null; then
	"$VENV/bin/pip" install -q --upgrade pip
	"$VENV/bin/pip" install -q pyyaml
fi
if ! "$VENV/bin/python3" -c 'import tomllib' 2>/dev/null \
	&& ! "$VENV/bin/python3" -c 'import tomli' 2>/dev/null; then
	"$VENV/bin/pip" install -q tomli
fi

# In cross mode meson will not fall back to PATH to find cmake.
CMAKE="$(command -v cmake || true)"
[[ -n "$CMAKE" ]] || { echo "needs cmake 3.28 or later on PATH" >&2; exit 1; }
export CMAKE

export CC="$(xcrun --sdk xros --find clang) -target arm64-apple-xros$MINVER"
export CXX="$(xcrun --sdk xros --find clang++) -target arm64-apple-xros$MINVER"
export OBJCC="$(xcrun --sdk xros --find clang) -target arm64-apple-xros$MINVER"
export AR="$(xcrun --sdk xros --find ar)"
export NM="$(xcrun --sdk xros --find nm)"
export RANLIB="$(xcrun --sdk xros --find ranlib)"
export STRIP="$(xcrun --sdk xros --find strip)"

COMMON="-arch arm64 -isysroot $SDKROOT -I$SYSROOT/include -F$SYSROOT/Frameworks"
export CFLAGS="$COMMON"
export CXXFLAGS="$COMMON -target arm64-apple-xros$MINVER"
export OBJCFLAGS="$COMMON -target arm64-apple-xros$MINVER"
export LDFLAGS="-arch arm64 -isysroot $SDKROOT -L$SYSROOT/lib -F$SYSROOT/Frameworks -target arm64-apple-xros$MINVER"

# Only the sysroot. Without this the host's /opt/homebrew/lib/pkgconfig leaks
# in and a macOS dylib gets picked for a visionOS link.
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig:$GLSLANG/lib/pkgconfig:$SDL3/lib/pkgconfig:$SRATE/lib/pkgconfig"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

../configure \
	--python="$VENV/bin/python3" \
	--cross-prefix= \
	--target-list=i386-softmmu \
	--extra-cflags="-DXBOX=1 -DQEMU_NO_PTHREAD_JIT_WRITE_PROTECT=1" \
	--extra-ldflags="-headerpad_max_install_names" \
	--disable-cocoa \
	--disable-coreaudio \
	--disable-slirp-smbd \
	--disable-werror \
	--extra-cross-file="$HERE/xros-arm64-props.cross" \
	-Dopengl=disabled \
	"$@"
