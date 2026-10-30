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
- Commit: `478b4f496102379c7eaa7f3ec10e714a703c4300`
- Upstream date: 2026-09-28
- `git describe`: `pre-release` (xemu does not tag releases in-tree)
- Licence: GPL-2.0. QEMU's `LICENSE` and `COPYING` apply and xemu adds no
  separate licence. Upstream licence headers are preserved on every file.

The pin has exactly one definition, `PIN` in `tools/setup-tree.sh`. This
file quotes it; that script decides it. Never restate it anywhere else.

Submodules are 15 QEMU firmware ROMs and CI tooling, none xemu-specific. The
xemu third-party code (ImGui, fpng, stb_image, fatx, Font Awesome) lives
in-tree under `ui/thirdparty`.

## The series

`patches/series`, applied in order. Keep one file per logical change and
explain each one here, because a patch that does six unrelated things defeats
the format.

### 0001-apple-silicon-fork.patch

**Not ours.** `github.com/zlixas/xemu` at `99db55071ad8c4ac02fcdd65eb159abe68b4ae37`,
branch `m4-perf`, 2026-10-03. GPL-2.0, same as xemu, so it is liftable with
attribution. 56 files, +2270, -142. Verified 2026-10-24 to reconstruct that
fork's source tree exactly.

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
