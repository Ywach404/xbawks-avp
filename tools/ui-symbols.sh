#!/usr/bin/env bash
# What breaks if ui/ is removed, computed without building anything.
#
# S1 removes the SDL3 and ImGui desktop shell, roughly 44,000 lines, and
# replaces main() with a thin C API. The expensive way to find out what that
# breaks is to delete it, relink, read one undefined symbol, fix it, relink.
# Thirty cycles of a QEMU link, each producing a megabyte of log.
#
# The cheap way is that the answer is already sitting in the object files.
# Symbols that ui/ defines, intersected with symbols the rest of the tree
# leaves undefined, is exactly the surface that needs stubbing. One pass of
# nm, no compiler, no linker, about a second.
#
#   ./tools/ui-symbols.sh            the stub surface
#   ./tools/ui-symbols.sh --all      also what ui/ needs FROM the rest
set -euo pipefail
cd "$(dirname "$0")/.."
B="third_party/xemu/build"
[[ -d "$B" ]] || { echo "no build dir. Run ./tools/build-macos.sh" >&2; exit 1; }

# The boundary is NOT ui/. Seventeen files under ui/ are stock QEMU: the
# console, the input stack, the keymaps, pixman glue. They stay, because a
# visionOS host still needs a console to attach to and an input path to feed.
#
# What goes is xemu's own SDL3 and ImGui shell: ui/xemu-*.c and ui/xui/*.cc,
# 33 objects. Measuring against ui/ as a whole overstates the work by about
# 45 symbols that never needed touching.
SHELL_RE='/ui_xemu|/ui_xui|/xemu-version\.c\.o|/xemu-xbe\.c\.o'
ui_objs()    { find "$B" -name '*.o' | grep -E "$SHELL_RE"; }
other_objs() { find "$B" -name '*.o' | grep -vE "$SHELL_RE"; }

# macOS nm: an undefined line is "<spaces>U _sym" (2 fields); a defined one
# is "<addr> T _sym" (3 fields).
defined()   { xargs nm -g 2>/dev/null | awk 'NF==3 && $2!="U" {print $3}' | sort -u; }
undefined() { xargs nm -g 2>/dev/null | awk 'NF==2 && $1=="U" {print $2}' | sort -u; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ui_objs    | defined   > "$tmp/ui_defines"
other_objs | undefined > "$tmp/rest_needs"
ui_objs    | undefined > "$tmp/ui_needs"
other_objs | defined   > "$tmp/rest_defines"

echo "shell objects: $(ui_objs | wc -l | xargs)"
echo "other objects: $(other_objs | wc -l | xargs)"
echo "ui defines:    $(wc -l < "$tmp/ui_defines" | xargs) global symbols"
echo
echo "== THE STUB SURFACE =="
echo "symbols ui/ provides that the rest of the tree needs:"
comm -12 "$tmp/ui_defines" "$tmp/rest_needs" | tee "$tmp/surface" | sed 's/^/  /'
echo
echo "  total: $(wc -l < "$tmp/surface" | xargs)"

if [[ "${1:-}" == "--all" ]]; then
	echo
	echo "== the other direction, for scale only =="
	echo "symbols ui/ needs from the rest (these disappear with it, no work):"
	comm -12 "$tmp/ui_needs" "$tmp/rest_defines" | wc -l | xargs printf "  %s\n"
fi
