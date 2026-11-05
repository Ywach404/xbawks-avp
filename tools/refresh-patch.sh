#!/usr/bin/env bash
# Regenerate patches/0002-headless-host.patch from the working tree.
#
# The tree is not vendored, so every change to third_party/xemu has to be
# captured back into the series before it can be committed. Doing that by
# hand is the problem this solves: 0001 and 0002 overlap on 12 files,
# including renderer.h and draw.c, so a plain `git diff` against the pin
# produces a 0002 that has swallowed 0001.
#
# The method: rebuild "pin plus 0001" in a scratch repository for exactly
# the paths that differ from the pin, commit that as the base, drop our
# tree on top, and diff. Whatever comes out is ours by construction, with
# no judgement about which hunk belongs to whom.
#
#   ./tools/refresh-patch.sh            write the patch, print what moved
#   ./tools/refresh-patch.sh --check    exit 1 if it would change anything
#
# Nothing in third_party/xemu is touched. The scratch repo is removed on
# exit, including on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TREE="$ROOT/third_party/xemu"
FIRST="$ROOT/patches/0001-apple-silicon-fork.patch"
TARGET="$ROOT/patches/0002-headless-host.patch"

mode="${1:-}"

# The pin has exactly one definition, in setup-tree.sh. Read it, never
# restate it.
PIN="$(sed -n 's/^PIN="\([0-9a-f]\{40\}\)".*/\1/p' tools/setup-tree.sh)"
if [[ -z "$PIN" ]]; then
	echo "could not read PIN from tools/setup-tree.sh" >&2
	exit 1
fi

if [[ ! -d "$TREE/.git" ]]; then
	echo "no checkout at $TREE. Run: ./tools/setup-tree.sh --clone" >&2
	exit 1
fi

have="$(git -C "$TREE" rev-parse HEAD)"
if [[ "$have" != "$PIN" ]]; then
	cat >&2 <<-TXT
	checkout HEAD is $have
	the pin is       $PIN

	The series is applied as working tree changes on top of the pin, so
	HEAD must still be the pin for this to know what is ours.
	TXT
	exit 1
fi

# Every path that differs from the pin. That is 0001's files plus ours,
# which is what the base has to cover. Directories (an untracked build
# tree) and anything gitignored are already excluded by git status.
# Kept in a file rather than an array: macOS ships bash 3.2, which has no
# mapfile, and this script has to run on a stock Mac.
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT INT TERM

changed="$BASE/changed.txt"
git -C "$TREE" status --porcelain \
	| sed 's/^...//' \
	| grep -v '/$' \
	| sort -u >"$changed"
if [[ ! -s "$changed" ]]; then
	echo "nothing differs from the pin" >&2
	exit 1
fi

git -C "$BASE" init -q
# A commit needs an identity and the scratch repo inherits none it can
# rely on. These never leave the temporary directory.
git -C "$BASE" config user.email "refresh@localhost"
git -C "$BASE" config user.name "refresh"
git -C "$BASE" config core.fileMode true

# Pin content for the paths that have one. A path 0001 or we added has
# none, and `git apply` or the copy below creates it.
while IFS= read -r f; do
	git -C "$TREE" cat-file -e "$PIN:$f" 2>/dev/null || continue
	mkdir -p "$BASE/$(dirname "$f")"
	git -C "$TREE" show "$PIN:$f" >"$BASE/$f"
	# The exec bit does not survive `git show`, and a mode that differs
	# from the pin would show up as a spurious mode change in the patch.
	mode_bits="$(git -C "$TREE" ls-tree "$PIN" -- "$f" | awk '{print $1}')"
	if [[ "$mode_bits" == "100755" ]]; then chmod +x "$BASE/$f"; fi
done <"$changed"

# 0001 is not ours and is carried verbatim, so it becomes part of the base.
if ! git -C "$BASE" apply --whitespace=nowarn "$FIRST"; then
	echo "0001 did not apply to the pin. The series is broken, not the tree." >&2
	exit 1
fi
git -C "$BASE" add -A
git -C "$BASE" commit -qm "pin plus 0001"

# Our tree on top. A path we deleted has to be deleted here too, or the
# patch would not record the deletion.
while IFS= read -r f; do
	if [[ -e "$TREE/$f" ]]; then
		mkdir -p "$BASE/$(dirname "$f")"
		cp -p "$TREE/$f" "$BASE/$f"
	else
		rm -f "$BASE/$f"
	fi
done <"$changed"
git -C "$BASE" add -A

out="$BASE/../generated-$$.patch"
trap 'rm -rf "$BASE" "$out"' EXIT INT TERM
git -C "$BASE" diff --cached --binary >"$out"

if [[ ! -s "$out" ]]; then
	echo "the generated patch is empty, which would drop the whole port." >&2
	echo "Refusing to write it." >&2
	exit 1
fi

files="$(grep -c '^+++ b/' "$out" || true)"
added="$(grep -c '^+' "$out" || true)"
removed="$(grep -c '^-' "$out" || true)"

if [[ "$mode" == "--check" ]]; then
	if cmp -s "$out" "$TARGET"; then
		echo "0002 is up to date ($files files)"
		exit 0
	fi
	echo "0002 is stale. Run ./tools/refresh-patch.sh" >&2
	exit 1
fi

if cmp -s "$out" "$TARGET"; then
	echo "0002 unchanged ($files files)"
	exit 0
fi

before="$(grep -c '^+++ b/' "$TARGET" 2>/dev/null || echo 0)"
cp "$out" "$TARGET"
echo "0002 refreshed: $files files, +$added/-$removed lines (was $before files)"
