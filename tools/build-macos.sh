#!/usr/bin/env bash
# Build the reconstructed tree on macOS arm64.
#
# The upstream build instructions fail four times on a clean macOS 26, and
# none of the four say what is actually wrong. They are all handled here.
#
#   ./tools/build-macos.sh          build
#
# XEMU_EXTRA_OPTS is forwarded to configure, which forwards to meson. The
# visionOS build needs fewer libraries than the desktop one, and the
# cheapest library to cross-compile is the one that is not there:
#
#   XEMU_EXTRA_OPTS="-Dopengl=disabled" ./tools/build-macos.sh
#
# -Dopengl=disabled is the one that matters: it removes libepoxy, the
# OpenGL framework and the IOSurface presentation path, leaving a binary
# whose only Apple frameworks are CoreFoundation, IOKit, Security and
# Foundation, all of which exist on visionOS.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TREE="$ROOT/third_party/xemu"
VENV="$ROOT/.build-venv"
LOG="$ROOT/build.log"

[[ -d "$TREE" ]] || { echo "no tree. Run ./tools/setup-tree.sh --clone" >&2; exit 1; }

export PATH="/opt/homebrew/bin:$PATH"

# Fix 1. build.sh passes --cross-prefix=, which puts meson in cross mode,
# and in cross mode meson will not fall back to PATH to find cmake. It then
# reports "Unable to find CMake" with cmake plainly installed. This matters
# because the bundled macos-libs ship no glslang.
export CMAKE=/opt/homebrew/bin/cmake

# Fix 2. scripts/gen_config.py imports yaml, and pythondeps.toml never
# declares it, so configure's own venv does not have it. Installing into
# build/pyvenv does not survive either, because configure recreates it with
# --clear. A venv passed in with --python= does survive.
if [[ ! -x "$VENV/bin/python3" ]]; then
	echo "== creating build venv with PyYAML =="
	/opt/homebrew/bin/python3 -m venv "$VENV"
	"$VENV/bin/pip" install -q --upgrade pip
	"$VENV/bin/pip" install -q pyyaml
fi

echo "== building (this takes a while; full log at $LOG) =="
cd "$TREE"
if ! ./build.sh --python="$VENV/bin/python3" ${XEMU_EXTRA_OPTS:-} > "$LOG" 2>&1; then
	echo "BUILD FAILED. Errors:" >&2
	# Never print the whole log: it is about 1 MB.
	grep -E '(^|[^a-z])(error|Error|FAILED):' "$LOG" | sort -u | head -40 >&2
	exit 1
fi

# Fix 3. dylibbundler -of rewrites all three existing rpaths to the same
# string, and macOS 26's dyld rejects duplicate LC_RPATH outright, so the
# app will not launch at all. Remove the duplicates and re-sign.
#
# Count LC_RPATH entries properly rather than grepping the whole load
# command dump for the path string. That string also appears as the `name`
# of every LC_LOAD_DYLIB, since dylibbundler writes @executable_path
# directly rather than using @rpath, so a raw grep finds nine matches on a
# binary with zero rpaths and a delete loop keyed on it never terminates.
E="$TREE/dist/xemu.app/Contents/MacOS/xemu"
[[ -f "$E" ]] || { echo "built, but no binary at $E" >&2; exit 1; }
rpath_count() {
	otool -l "$E" | awk '/^ *cmd LC_RPATH$/{f=1;next} f&&/^ *path /{print $2;f=0}' \
		| grep -cFx '@executable_path/../Libraries/arm64/' || true
}
# Exactly one is correct. Not zero: some bundled dylibs reference each other
# through @rpath (libglib wants @rpath/libiconv.2.dylib), so stripping them
# all gives "Library not loaded ... Reason: no LC_RPATH's found".
while [[ "$(rpath_count)" -gt 1 ]]; do
	install_name_tool -delete_rpath '@executable_path/../Libraries/arm64/' "$E" || break
done
if [[ "$(rpath_count)" -eq 0 ]]; then
	install_name_tool -add_rpath '@executable_path/../Libraries/arm64/' "$E"
fi
codesign --force --sign - "$E"

echo "== built: $E =="
ls -la "$E" | awk '{printf "   %.1f MB\n", $5/1048576}'
lipo -info "$E" 2>/dev/null | sed 's/^/   /'
