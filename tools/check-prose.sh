#!/usr/bin/env bash
# No em dashes or en dashes in anything this repo authors.
#
# Scope is deliberately "files we wrote", which means tracked files minus
# the upstream patch. Everything else on disk is somebody else's: the
# reconstructed QEMU tree, build output, a Python venv full of vendored pip
# code, the owner's media. Checking those produces false positives and
# teaches you to ignore the check.
set -euo pipefail
cd "$(dirname "$0")/.."

bad=0
while IFS= read -r f; do
	case "$f" in
		patches/*.patch) continue ;;   # upstream's prose, not ours
		*.iso|*.bin|*.png) continue ;;
	esac
	[[ -f "$f" ]] || continue
	if hits=$(grep -nP '\x{2014}|\x{2013}' "$f" 2>/dev/null); then
		echo "$f:"; echo "$hits" | sed 's/^/  /'
		bad=1
	fi
done < <(git ls-files)

if (( bad )); then
	echo
	echo "Use a comma, a colon, parentheses, a full stop, or --"
	exit 1
fi
echo "clean: no em or en dashes in $(git ls-files | wc -l | xargs) tracked files"
