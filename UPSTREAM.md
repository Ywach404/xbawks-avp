# Upstream provenance

This repository holds a **commit pin and a patch series**, not a vendored
tree. `third_party/xemu` is reconstructed, never committed:

```sh
./tools/setup-tree.sh --clone     # first time, clones upstream at the pin
./tools/setup-tree.sh             # apply the series
./tools/setup-tree.sh --reset     # back to the pin, reapply
```

## Why not vendored

The Quake port vendored QuakeSpasm as a subset, and that was right there: the
whole vendored tree is 3.0 MB. xemu is a QEMU fork and its source is
**1.34 GB**, about 450 times larger, while everything that is not upstream
comes to roughly 2,400 lines. Vendoring would bury a 2,400 line delta inside
1.34 GB of somebody else's code, in a repository with a remote.

The series keeps the same discipline the Quake port got from counting its six
patched hunks: what is ours stays visible, enumerated and reviewable. It also
means upstream can be moved by changing one line and seeing what fails to
apply.

## The pin

- Upstream: `github.com/xemu-project/xemu`
- Commit: `6095054b7d02dfac25fdc4a8ba9300358046e860`
- Upstream date: 2026-11-02
- `git describe`: `pre-release` (xemu does not tag releases in-tree)
- Licence: GPL-2.0. QEMU's `LICENSE` and `COPYING` apply and xemu adds no
  separate licence. Upstream licence headers are preserved on every file.

The pin has exactly one definition, `PIN` in `tools/setup-tree.sh`. This
file quotes it; that script decides it. Never restate it anywhere else.

Submodules are 15 QEMU firmware ROMs and CI tooling, none xemu-specific. The
xemu third-party code (ImGui, fpng, stb_image, fatx, Font Awesome) lives
in-tree under `ui/thirdparty`.

### Moving it

Both patches have to be rebased, not just ours, because 0001 carries the
upstream context it was cut against and goes stale the moment the pin
moves. `refresh-patch.sh` only regenerates 0002 and will refuse outright
when 0001 no longer applies, which is the correct failure and the signal
that this is the job.

The method, in the order that works:

1. Check out the new pin in the tree and apply 0001 with `--3way`. It has
   to be the real tree: a scratch repository lacks the blobs a three way
   merge needs and falls back to a plain apply, which rejects every hunk
   that merely drifted and silently loses them.
2. Resolve whatever conflicts remain, then regenerate 0001 by staging
   **only the files 0001 itself lists**. Never `git add -A`: the build
   directory is untracked but not ignored, so staging everything puts
   thousands of object files in the patch, and a later `git checkout
   --force` then deletes the build tree because the index now claims it.
3. Snapshot that state as the base, restore our work on top, and
   regenerate 0002 against the base.
4. Verify by applying both patches to a fresh tree at the new pin and
   comparing every file byte for byte.

## The series

`patches/series`, applied in order. Keep one file per logical change and
explain each one here, because a patch that does six unrelated things defeats
the format.

Changes go into the tree first and are captured back with:

```sh
./tools/refresh-patch.sh            # rewrite 0002 from the working tree
./tools/refresh-patch.sh --check    # exit 1 if 0002 is stale
```

Do not write a patch by hand and do not diff against the pin directly. 0001
and 0002 overlap on 12 files, `renderer.h` and `draw.c` among them, so a plain
diff from the pin produces a 0002 that has swallowed 0001. The script rebuilds
"pin plus 0001" in a scratch repository, drops the tree on top and diffs, so
what comes out is ours by construction rather than by judgement.

### 0001-apple-silicon-fork.patch

**Not ours.** `github.com/zlixas/xemu` at `99db55071ad8c4ac02fcdd65eb159abe68b4ae37`,
branch `m4-perf`, 2026-10-03. GPL-2.0, same as xemu, so it is liftable with
attribution. 56 files, +2273, -145. Verified 2026-10-24 to reconstruct
that fork's source tree exactly against the pin of that date. Rebased
2026-11-10 onto the current pin: three hunks in the OpenGL renderer had
drifted, where upstream had replaced an assert macro and a fence call inside
code the fork rewrites entirely, and were resolved in the fork's favour and
kept verbatim. The delta is the fork's; the tree it applies to has moved.

It is here because **upstream's Vulkan renderer cannot create a device on
Metal**: it requires `geometryShader` unconditionally and Metal has no
geometry shaders. Without this patch there is no working renderer on Apple
hardware at all.

What it contains:

- `geometryShader` made optional on Apple, with fixed-function depth plus
  polygon offset replacing the geometry shader path
- an **IOSurface display path** replacing the SDL-backed `gloffscreen`
  Vulkan-to-GL interop (`vk/renderer.h:44-54`). This is what makes a
  windowless framebuffer plausible, and IOSurface is a zero-copy route to
  an `MTLTexture` later.
- quads converted to indexed triangles, preserving provoking-vertex
  semantics
- NEON-optimised packed SSE, with a non-aarch64 fallback
- Xbox kernel idle-loop halt, matched on `KiIdleLoop`'s signature and
  revalidated at runtime
- poll-loop sleep detection, OpenGL state caching, a larger jump cache

Known hazard, carried knowingly: `is_xbox_poll_loop` sets its `fresh` bitmask
unconditionally for `0x8b mov r32,r/m32`, so a pointer-chasing loop can be
read as a poll loop. Results stay correct but a long list walk can stall up
to 250 us. Upstream tried the same idea on branch `fix/detect-spins`
(`029bc377a1`, 2021-11-03) and never merged it.

Splitting this into its roughly 8 separable parts is possible and is deferred
until something in it needs changing.

## Never committed here

BIOS images, the MCPX boot ROM, HDD images, game ISOs and XBEs. All of it is
user-supplied at runtime. `.gitignore` denies the extracted forms, the
archive formats that wrap them, and the drop directory by name.
