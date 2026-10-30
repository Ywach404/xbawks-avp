#!/usr/bin/env bash
# Rebuild third_party/xemu from the pinned upstream commit plus our series.
#
# The tree is 1.34 GB of source and is NOT vendored. This repo holds the
# commit pin and the patches, which is about 2400 lines, and this script
# reconstructs the rest. That keeps what is ours visible instead of buried
# in a vendored copy of QEMU.
#
#   ./tools/setup-tree.sh           apply the series to an existing checkout
#   ./tools/setup-tree.sh --clone   clone upstream at the pin first
#   ./tools/setup-tree.sh --reset   discard local changes, reapply the series
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TREE="$ROOT/third_party/xemu"
UPSTREAM_URL="https://github.com/xemu-project/xemu.git"

# The single definition of the pin. UPSTREAM.md quotes it; this decides it.
PIN="478b4f496102379c7eaa7f3ec10e714a703c4300"

mode="${1:-}"

if [[ "$mode" == "--clone" ]]; then
	if [[ -e "$TREE" ]]; then
		echo "$TREE already exists. Remove it first, or use --reset." >&2
		exit 1
	fi
	echo "== cloning upstream (3 GB, several minutes) =="
	git clone --recurse-submodules --shallow-submodules "$UPSTREAM_URL" "$TREE"
	git -C "$TREE" checkout --quiet "$PIN"
fi

if [[ ! -d "$TREE/.git" ]]; then
	echo "no checkout at $TREE. Run: $0 --clone" >&2
	exit 1
fi

have="$(git -C "$TREE" rev-parse HEAD)"
if [[ "$mode" == "--reset" ]]; then
	echo "== resetting to the pin, discarding local changes =="
	git -C "$TREE" checkout --quiet --force "$PIN"
	git -C "$TREE" clean -qfd
	have="$PIN"
fi

if [[ "$have" != "$PIN" ]]; then
	cat >&2 <<TXT
checkout is at $have
the pin is    $PIN

Either it has moved or the series has already been applied on top. Use
--reset to go back to the pin and reapply.
TXT
	exit 1
fi

# Apply in series order, skipping comments and blanks.
echo "== applying series =="
applied=0
while IFS= read -r line; do
	line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
	[[ -z "$line" ]] && continue
	patch="$ROOT/patches/$line"
	[[ -f "$patch" ]] || { echo "missing patch: $patch" >&2; exit 1; }
	printf '  %-44s ' "$line"
	# --3way so a patch that has drifted says where, instead of silently
	# applying to the wrong place.
	if git -C "$TREE" apply --3way --whitespace=nowarn "$patch"; then
		echo "ok"
		applied=$((applied + 1))
	else
		echo "FAILED"
		echo "  patch did not apply. The tree is left as-is for inspection." >&2
		exit 1
	fi
done < "$ROOT/patches/series"

echo "== $applied patch(es) applied on top of $PIN =="
echo "build with: cd third_party/xemu && see DEVLOG.md for the four macOS fixes"
