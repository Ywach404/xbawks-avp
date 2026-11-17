#!/usr/bin/env bash
# Build glslang for arm64-apple-xros, static, into its own prefix.
#
# The UTM sysroot does not contain glslang: UTM has no need for it (its
# include/GLSLANG/ShaderLang.h is ANGLE's, a different library with a
# colliding name). This is the one library of the four that has to be built.
#
# Static, for three reasons: it is a C++ API with one consumer in the tree,
# nothing dlopens it, and a static archive sidesteps bundling a C++ dylib
# whose libc++ ABI would then have to be signed and shipped.
#
# The revision matches subprojects/glslang.wrap in the consuming tree, so a
# pkg-config hit and the cmake-subproject fallback produce the same library.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REV="${GLSLANG_REV:-e1b562a8bed273a02f30b59b66a5d499793cede5}"   # vulkan-sdk-1.4.363.0
SRC="$HERE/src/glslang"
# ./build-glslang.sh [device|simulator]
VARIANT="${1:-device}"
case "$VARIANT" in
device)    TOOLCHAIN="$HERE/xros.cmake";           SUFFIX="" ;;
simulator) TOOLCHAIN="$HERE/xros-simulator.cmake"; SUFFIX="-simulator" ;;
*) echo "usage: build-glslang.sh [device|simulator]" >&2; exit 1 ;;
esac
PREFIX="$HERE/glslang-xros$SUFFIX"
BUILD="$HERE/build/glslang-xros$SUFFIX"

mkdir -p "$HERE/src"
if [[ ! -d "$SRC/.git" ]]; then
	echo "== cloning glslang =="
	git clone https://github.com/KhronosGroup/glslang "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$REV" 2>/dev/null || git -C "$SRC" fetch origin
git -C "$SRC" checkout -q "$REV"
echo "== glslang at $(git -C "$SRC" rev-parse --short HEAD) =="

rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
	-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DENABLE_OPT=OFF \
	-DENABLE_HLSL=OFF \
	-DENABLE_GLSLANG_BINARIES=OFF \
	-DENABLE_SPVREMAPPER=OFF \
	-DGLSLANG_TESTS=OFF \
	-DGLSLANG_ENABLE_INSTALL=ON \
	-DBUILD_EXTERNAL=OFF

cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"
cmake --install "$BUILD"

# A .pc, because glslang installs only CMake config files and the consuming
# tree asks pkg-config first. Without one, meson reports glslang not found
# and quietly rebuilds it as a CMake subproject, so this prefix would be
# built and then never used. The version comes from the installed header so
# meson's >=15.1.0 check sees the real one.
INFO="$PREFIX/include/glslang/build_info.h"
ver() { sed -n "s/^#define GLSLANG_VERSION_$1 //p" "$INFO"; }
VERSION="$(ver MAJOR).$(ver MINOR).$(ver PATCH)"
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/glslang.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: glslang
Description: Khronos GLSL front end, static, arm64-apple-xros$SUFFIX
Version: $VERSION
Libs: -L\${libdir} -lglslang -lMachineIndependent -lGenericCodeGen -lOSDependent -lSPIRV -lglslang-default-resource-limits -lc++
Cflags: -I\${includedir}
PC

echo "== installed to $PREFIX (glslang $VERSION) =="
ls "$PREFIX/lib"
