# xemu-avp DEVLOG

Facts only: commands, results, measurements. Rationale sections are left as
TODOs for the project owner.

## S0 -- JIT probe

Probe written 2026-10-22, builds, validated on the simulator, **not yet run on
the headset**. Code and protocol: `probes/jit-probe/`.

Five allocation paths (plain anonymous RWX with nothing else, which is what
PPSSPP, DolphiniOS and UTM's debugged-JIT path do; MAP_JIT with the
write-protect toggle; MAP_JIT without it; plain RW then mprotect R+X; MAP_JIT
RW then mprotect R+X), crossed with three launch modes (plain, attached,
attached then detached). Reports the full `csops` status word alongside each
result. Accepts a path as executed only when the hand-assembled stub returns
42.

Simulator baseline, visionOS 27.0, `make check` then `simctl launch`:

```
CS_DEBUGGED: no
code signing status: 0x22020201 VALID KILL
pthread_jit_write_protect_np: resolved
pthread_jit_write_protect_supported_np: resolved, returns 1
D  (plain RWX, no MAP_JIT)       FAILED at mmap, errno 13 (Permission denied)
A  (MAP_JIT + toggle)            EXECUTED, returned 42
A' (MAP_JIT, no toggle)          FAILED at write, signal 10 (Bus error)
B  (plain RW then mprotect RX)   EXECUTED, returned 42
C  (MAP_JIT RW then mprotect RX) EXECUTED, returned 42
3 of 5 paths executed
```

A simulator process inherits macOS policy, so this measures the probe, not
the platform. A' failing at the write is expected: MAP_JIT pages start
execute-protected, and the signal guard caught the fault and continued. D
failing with EPERM is also expected under macOS policy, and is the result
worth watching on device, because iOS-family kernels can invert it: MAP_JIT
refused without the dynamic-codesigning entitlement, plain RWX allowed once
CS_DEBUGGED is set.

Device build verified: `arm64`, `LC_BUILD_VERSION platform VISIONOS minos
26.0 sdk 27.0`, `_mmap _mprotect _dlsym _sys_icache_invalidate` all linked.
Compiles with `CODE_SIGNING_ALLOWED=NO`, so only signing is untested.

Open: run all three modes on device and paste the report here.

```sh
cd probes/jit-probe
DEV_TEAM=XXXXXXXXXX make run        # mode 1, plain
DEV_TEAM=XXXXXXXXXX make run-debug  # modes 2 and 3
```

Device result, 2026-10-22, the owner's Apple Vision Pro, visionOS 27, Xcode 27.0 (27A5218g),
signed Apple Development, free personal team.

**Zero of five paths executed, in every launch mode. Not once did any path
return 42.**

| path | mode 1, plain | mode 2, attached | mode 3, after detach |
|---|---|---|---|
| D, plain RWX | SIGKILL at call | fault at call | fault at call |
| A, MAP_JIT + toggle | `mmap` EPERM | `mmap` EPERM | `mmap` EPERM |
| A', MAP_JIT bare | `mmap` EPERM | `mmap` EPERM | `mmap` EPERM |
| B, RW then mprotect RX | SIGKILL at call | fault at call | fault at call |
| C, MAP_JIT RW then mprotect | `mmap` EPERM | `mmap` EPERM | `mmap` EPERM |

Code signing status word, which is where the attach trick shows up:

- mode 1: `0x22003305` VALID GET_TASK_ALLOW **HARD KILL** ENFORCEMENT,
  `CS_DEBUGGED: no`
- modes 2 and 3: `0x32003005` VALID GET_TASK_ALLOW ENFORCEMENT,
  `CS_DEBUGGED: YES`

So the attach does exactly what it is supposed to: `CS_HARD` and `CS_KILL`
clear, and `CS_DEBUGGED` sets and survives the detach. It changes the
*failure mode* from an uncatchable SIGKILL to a trappable fault. It does not
make the page executable.

`pthread_jit_write_protect_np` is **NOT RESOLVABLE** on device. The symbol is
absent, not merely unavailable to the compiler.

`MAP_JIT` returns EPERM from `mmap` in all three modes. It requires the
`dynamic-codesigning` entitlement, which is not issued to third-party apps.

The decisive observation, from lldb at the stop in path B:

```
thread #1: tid = 0x5920f, 0x00000001042e0000, queue = 'com.apple.main-thread',
stop reason = EXC_BAD_ACCESS (code=2, address=0x1042e0000)
```

The program counter equals the page address and equals the faulting address,
so it failed on the **first instruction fetch**. `code=2` is a protection
failure. `mprotect(PROT_READ|PROT_EXEC)` had returned success on that page
moments earlier. The kernel accepts the request, reports no error, and
refuses the execute at fault time. Nothing in the API surface signals this.

`EXC_BAD_ACCESS` is a Mach exception, caught by lldb before it can become a
UNIX signal, so `process handle -p true SIGBUS SIGSEGV SIGILL` does not pass
it through and the process re-faults at the same address on `continue`.
Detaching is what hands the fault back to the process.

Conclusion: **there is no JIT on visionOS 27, in any launch mode available to
a sideloaded app, including attach-then-detach.** QEMU's TCG cannot run.
Raw journal preserved at `probes/jit-probe/RESULT-journal.txt`.

## S1 -- headless macOS arm64 build, Vulkan via MoltenVK

Not started. Gated on S0.

## Pre-S1 -- upstream checkout (2026-10-08)

- `git clone --recurse-submodules --shallow-submodules https://github.com/xemu-project/xemu.git third_party/xemu`
- Result: commit `478b4f496102379c7eaa7f3ec10e714a703c4300`, dated 2026-09-28,
  `git describe` = `pre-release`.
- Size: 3.2 GB checkout, of which 1.9 GB is `.git`.
- Submodules: 15, all QEMU ROMs/CI (`roms/*`, `tests/lcitool/libvirt-ci`).
- NV2A pgraph backends present upstream: `gl`, `vk`, `null`.
- Provenance recorded in `UPSTREAM.md`. Checkout is gitignored pending the
  vendor-vs-submodule decision in S1.

## 2026-10-22 -- feasibility pass

SDK availability, Xcode 27.0 (27A5218g), `XROS27.0.sdk`,
`usr/include/pthread/pthread.h:586-592`:

```
__API_AVAILABLE(macos(11.0))
__API_UNAVAILABLE(ios, tvos, watchos, driverkit)
void pthread_jit_write_protect_np(int enabled);

__API_AVAILABLE(macos(11.0), ios(17.4))
__API_UNAVAILABLE(tvos, watchos, driverkit, visionos)
int pthread_jit_write_protect_supported_np(void);
```

`MAP_JIT` is defined in the xros `sys/mman.h` at the same value as macOS
(0x0800), but that header is shared across Darwin platforms and is not
evidence of a grant.

Upstream survey, `third_party/xemu` at 478b4f49 (QEMU 10.2.0 base):

- TCG in use. No HVF: Hypervisor.framework cannot run an x86 guest on an
  arm64 host (`meson.build:932-940`, `949-977`).
- `tcg/aarch64/` present, 3575 lines. TCI present: `tcg/tci.c` 1094 lines,
  `tcg/tci/tcg-target.c.inc` 1327. Option `tcg_interpreter`,
  `meson_options.txt:98`, default false. Requires libffi >= 3.0
  (`tcg/meson.build:19-24`). Disables plugins (`configure:1064-1070`).
- Under TCI the code buffer is RW only (`tcg/region.c:815-820`), but MAP_JIT
  is still requested on Darwin regardless (`tcg/region.c:712-718`), and five
  `pthread_jit_write_protect_np` call sites are not TCI-guarded
  (`accel/tcg/translate-all.c:278`, `tb-maint.c:975,977`,
  `cpu-exec.c:460,643`).
- `xemu.entitlements` already requests `com.apple.security.cs.allow-jit` and
  `allow-unsigned-executable-memory`, both macOS hardened runtime only.
- No iOS or visionOS references anywhere outside `roms/`.

Renderer:

- `hw/xbox/nv2a/pgraph/`: `vk` 22 files / 12,400 lines, `gl` 15 / 6,239,
  `null` 1 / 146.
- `gl` is the default (`pgraph.c:254-267`).
- Zero SDL references inside `vk/`. No `VkSurfaceKHR` and no swapchain: it
  renders offscreen into a VkImage.
- `vk/renderer.c:22` includes `gloffscreen.h`, which is SDL-backed
  (`pgraph/thirdparty/gloffscreen/sdl.c`), for Vulkan-to-GL external memory
  interop. `HAVE_EXTERNAL_MEMORY` is hardcoded 1 at `vk/renderer.h:44`.
  Non-interop CPU-readback fallback exists at `vk/renderer.c:200-203`.
- Renderer-to-UI seam is GL-typed: `pgraph.h:133` returns a `GLuint`,
  consumed at `ui/xemu.c:851`.

Shell and build:

- SDL3, not SDL2 (`meson.build:1674-1721`).
- All stock QEMU UI backends compiled out (`ui/meson.build:92`), so there is
  no `-display none` path. QEMU's own `main` is disabled under `-DXBOX=1`;
  the entrypoint is `ui/xemu.c:1343`, which hard-exits below GL 4.0
  (`:1108-1125`).
- SDL outside `ui/`: `hw/xbox/xblc.c` (28 hits), `hw/xbox/mcpx/apu/monitor.c`
  (16, the APU audio out), `apu/apu.c`, `apu/vp/vp.c:1771`,
  `apu/dsp/interp/dsp_cpu.c:669`.
- `opengl` is effectively unconditional in a system build
  (`meson.build:1887`); `-Dopengl=disabled` still enters the branch, which
  then picks `-framework OpenGL` on darwin.
- No iOS or visionOS cross file. `build.sh` aborts on any platform other
  than Linux, Darwin, MSYS, win64-cross.
- Line counts: `hw/xbox/` 58,775, `ui/` 56,924 (43,958 excluding thirdparty),
  `target/i386/` 77,879, `tcg/` 63,431.

Prior art, `github.com/zlixas/xemu` (GPL-2.0, bundled MoltenVK Apache-2.0),
claims on a MacBook Air M4, macOS 26, 60 Hz vsync, Crash Twinsanity title
screen and intro:

- 60 fps vsync-locked against upstream 18.3 fps
- 0.90 cores at 60 fps, emulation thread 32 percent
- Vulkan about 30 percent less CPU than OpenGL

TCG throughout, no hardware virtualisation. Unverified here, one star, and a
title screen is not a gameplay benchmark.

Open: reproduce on the M5 with your own BIOS and media, and record the
number. That is the ceiling; the headset lands under it.

## 2026-10-22 -- Mac-side ceiling build

Built `github.com/zlixas/xemu` (commit `99db5507`, parent `478b4f49`) on this
M5 to establish the performance ceiling. Work in
`spatial/_scratch/xemu-mac-ceiling/`, full review in its `FINDINGS.md`.

Result: `dist/xemu.app/Contents/MacOS/xemu`, 16.6 MB, arm64, ad-hoc signed.
Both renderers compiled in; the renderer is a runtime setting.

The fork's own build instructions fail four times on clean macOS 26. Working
sequence:

```sh
brew install meson pkgconf ninja cmake vulkan-headers molten-vk dylibbundler glslang
python3.15 -m venv .../xemu-build-py && .../bin/pip install pyyaml
export PATH="/opt/homebrew/bin:$PATH" CMAKE=/opt/homebrew/bin/cmake
./build.sh --python=.../xemu-build-py/bin/python3
# then, every time:
E=dist/xemu.app/Contents/MacOS/xemu
install_name_tool -delete_rpath "@executable_path/../Libraries/arm64/" "$E"
install_name_tool -delete_rpath "@executable_path/../Libraries/arm64/" "$E"
codesign --force --sign - "$E"
```

The four failures, none needing a source change:

1. `Unable to find CMake` with cmake installed. `build.sh` passes
   `--cross-prefix=`, so meson runs in cross mode and will not fall back to
   PATH for cmake. `export CMAKE=` fixes it. Matters because `macos-libs`
   ships no glslang.
2. `ModuleNotFoundError: No module named 'yaml'`. `gen_config.py` imports
   yaml, `pythondeps.toml` never declares it. Upstream xemu packaging bug.
   Installing into `build/pyvenv` does not survive, configure recreates it
   with `--clear`, so `--python=` at a venv holding PyYAML is the fix.
3. `dyld: duplicate LC_RPATH`, app would not launch. `dylibbundler -of`
   rewrites all three existing rpaths to the same string and macOS 26's dyld
   rejects duplicates. Upstream's `package_macos`, not the fork's.
4. Benign link warnings: Homebrew glslang and SPIRV-Tools built for macOS 26
   while the target is 14.0.

Vulkan through MoltenVK verified initialising on this machine, renderer
forced to VULKAN:

```
Loaded Vulkan implementation: /opt/homebrew/lib/libMoltenVK.dylib
Selected physical device: Apple M5 Max
Enabled device extensions: VK_EXT_metal_objects, VK_EXT_memory_budget,
                           VK_KHR_portability_subset
VK: no geometry shader support, using fast depth
```

Upstream `pgraph/vk/instance.c` requires `geometryShader` unconditionally
(`F(geometryShader, true)`), so upstream's Vulkan renderer cannot create a
device on MoltenVK at all. The fork sets it false on Apple and routes through
fast depth. `VK_EXT_metal_objects` is enabled, which is what S3 needs.

MoltenVK is `dlopen`ed, not linked: `otool -L` shows no reference and nothing
matching it is inside the app bundle. It resolved here only because
Homebrew's `molten-vk` is installed.

Fork provenance: one commit of its own, pushed within 43 seconds of repo
creation, never touched again. 1 star, 0 forks, `ahead_by: 1, behind_by: 34`.
No tests and no benchmark harness in the repo. SPDX GPL-2.0-or-later headers
intact on all 5 new files.

Hazard in the poll-loop detector: `is_xbox_poll_loop` sets its `fresh`
bitmask unconditionally for `0x8b mov r32,r/m32`, so a pointer-chasing loop
is accepted as a poll loop. Results stay correct, but a long list walk can
stall up to 250 us per iteration. Upstream attempted the same idea on branch
`fix/detect-spins` (tipped `029bc377a1`, 2021-11-03) and never merged it.

Machine state changed by the build: Homebrew installed python@3.15, which is
now `/opt/homebrew/bin/python3`, and upgraded ffmpeg 8.1.2 to 9.0.2 plus
libvpx, x265, libvmaf and sdl2-compat. Also note `brew install sdl2` now
resolves to sdl2-compat (SDL2 API over SDL3), not real SDL2.

To run it:

```sh
spatial/_scratch/xemu-mac-ceiling/fork/dist/xemu.app/Contents/MacOS/xemu
```

Stops at `Failed to load BIOS '(null)'`. Settings > System wants the MCPX
boot ROM (`mcpx_1.0.bin`, 512 bytes), a BIOS image, and an HDD image
(`xbox_hdd.qcow2`). The EEPROM was generated by xemu itself and already
exists at `~/Library/Application Support/xemu/xemu/eeprom.bin`. A game disc
image is needed only to measure a real title. None of those files were
obtained; all are user-supplied.

To measure:

```sh
XEMU_PERF_LOG=1 <same path> 2>&1 | grep --line-buffered '^perf:'
```

Toggle Settings > Display > Renderer and Fast depth to compare paths.

Open: supply the files and record the numbers. Note what the fork's
own figures do and do not mean: 18.3 to 60 fps is a graphics result from
dropping geometry shaders, and 0.90 cores comes largely from sleeping (kernel
idle halt, poll-loop sleep), so neither is a TCG measurement. The CPU ceiling
this port depends on is still unmeasured.

## 2026-10-22 -- first boot, and the first real numbers

Owner supplied the system files. Copies used, originals untouched:
MCPX `mcpx-1.0.bin` (512 B), the BIOS image (1 MiB), HDD
`xbox_hdd.qcow2` (2.0 GB on disk, 8 GiB virtual, original Dashboard).
Copied to `_scratch/xemu-mac-ceiling/media/` because booting writes to the
disk image.

**The Xbox dashboard boots and runs.** Confirmed visually: the Xbox Live
notice screen renders correctly.

Configuration gotcha that cost a boot: `flashrom_path` is read but `-bios` is
never added to the QEMU argv while `general.show_welcome` is true.
`system/vl.c:3042` takes the welcome branch, sets `autostart = 0` and skips
the BIOS entirely, so the machine starts with no BIOS and reports
`Failed to load BIOS '(null)'` (`hw/xbox/xbox.c:101`) with the path correctly
set in the config. Setting `show_welcome = false` fixes it. The UI only ever
reads `flashrom_path` in the file picker (`ui/xui/main-menu.cc:1564`); the
machine takes it from `ms->firmware`, i.e. QEMU's `-bios`.

Same workload both runs: Xbox dashboard, idle at the notice screen, 640x480,
vsync off, `XEMU_PERF_LOG=1`, M5 Max, 18 logical cores (6 + 12), macOS 26.5.2,
no thermal or performance warnings recorded.

| renderer | fps | process CPU | RSS |
|---|---|---|---|
| Vulkan via MoltenVK | 59.8 to 60.3 | 1.52 to 1.57 cores | 584 MiB |
| OpenGL | 59.9 to 60.1 | 1.84 to 1.90 cores | 752 MiB |

Vulkan costs about 18 percent less CPU and 22 percent less memory than
OpenGL on this workload. The fork's README claims about 30 percent less CPU;
measured here it is 18.

Per-thread, Vulkan run: hottest thread 37.4 percent of one core, second
30.3 percent, third 7.9 percent. The hottest is the emulation thread, and it
is the number that matters, because TCG emulation of a single-core guest does
not parallelise.

**What these numbers do not say.** 60 fps is the dashboard's own native rate,
so this is "full speed reached", not headroom. The dashboard is close to an
idle workload: 135 begin/end pairs and 296 attribute binds per frame. And an
M5 Max with 18 cores is a generous stand-in for the Vision Pro's M5.

Open: supply a game disc image. A CPU-bound scene is the only thing
that turns this into a ceiling.

## 2026-10-22 -- deterministic benchmark baseline, both renderers

Ran `abaire/xemu-perf-tests` (release `v2026-10-20_16-30-32-683342094`,
`xemu-perf-tests_xiso.iso`, 3,014,656 bytes, sha256
`f523f44982899aad6ccede627a3e60fac245965d20033043cd1f6915612c8c3f`) through
`abaire/xemu-perf-tester`, driving our own build rather than a downloaded
release. Open-source nxdk homebrew, not commercial media. Results were not
uploaded: `--upload-results` was never passed.

53 benchmarks, both renderers, same ISO, same BIOS and MCPX, same machine.

```sh
perf-venv/bin/xemu-perf-run \
  --xemu  _scratch/xemu-mac-ceiling/fork/dist/xemu.app \
  --iso   _scratch/xemu-mac-ceiling/media/xemu-perf-tests.iso \
  --bios  <media>/bios.bin \
  --mcpx  _scratch/xemu-mac-ceiling/media/mcpx-1.0.bin \
  --results-path ... --cache-path ... [--use-vulkan]
```

Totals across all 53, sum of `average_us`:

| renderer | total | ratio |
|---|---|---|
| OpenGL | 1,918,125 us | 1.000 |
| Vulkan via MoltenVK | 1,882,647 us | 0.982 |

Median per-test ratio VK/GL 0.981, mean 1.042, Vulkan faster on 36 of 53.
So on guest-visible throughput the two are near parity, with Vulkan slightly
ahead and a long tail where it is much worse. That is a different measure
from the dashboard result above, which was host CPU: Vulkan costs about 18
percent less host CPU while delivering roughly the same guest throughput.

**The regression that matters for S3.** Vulkan's two worst results are both
surface readback:

| test | OpenGL | Vulkan | ratio |
|---|---|---|---|
| `SurfaceRendering::XemuSurfaceDownloadPath` | 21,763 us | 48,789 us | 2.24x |
| `SurfaceRendering::SurfaceRendering` | 22,903 us | 39,793 us | 1.74x |

Getting rendered pixels back out of the Vulkan renderer is more than twice
as expensive as under OpenGL. S3 plans to hand the framebuffer to Metal, and
if that goes through a download path rather than a zero-copy
`VK_EXT_metal_objects` share, this is the cost it pays. The extension is
confirmed enabled (see the boot log above), so the zero-copy route exists;
this number is what the fallback costs.

Vulkan's best results, for contrast: `PrimitiveType-LLoop` 0.57x,
`TinyDraw-inlineelements` 0.83x, `TinyAlloc-arrays` 0.84x.

Two changes were needed in the orchestrator, both in the scratch venv only,
both with `.orig` backups alongside:

1. `util/xemu.py`, `_XEMU_FORK_PR_RE` is `r"xemu-" + VERSION + r"-\s+-.*"`,
   which expects literal whitespace and so rejects any real fork version.
   Our `xemu-0.8.136-m1-<sha>` fails every pattern. Relaxed to
   `r"xemu-" + VERSION + r"-.*"`, which parses it as 0.8.136, branch
   "Unofficial".
2. `runner.py:111`, `_determine_xemu_info` gives xemu a 1 second timeout to
   print its version banner. Under Vulkan, MoltenVK loading and device
   enumeration overrun that, the banner is missed, and the run dies later
   with `Invalid xemu version string ''` rather than anything pointing at a
   timeout. Raised to 10 seconds. OpenGL was unaffected, which is why the
   first run succeeded and only the Vulkan one failed.

**What this baseline is for.** Absolute numbers on an M5 Max say little on
their own. The value is that the suite is deterministic, so the identical 53
tests can be run again on the headset, or against a different TCG backend,
and compared directly. That is the comparison a game can never give, because
no two playthroughs render the same frames.

Still unmeasured: a CPU-bound workload. These are pgraph tests and they
exercise the graphics path, not the TCG translation of a game's logic.

Raw results, with every per-iteration timing:
`_scratch/xemu-mac-ceiling/perf-results-{gl,vk}/`

## 2026-10-22 -- S0 reopened: a mode the probe never tested

The weekly watcher found this on its first run, hours after S0 was recorded.

`github.com/illixion/Apparition`, MIT, roughly 118 commits, 2 stars, 3 forks.
A device-based sideloader for Vision Pro, iPhone, iPad and Apple TV.

**It independently corroborates the S0 result.** Its README states:

> iOS 26 on A15 and M2 and later, and visionOS 27 on Vision Pro, no longer
> let an app run code it generates just because a debugger attached once and
> set `CS_DEBUGGED`. That old trick is what SideStore's JIT button still does.

That is exactly what mode 3 measured here, found independently by someone
else, on the same OS version, on the same hardware.

**But it claims a fourth mode, which the probe did not test.** Its approach:

> Launch with JIT keeps the debugger attached and prepares the memory the app
> asks for, on the device itself

So the debugger stays attached for the whole session, and **the debugger
prepares the memory rather than the app**. Every path the probe tested had
the app call `mmap` and `mprotect` for itself. Under a persistent attach the
privileged side of the pair does the work, which is a different question and
may be why it sidesteps the fault at `EXC_BAD_ACCESS` code 2.

Protocol is "JIT26", originated by StikDebug, plus UTM's own. One documented
command is `x16 = 0x4150`, "copy x2 bytes from x1 to x0", which reads like a
trap-based RPC: the app traps, the debugger services the request. A separate
experimental finding in that project is that bytes a debugger writes directly
into an app's signed `__TEXT` keep executing after the debugger detaches,
observed on visionOS 27.2. If that is the real mechanism it is not making new
memory executable at all, it is overwriting memory that already is.

Claimed on a real Vision Pro: UTM running Alpine Linux running a PS2
emulator running GTA San Andreas. That is far heavier than this port needs,
so if it holds it is a strong existence proof.

Primary source for the claims is
`blog.illixion.com/2026/10/building-apparition/`, which states verbatim that
"Grand Theft Auto: San Andreas booted on the Vision Pro and ran perfectly" in
ARMSX2 with JIT, alongside UTM booting Alpine through StikDebug, Node and V8,
and a PS1 emulator's dynarec. The post carries screenshots plus a video demo.
Owner reviewed the video on 2026-10-22 and judged the mechanism to work.

Two lines from that post matter more than the demo does:

> Only a mapping that already allows execute, and that the debugger wrote to
> while attached, can run code after detach

> The app can make writable views of the prepared memory at any time

The second removes the obvious objection. A trap into the debugger per code
write would have been fatal, because TCG translates blocks continuously
during play. A writable alias onto a prepared region means the debugger pays
a setup cost once and TCG writes normally afterwards. The cost that remains
is that the debugger has to touch every 16 KiB page to prepare it, and
QEMU's code buffer is tens to hundreds of megabytes, so that is thousands of
pages at startup. Slow boot, not slow frames.

Requests are made with `brk #0xf00d`.

Confidence in the mechanism: good. Confidence that it fits THIS port:
unknown, and that is now the open question rather than whether JIT is
possible at all. None of it contradicts a single measurement in S0: `MAP_JIT`
is still EPERM and app-side `mprotect` still refuses the instruction fetch.
It opens a path beside them.

The demonstrated apps are windowed. **Nothing in that demo exercises a
CompositorServices immersive space at 90 or 120 Hz with a debugger attached**,
which is what this port would need and which is precisely the combination
that has failed on this machine before.

Open: decide whether the operational cost is acceptable before any
engineering. A persistent attached debugger for the entire session is a
heavier tax than the attach-then-detach that was weighed earlier, and prior
work on this machine found an attached lldb breaking compositor XPC and audio
on visionOS, and a visionOS app under Xcode's debugger hanging forever at the
loading splash. That hang was hit again today during S0 mode 2.

## 2026-10-22 -- the fourth mode, read from source

Source read of `illixion/Apparition` (MIT), `utmapp/qemu` (GPL-2.0, QEMU
10.0.12) and StikDebug's `INTEGRATION.md` (MPL-2.0). Full notes in the
working notes.

**The mechanism is far simpler than the blog implies, and it is not a Mach
VM trick.** Apparition makes no Mach VM calls at all. `core/src/jit.rs`,
`Gdb::prepare()` lines 493 to 507, sends one gdb-remote packet per 16 KiB
page:

```rust
format!("M{:x},4:00000000", address + page * PAGE)
```

Four zero bytes into each page. Its own comment: "TXM only lets a page
execute after the debugger has written to it." The **app** allocates its own
region and RX-protects it; the debugger only touches each page; the page then
executes forever, including after the debugger detaches. The single
privileged component is Apple's own `debugserver`, reached through
`com.apple.internal.dt.remote.debugproxy`. Apparition is a plain gdb-remote
client.

The `__TEXT` patching result mentioned in the blog is a separate unproven
experiment (`Lab/TextPatch.c`, no result file published, capped at 4096
bytes). Disregard it.

**A persistent attach is not required for QEMU.** The `brk #0x69` path
prepares the region and then immediately detaches (jit.rs:260 to 264).
Staying attached is a Wine requirement, because Wine prepares a region per
DLL load. This removes the objection recorded above: there is no debugger
sitting on the process while the compositor runs. Whether an attached
debugserver would degrade an immersive app is still unknown and no longer on
the critical path.

**No per-block overhead.** After preparation the JIT writes through its RW
alias at native speed with no traps, so continuous retranslation is a
non-issue provided the code buffer is preallocated and fixed size, which is
QEMU's model. Measured preparation: 305 MiB / 19,520 pages in about 2 s
on-device, 256 MiB in 0.3 s, against 211 s for 320 MiB over LLDB on Wi-Fi.

**UTM's QEMU patch is public, and GPL-2.0, same as xemu.**
`utmapp/qemu`, `tcg/region.c`, `alloc_code_gen_buffer_splitwx_vmremap()`.
Four changes in one function:

1. base anon mapping created `PROT_READ | PROT_EXEC`, not RW, under
   `__builtin_available(iOS 26, visionOS 26, ...)`
2. `mach_vm_remap` and `mprotect(buf_rx, RX)` stay in upstream order
3. `break_prepare_jit_region(buf_rx, size)` (`mov x0/x1; brk #0x69`), gated
   on `is_debugger_attached()` via sysctl `P_TRACED`
4. only then `mprotect(buf_rw, size, PROT_READ | PROT_WRITE)` makes the
   writable alias

The ordering constraint is that **no writable mapping of those pages may
exist at the moment of preparation**. UTM gates on `P_TRACED` rather than
`CS_DEBUGGED`, and skips silently when undebugged rather than risking a stray
`brk`.

### Two things that would have cost days

**xemu disables split-wx in release builds.** `accel/tcg/tcg-all.c:78-82`
sets `splitwx_enabled = -1` only under `CONFIG_DEBUG_TCG`, otherwise `0`. A
release build therefore takes the non-splitwx path, which adds `MAP_JIT` on
Darwin, which S0 proved returns EPERM. Even `-1` falls through to `MAP_JIT`
on failure. **xemu must force split-wx on.** UTM passes `split-wx=on` from
its command line (`UTMQemuConfiguration+Arguments.swift:543-547`); xemu has
no QEMU command line, so this becomes a forced argument into `tcg_init`.

**Cap `tb-size`.** Default is `min(1 GiB, physmem/8)`, so 1 GiB on a 16 GB
Vision Pro, which is 65,536 pages. Every prepared page is written and so
resident dirty: 1 GiB of RSS before a single guest instruction, plus roughly
6.5 s of preparation. 128 to 256 MiB is the right range.

Two things need no work: `x18` is already reserved
(`tcg/aarch64/tcg-target.c.inc:3427`), and guard pages are already confined
to the RW side so the RX range stays contiguous.

### Practical costs

Free personal team is sufficient. `get-task-allow` comes from a free
development profile and `increased-memory-limit` is granted on a free team;
only `extended-virtual-addressing` is paid-only and a few-hundred-MiB buffer
does not need it. But: Apparition itself consumes one of the three app slots,
everything re-signs every 7 days, and **every JIT launch needs a relay**,
because the headset resets connections to its own RemotePairing service. "No
Mac required" is true of the mechanism and false of the session.

Licence is clean. Apparition is a separate MIT app, never linked. UTM's QEMU
fork is GPL-2.0 so its patch can be lifted directly with attribution. Avoid
`StikJIT.xcframework`, which is MPL-2.0 shipped as a binary and would be a
real problem inside a GPL-2.0 app. It is not needed.

### Still unknown

- Whether anyone other than Apparition's author has run JIT on a Vision Pro
  under visionOS 27. No third-party report was found.
- Whether an attached debugserver harms an immersive app. No source says, and
  prepare-and-detach makes it moot for this port.

### Next measurement, and it needs no xemu work at all

Install UTM's official `UTM-visionOS.ipa` (release asset, v5.0.8,
2026-10-17) through Apparition, launch with JIT, and see whether a VM boots.
Same code path, same hardware, somebody else's binary. One evening, and it
either proves the whole approach or ends it without a line being written
here.

## 2026-10-22 -- S0 ANSWERED AGAIN: JIT works on visionOS 27

Measured on the owner's Apple Vision Pro,
RealityDevice17,1, **visionOS 27.2**. Not xemu: UTM's official
`UTM-visionOS.ipa` v5.0.8, somebody else's binary, through the exact code
path a port would use.

Apparition 0.2.0 from this Mac, as the debugger:

```
    0.272s launched suspended, pid 1120
    0.322s no-ack mode: OK
    1.539s attached to pid 1120; faults left to the app: OK
 1374.663s brk #0x69: prepared 128 MiB at 0x129f44000 (8192 pages) in 1.346s
 1374.703s detached: OK
Done (detached): 128 MiB prepared over 0 requests; 0 faults and 0 signals
passed to the app.
```

**QEMU's TCG got an executable code buffer on a Vision Pro.** The earlier S0
result stands unchanged and is not contradicted: an app still cannot make its
own memory executable, `MAP_JIT` is still EPERM, `mprotect` still refuses the
instruction fetch. What works is the app allocating and RX-protecting its own
region and a debugger writing four bytes into each 16 KiB page, after which
those pages execute.

Three predictions from the source read, all confirmed on hardware:

1. **The debugger detaches.** `detached: OK` at 1374.703s, 40 ms after
   preparation. There is no debugger attached while the app runs. Every
   concern recorded here about an attached debugger fighting the
   CompositorServices submission loop, the audio session or the immersive
   space is therefore **moot for this architecture**. That was the objection
   on the critical path and it is gone.
2. **Preparation is a one-time startup cost**, paid per page. 8192 pages,
   128 MiB, 1.346 s. That is about 164 microseconds per MiB, so a 256 MiB
   buffer costs roughly 2.7 s at launch and nothing thereafter.
3. **No per-block overhead.** `0 faults and 0 signals passed to the app`
   across the whole session. After preparation the JIT wrote through its RW
   alias with no traps at all, which is what makes continuous retranslation
   viable.

Note UTM requested **128 MiB**, not QEMU's 1 GiB default, so it caps `tb-size`
itself. The note recorded earlier about capping it for xemu stands and 128 MiB
is now a known-good figure rather than an estimate.

Free personal team was sufficient. `EXTENDED_VIRTUAL_ADDRESSING` was refused
("The selected team does not have a program membership that is eligible"),
`INCREASED_MEMORY_LIMIT` was granted, and JIT worked anyway.

Also learned while getting here:

- Free-account signing rewrites the bundle id. The app installs as
  `com.utmapp.UTM.TEAMID`, with the team id appended, and `apparition
  jit` needs that form or it reports the app is not installed.
- Tailscale on the Mac broke pairing completely. It claimed
  `192.168.0.0/24` on `utun7` and its route beat `en0`, so mDNS discovery
  found the headset while every TCP connection to it timed out. Check with
  `route -n get <headset ip>`; it must say `en0`.
- The headset's pairing port rotates on every probe, so read it from
  `apparition devices` immediately before pairing.

### And it booted

Alpine Linux 3.24 (`alpine-virt-3.24.3-x86_64.iso`, 70 MB) reached a
`localhost login:` prompt inside UTM on the headset, on the Intel ICH9
x86_64 machine type, which is full emulation rather than virtualisation.
OpenRC came up clean, every service green.

So this is not merely that a page was made executable. An **x86_64 kernel
executed instruction after instruction under TCG on a Vision Pro, with no
debugger attached**, all the way to userspace. x86_64-on-arm64 through TCG is
the same class of work `i386-softmmu` does, which is exactly what xemu needs.

**S0 is passed. The blocker that closed this project at 14:00 was gone by
18:00 the same day.**

What remains unproven is not JIT, it is speed. Alpine booting is not
evidence of frame rates. The number still to beat is the one measured on the
Mac earlier today: the emulation thread at 67 percent of one core on an
M5 Max running a 2001 launch title. The headset's M5 is smaller and
thermally tighter.

## 2026-10-24 -- S1a: tree reconstructed from a pin plus a series, and built

Structure changed from the vendoring plan. Measured first:

| | size |
|---|---|
| fork source, no `.git`, no build | 1.34 GB |
| everything the Quake port vendored | 3.0 MB |
| the fork's delta vs upstream | 56 files, +2270, -142 |

Vendoring would have buried a 2,400 line delta inside 1.34 GB of somebody
else's QEMU, in a repo with a remote. So: `tools/setup-tree.sh` reconstructs
`third_party/xemu` from the pinned commit plus `patches/series`.

Verified rather than assumed: applying the series to a clean checkout at the
pin reproduces the fork's source tree exactly. `git diff --cached --shortstat`
reads 56 files, +2270, -142, and a recursive diff against the fork shows no
source differences, only build artifacts it had left behind.

Build via `tools/build-macos.sh`, which encodes the four macOS fixes. Result:
15.8 MB arm64 binary, runs.

```
xemu_version: 0.8.136-53-g478b4f4961
Loaded Vulkan implementation: /opt/homebrew/lib/libMoltenVK.dylib
Selected physical device: Apple M5 Max
VK: no geometry shader support, using fast depth
```

The version string derives from our pin rather than the fork's, which is the
right behaviour: the tree is upstream plus our series.

146 s sample on Fuzion Frenzy sitting in attract mode: max **60.3 fps**,
30 s of the 146 at full speed, median 25.0 because the attract loop is mostly
FMV, which is the same bimodal split diagnosed on 2026-10-22. CPU 1.75 cores,
RSS 571 MiB, against 1.70 cores and 612 MiB measured from the scratch build.
Same binary behaviour.

### A fifth macOS build fix, found here

The rpath de-duplication in `build-macos.sh` was wrong twice before it was
right, and both failures are worth recording because neither is obvious.

First, counting rpaths by grepping `otool -l` output for the path string
finds **nine** matches on a binary with **zero** `LC_RPATH` entries, because
`dylibbundler` writes `@executable_path/../Libraries/arm64/...` as the `name`
of every `LC_LOAD_DYLIB` rather than using `@rpath`. A delete loop keyed on
that count never terminates. Count `LC_RPATH` load commands specifically.

Second, the correct number is **one**, not zero. Stripping them all gives:

```
dyld: Library not loaded: @rpath/libiconv.2.dylib
  Referenced from: .../Contents/Libraries/arm64/libglib-2.0.0.dylib
  Reason: no LC_RPATH's found
```

The bundled dylibs reference each other through `@rpath` even though the
executable's own dependencies do not. The script now deletes down to one and
adds one back if it reaches zero.

## 2026-10-24 -- S1d: the shell is gone, and the frame is black

Built headless. `tools/ui-symbols.sh` set the scope and it kept shrinking:
44,000 lines, then 78 symbols measured against all of `ui/`, then 19 against
the shell, then **4** against only the files actually deleted.

Deleted: `ui/xemu.c` (SDL3 window, GL context, `main`) and `ui/xui/` (50
files, 9,794 lines of ImGui), plus `ui/xemu-thumbnail.cc`. Kept: the 17
stock QEMU files under `ui/`, because the console, input stack and keymaps
are not desktop code and a host needs all of them.

Added `ui/xemu-host.c`: four stubs, a `DisplayChangeListener`, a
`QemuDisplay` registration and a `main` that starts the QEMU thread and
writes one frame out. PNG goes through the vendored **fpng** rather than
libpng, because this build reports "PNG support: NO" and adding libpng
would mean cross-compiling another library for visionOS later.

Also disabled the **GL pgraph backend** (`subdir('gl')`), 6,239 lines
against an API visionOS does not have, which was dragging 113 `epoxy_gl*`
symbols into the link, and flipped `get_default_renderer()` to try Vulkan
before OpenGL. And set `HAVE_IOSURFACE_DISPLAY 0`, because the IOSurface
presentation path still creates a GL context, and presenting is the host's
job now.

### Result

```
[xemu-host] wrote /tmp/xemu-headless.png (640x480)
[xemu-host] 13 frames seen
```

Builds, links, runs, exits 0, writes a correctly sized PNG, 14.1 MB binary.

**Zero GL symbols linked.** Verified case-sensitively: an earlier check said
20 and was wrong, because `grep -i '_gl[A-Z]'` matches `_glslang_*`, which
is the Vulkan shader compiler and is meant to be there.

35 SDL symbols remain, all gamepad and audio (`SDL_CloseGamepad`,
`SDL_ClearAudioStream`). Those belong to S3 and S4. The window path is gone.

### What is not done

**The PNG is black.** The pipeline is correct end to end and the content is
missing. With `HAVE_GL_DISPLAY 0`, `pgraph_vk_get_framebuffer_surface`
(`vk/renderer.c:200-213`) takes the `#else` branch: it calls
`pgraph_vk_wait_for_surface_download(surface)` and returns 0. The frame is
downloaded into guest VRAM and nothing copies it into QEMU's console
surface, which is what the host reads.

Next step, which is small and located:

- `vk/surface.c:458` does
  `memcpy_image(gl_read_buf, mapped_memory_ptr, surface->pitch, ...)`, so
  after the download the pixels are in guest memory at the surface's
  address.
- `nv2a.c:92`, `nv_dma_map()`, returns `d->vram_ptr + dma.address`, which is
  how to get a CPU pointer to it.
- So the non-GL branch needs to publish address, width, height and pitch,
  and the host wraps that with `qemu_create_displaysurface_from()` and
  `dpy_gfx_replace_surface()`. That is the standard QEMU software scanout
  pattern.

### S1 done: a real frame, headless

The black PNG was exactly what the devlog predicted: the frame reached guest
VRAM and nothing published a pointer to it.

Three edits closed it. `nv2a.h` gains `NV2ACpuFramebuffer` and a
set/get pair. `vk/renderer.c`'s readback branch, after
`pgraph_vk_wait_for_surface_download()`, publishes
`d->vram_ptr + surface->vram_addr` with the surface's width, height and
pitch; it still returns 0, which still correctly means "no GL texture". And
the host calls `nv2a_get_framebuffer_surface()` to trigger the scan-out,
then reads the published pointer.

Deliberately **not** routed through a QEMU `DisplaySurface`. The host wants
a CPU pointer to pixels, which is what it gets, and on visionOS that becomes
a Metal texture upload rather than a console surface. Also deliberately not
called under the BQL: it takes the pfifo lock and waits on the QEMU thread,
which is how the old shell called it from its own thread.

```
[xemu-host] wrote /tmp/xemu-headless.png (640x480)
[xemu-host] 13 frames seen
```

469,810 bytes against 6,863 for the black one. Verified visually: a real
gameplay frame, correct colours, correct geometry.

**S1's done-condition is met and exceeded.** It asked for the dashboard;
this is a commercial game mid-frame, rendered by the NV2A through Vulkan on
MoltenVK, with no window, no SDL window path and zero GL symbols linked.

The PNG is not committed. It is a frame of a commercial game and game
content stays out of the repo.

### What S1 did not do, on purpose

The IOSurface seam. `HAVE_IOSURFACE_DISPLAY` is 0 because that path creates
a GL context to present through, and presenting is the host's job now. S3
revisits it, since IOSurface is the zero-copy route to an `MTLTexture` and
the CPU readback used here is a copy per frame.

Still SDL-linked: 35 symbols, all gamepad and audio. S3 and S4.

## 2026-10-24 -- S2 opened: the cross-compile shopping list

Before porting anything, measured what the headless binary actually needs.
S1 shortened this list considerably by deleting the window.

Apple frameworks, free on visionOS: CoreFoundation, Foundation, IOKit,
IOSurface, Security, libSystem, libc++.

Third-party libraries, by how much they are actually used:

| library | undefined symbols | verdict |
|---|---|---|
| glib-2.0 | **275** | unavoidable, QEMU's backbone |
| libusb-1.0 | 40 | USB passthrough, not needed, see below |
| SDL3 | 35 | APU audio and gamepad, S3 and S4 |
| glslang | 20 | Vulkan shader compilation, needed |
| slirp | 18 | user networking, small and worth keeping |
| libpcap | 6 | a network backend xemu added |
| libsamplerate | 5 | APU resampling, S4 |
| zlib | 0 direct | needed transitively |

`OpenGL` is still in the link list with zero GL symbols used, because
`meson.build:1887` adds `-framework OpenGL` unconditionally on darwin. That
framework does not exist on visionOS, so it has to go in S2 proper.

### What can be turned off, and what only looks like it can

`libusb`, `slirp` and `sdl` are meson feature options. The other two,
`libpcap` (`meson.build:2455`) and `libsamplerate` (`:2458`), are hardcoded
`required: true` and need a patch.

But a flag is not enough for libusb. xemu writes:

```
libusb = dependency('libusb-1.0', required: get_option('libusb').enabled(), ...)
```

so `-Dlibusb=disabled` makes it **optional rather than unused**: it is still
found and still linked. Verified by building with it and seeing
`libusb-1.0.0.dylib` still in `otool -L`. Excluding it needs a
`get_option('libusb').disabled()` guard, which is an S2 patch.

`-Dslirp=disabled` fails to compile: `ui/xemu-net.c:38` includes
`libslirp.h` unconditionally. Keeping slirp anyway, since it is a small
self-contained C library and guest networking is wanted eventually.

`tools/build-macos.sh` now forwards `XEMU_EXTRA_OPTS` to configure.

Regression check after all of this: still builds, still runs headless, still
writes a 640x480 frame, 467,563 bytes.

### So the realistic xros cross-compile set

**glib, glslang, zlib, slirp** to port, plus MoltenVK to ship. SDL3,
libsamplerate, libpcap and libusb all go away with the audio, networking and
USB work that S3 and S4 do anyway. That is four libraries, against the
fifteen the original survey feared.

### OpenGL unlinked entirely

`-Dopengl=disabled` did nothing before, because three separate places
ignored it:

1. `meson.build:1885`, `epoxy = dependency('epoxy', required: true)`,
   unconditional.
2. `meson.build:1888`, the opengl block ran on `have_system` regardless of
   the option, and on darwin added `-framework OpenGL`.
3. `hw/xbox/nv2a/pgraph/vk/meson.build:25` added `OpenGL` as an
   appleframeworks module for the IOSurface presentation path.

And one compile error behind them: `vk/renderer.h:308-320` declares
`GLuint` interop fields unconditionally, although only the GL display path
uses them. Now guarded by `HAVE_GL_DISPLAY`.

With all four fixed, `-Dopengl=disabled` produces a binary that links **no
GL at all**, and whose only Apple frameworks are:

```
CoreFoundation  IOKit  Security  Foundation
```

All four exist on visionOS. Still renders: 640x480, 471,341 bytes.

This is a precondition for S2 rather than a nicety. A visionOS link would
have failed on `-framework OpenGL`, which does not exist there, and the
failure would have pointed at the linker rather than at the three places in
meson that caused it.

## 2026-10-24 -- S2: the tree compiles for arm64-apple-xros

**2,590 of 2,606 objects.** Work in `_scratch/xros-sysroot/`, full notes in
its `FINDINGS.md`.

### Three of the four libraries came free

**UTM publishes a prebuilt visionOS sysroot.** `Sysroot-visionos-arm64` is a
GitHub Actions artifact built on every push to UTM's `main`, public repo, no
special permissions:

```sh
gh api "repos/utmapp/UTM/actions/artifacts?per_page=100" \
  --jq '.artifacts[] | select(.name=="Sysroot-visionos-arm64" and .expired==false)
        | "\(.id)\t\(.created_at)\t\(.size_in_bytes)"'
gh api repos/utmapp/UTM/actions/artifacts/<ID>/zip > s.zip
```

Used `12276716353` (2026-10-20, 341 MB). Contains glib 2.83.0, slirp 4.9.1,
MoltenVK.framework, pixman, libffi, intl, iconv. Every binary is
`LC_BUILD_VERSION platform VISIONOS minos 1.0 sdk 27.0`. **Artifacts expire
after 90 days**, so the zips are kept locally.

**zlib is not needed at all**: the XROS 27.0 SDK ships `usr/lib/libz.tbd`.

So only **glslang** had to be built. Static, revision `e1b562a8` =
`vulkan-sdk-1.4.363.0` = glslang 16.6.0, which is exactly what
`subprojects/glslang.wrap` pins.

### glib needs zero patches, and that is the finding

UTM's `patches/glib-2.69.0.patch` looks like the answer and is **dead
code**: the build applies `${NAME}.patch` where NAME comes from the tarball,
and `patches/sources` pins glib 2.83.0, so it looks for a file that does not
exist. glib 2.83.0 cross-compiles for arm64-apple-xros unpatched. The
fork/exec and `/proc` assumptions were fixed upstream.

libslirp is the opposite: its patch does apply, one hunk widening a meson
branch so the iOS family also links `-lresolv`. That single hunk is the only
reason UTM's cross file says `system = 'ios'`.

### Two traps worth more than the libraries

**Meson merges cross files left to right, but a later `[built-in options]`
section REPLACES the earlier one rather than appending.** QEMU's configure
writes its own `config-meson.cross` and bakes `--extra-cflags` into
`c_args`. Layering a full cross file on top silently discarded every one of
those defines, including `-DXBOX=1`. The symptom was not a configure error:
it was 2,854 compile errors several minutes into the build from a `-D` that
had vanished. Hence two files, one standalone for libraries and one
properties-only for layering.

**`system` must be `'darwin'`, not `'ios'`.** UTM uses `ios` for its
libraries because slirp needs it, but QEMU has many `host_os == 'darwin'`
branches that `ios` silently loses. UTM itself builds QEMU through
configure, which emits `darwin`.

Also `has_function_dup3 = false`. On XROS27.0 targeting 26.0, `dup3` is
weak-imported and NULL at runtime, but meson's own-prototype probe links
clean, so `config-host.h` would get `CONFIG_DUP3` wrongly. Verified both
ways rather than copied.

### Fixed here, in this commit

- **imgui and implot** were still `required: true` subprojects with zero
  consumers after S1 deleted `ui/xui/`. imgui carried `'sdl3=enabled'`,
  pulling in the SDL3 CMake subproject, which was the first thing to break
  the cross build. Five statements removed.
- **`-framework Cocoa`** (`ui/meson.build:48`), a second macOS-only
  framework that `-Dopengl=disabled` did not cover, with
  `xemu-os-utils-macos.m` being AppKit for a menu that no longer exists.
  Only `ui/xemu.c` used it and that is gone.
- **`block/file-posix.c`** needed `#include <sys/mount.h>` inside its
  existing `__APPLE__` guard. It arrives transitively on macOS and not on
  visionOS.

Framework list is now **CoreFoundation, IOKit, Security**. Foundation left
with Cocoa. Still renders headless, 640x480.

### Still open

1. **`configure` has no `--extra-cross-file`.** About six lines, applied
   after `config-meson.cross` so it wins. Proven on a copy; the real tree
   needs the patch.
2. **`pthread_jit_write_protect_np`** is guarded by a bare `#ifdef __APPLE__`
   at `include/qemu/osdep.h:860`, and the SDK marks it unavailable on
   visionOS, so the build dies in 2,854 places. This is the compile-time
   counterpart of S0's hardware result.
3. **UTM also publishes `Sysroot-visionos-tci-arm64`**, tci being the
   threaded code interpreter. Worth a look, though S0 settled that JIT works.
4. **MoltenVK's dlopen path list** (`vk/instance.c:164-178`) has five
   entries and none is the visionOS one. An iOS-family bundle puts the
   executable at the root, so it is `@executable_path/Frameworks/...`, and
   the file is `MoltenVK.framework/MoltenVK`, not `libMoltenVK.dylib`. The
   `volkInitialize()` fallback cannot work either, since visionOS has no
   system library path, so a dlopen miss has to be fatal.
5. **Vulkan headers are a host dependency hiding in the cross build**: the
   tree hardcodes `/opt/homebrew/opt/vulkan-headers/include`. Works because
   headers are arch-independent. Should be vendored.
6. **The final link was never attempted.** 2,590 objects compiled is not a
   linked binary, and a link surfaces gaps no object file shows.
7. The 16 failing objects are all already-scoped S3 and S4 work: 15 want
   `SDL3/SDL.h`, 1 wants `pcap/pcap.h`.

### What the app will embed

Flat in `App.app/Frameworks/`: `libglib-2.0.0`, `libgobject-2.0.0`,
`libgmodule-2.0.0`, `libgthread-2.0.0`, `libslirp.0`, `libpixman-1.0`,
`libintl.8`, `libiconv.2`, `libffi.8`, plus `MoltenVK.framework`. Bare
dylibs rather than the `.framework` copies the artifact also ships, because
the two naming schemes are incompatible and pkg-config describes the dylibs.
Only libSystem, libresolv, CoreFoundation and CoreServices come from the OS.

## 2026-10-24 -- IT LINKS. qemu-system-i386 for arm64-apple-xros

```
size:     18.8 MB
arch:     arm64
platform: VISIONOS   minos 26.0   sdk 27.0
```

An original Xbox emulator, built for Apple Vision Pro.

What it loads at runtime:

```
UIKit  Metal  GameController  AVFAudio  AudioToolbox  CoreHaptics
CoreMotion  CoreVideo  CoreGraphics  QuartzCore  CoreFoundation
Foundation  Security
libglib-2.0.0  libslirp.0  libusb-1.0.0  libz  libc++  libobjc  libSystem
```

**Zero GL symbols. Zero `pthread_jit` symbols.** Three dylibs to bundle;
everything else comes from the OS. The Apple frameworks arrive through SDL3
and are exactly the ones a headset app wants.

### The four things between compiling and linking

Each was a single clean error, found by building rather than reasoning.

**1. SDL3, 15 objects.** Not in UTM's sysroot, because UTM has its own UI.
Built it: SDL3 supports visionOS properly through its UIKit video backend,
static, pinned to the same revision `fa2c02bb` the tree's wrap uses. First
try. It is what pulls in GameController, AVFAudio and CoreHaptics, which are
the frameworks S3 and S4 want anyway.

**2. libsamplerate, 5 objects.** Small portable C, cross-compiled unchanged.

**3. `pkg_config_libdir` in the cross file overrides the environment.**
Setting `PKG_CONFIG_LIBDIR` in the shell had no effect on meson at all, and
`samplerate` stayed "found: NO" while `pkg-config --cflags samplerate`
worked perfectly in the same shell. The cross file's property wins. Both new
libraries had to be added there.

**4. The Rust DSP recompiler.** `dsp56300-emu-ffi` is a Rust crate
recompiling the MCPX's DSP56300, and its build targets the host triple, so
the link failed with `built for 'macOS'`. Not worth porting: it is a second
JIT in a project where the first one already costs a debugger attach, and a
C interpreter for the same DSP already sits beside it in
`apu/dsp/interp/`, with `dsp.c:122` switching between them at runtime. Now
a feature option, `-Ddsp_jit=disabled`, with the interpreter as the only
engine when it is off.

Then exactly one undefined symbol: `net_init_pcap`, named in net.c's client
table although `net/pcap.c` is no longer compiled. Guarded on `CONFIG_PCAP`.

### Also fixed on the way

**`pthread_jit_write_protect_np` was guarded by a bare `#ifdef __APPLE__`**
(`include/qemu/osdep.h:860`), which failed in 2,854 places on visionOS where
the SDK marks it unavailable. Narrowed to `TARGET_OS_OSX`, so the iOS family
takes the existing no-op branch.

That is correct rather than a workaround. On visionOS the app never toggles
W^X, because it cannot: `MAP_JIT` returns EPERM and `mprotect` to R+X is
refused at the first instruction fetch, both measured on device in S0. The
pages are made executable once, before use, by a debugger writing to each of
them. There is nothing to toggle per translation block.

**`configure` gained `--extra-cross-file`**, applied last so it wins.

**`libpcap` and `libsamplerate` were `required: true`** and stopped a
visionOS configure dead. Now optional.

Build recipe and scripts: `tools/xros/`, with its README. The 1.5 GB sysroot
stays in `_scratch` because it is not ours.

### What this is not

It is a binary, not an app. There is no bundle, no `main` for UIKit, no
MoltenVK shipped, and nothing has run on the headset. `vk/instance.c:164-178`
still has five dlopen paths for MoltenVK and none is the visionOS one.

macOS still builds and still renders headless, unchanged.

## 2026-10-24 -- packaged as a visionOS app bundle

**MoltenVK loader fixed for the iOS family.** `vk/instance.c` had five
dlopen paths and none worked on visionOS: an iOS-family bundle puts the
executable at the root, so `Frameworks` is a sibling rather than one level
up, and MoltenVK ships as a framework whose binary carries no extension.
Now `@executable_path/Frameworks/MoltenVK.framework/MoltenVK` first, then
`@rpath`.

The `volkInitialize()` fallback is also removed there. It looks for a Vulkan
loader on the system library path, and an iOS-family OS has neither, so it
could only fail later and less clearly. A dlopen miss is now fatal with a
message naming the path it wanted.

**The frame output no longer needs an environment variable.** Those do not
reach an app launched the ordinary way, so on device it defaults to
`$HOME/Documents/frame.png`, which `devicectl device copy from` can fetch
and Files can show.

**`tools/xros/make-app.sh`** builds `XemuHost.app`, 31 MB, 11 frameworks,
and an 11 MB IPA.

Deliberately **not** a UIKit app. An iOS-family bundle needs an Info.plist
and an executable, and nothing requires that executable to call
`UIApplicationMain`. This one runs the emulator headless, writes a frame
into its own Documents and exits, which answers the only question worth
asking right now: does any of this run on the headset. The real app, with a
compositor and a window, is S3.

It bundles the ten dylibs plus `MoltenVK.framework`, rewrites every
inter-library reference to `@rpath` and adds
`@executable_path/Frameworks` as an rpath, because an iOS-family layout is
not the macOS one the build produced.

Open: install and run it. All three free-profile slots are in use
(QuakeAVP, UTM, VISR), so one has to go first.

## 2026-10-25 -- on device: installed, and it will not run headless

Installed and signed **without Apple's servers**, which is worth keeping.

`gsa.apple.com/grandslam` returned 503 five times across two stages of
Apple's flow, so `apparition install` could not sign at all. It does not
have to: issuing a provisioning profile needs Apple online, **using one does
not**. There were ten valid xrOS profiles already on disk, and
`local.jitprobe.s0` was free because S0 is answered and that app is
uninstalled.

`tools/xros/sign-install.sh` finds the profile for a bundle id, embeds it,
extracts the profile's own entitlements rather than inventing them, signs
nested code outwards, and installs with `devicectl`. Confirmed on the
device:

```
Identifier=local.jitprobe.s0
TeamIdentifier=TEAMID
  [Key] get-task-allow
```

`get-task-allow` is intact, which is what the JIT attach needs later.

Reusing an App ID also sidesteps a quota worth knowing about: a free account
gets **ten App IDs per week**, and this project had used all ten.

### A bug of mine, found and fixed

The first bundle died instantly. The dylib rewrite in `make-app.sh` matched
`*/lib/lib*.dylib` and rewrote **system** libraries to `@rpath` as well,
because UTM's sysroot ships its own copies of libSystem, libz, libc++ and
libobjc, so the link resolved there and the pattern matched:

```
@rpath/libSystem.B.dylib   @rpath/libz.1.dylib
@rpath/libc++.1.dylib      @rpath/libobjc.A.dylib
```

None of those are in `Frameworks`, because they belong to the OS, so dyld
gives up before `main()` with no crash report at all. Now the rule is:
bundled means `@rpath`, everything else goes back to `/usr/lib`. Also
removed an absolute rpath into the build-time sysroot that the link leaves
behind.

### And the finding that actually matters

**It still dies immediately.** Launch returns
`com.apple.dt.CoreDeviceError error 3`, "The connection was invalidated",
within a second, and the app container's `Documents` is untouched.

So the premise was wrong. A bundle with an `Info.plist` and an executable is
enough to *install* on visionOS, and it is not enough to *run*. The system
expects the process to check in through `UIApplicationMain`, and a process
that never does is gone before it reaches any code of ours.

That was worth testing: it cost one evening against the chance of skipping
an entire app shell, and the answer is unambiguous.

**So S3 is not optional scaffolding, it is the next step.** The binary needs
`UIApplicationMain` on the main thread with the emulator on a worker, which
is the same shape `ui/xemu.c` already had on macOS: a thread for
`qemu_main`, the platform's event loop on the main thread. `xemu-host.c` is
written to suit that, since it already separates `qemu_main_thread()` from
the loop in `main()`.

## 2026-10-26 -- the emulator runs on the headset, and prepares its own JIT

Six things went right in one session, each one verified on device.

**1. A UIKit shell, because a bare executable will not run.**
`ui/xemu-host-ios.m` provides `main()` on the iOS family, calls
`UIApplicationMain`, and runs the emulator on a worker thread.
`xemu-host.c`'s `main` became `xemu_host_run` there.

**2. A scene manifest, because visionOS is scene based.** With
`UIApplicationMain` but no `UIApplicationSceneManifest`, the app starts and
`didFinishLaunching` is **never called**. From the log that looks exactly
like a hang after handing off to UIKit. The manifest also needs the
delegate class it names to exist, so there is a minimal
`XemuHostSceneDelegate` that puts a black window up.

**3. A log channel.** There is no console on a headset: a detached launch
gives nothing and an early death leaves no crash report. `main` now
redirects stderr to `Documents/host.log`, line buffered, before anything
else. Every finding below came from that file. It was worth building first.

**4. MoltenVK loads from the bundle**, at the path fixed earlier:

```
Loaded Vulkan implementation: @executable_path/Frameworks/MoltenVK.framework/MoltenVK
MoltenVK version 1.4.2, supporting Vulkan version 1.4.334
Created VkDevice to run on GPU Apple M5 GPU
  VK_KHR_portability_subset  VK_EXT_memory_budget  VK_EXT_metal_objects
```

**5. The accel defaults, exactly as predicted on 2026-10-22.** The first
device run died with `allocate 1073741824 bytes for jit buffer: Operation
not permitted`: QEMU's 1 GiB `tb-size` default, through the non-splitwx
path, asking for `MAP_JIT`, which visionOS refuses. Forcing
`-accel tcg,split-wx=on,tb-size=128` on the iOS family fixes it. That note
was written four days before it bit, and it still cost a run to recognise.

**6. The JIT request, from our own binary.**

`tcg/region.c`'s `alloc_code_gen_buffer_splitwx_vmremap()` now allocates
the base mapping **R+X rather than R+W**, remaps, asks a debugger to
prepare the executable view with `brk #0x69`, and only then creates the
writable alias. The ordering is the whole point: a debugger can only
prepare pages that have no writable mapping at that moment.

```
1.440s attached to pid 2615; faults left to the app: OK
2.412s brk #0x69: prepared 128 MiB at 0x117c00000 (8192 pages) in 0.651s
2.447s detached: OK
```

128 MiB is our own `tb-size`. The debugger detaches 35 ms after preparing,
so nothing is attached while the emulator runs.

Gated on `P_TRACED` via sysctl. Undebugged it refuses with a message naming
Apparition rather than dying at the first translated block.

### Where it stops

The process ends shortly after `VkDevice` creation, with no error. Two
things in the log before that, both still open:

```
mcpx_apu_monitor_init failed: SDL_Init failed: Application didn't
  initialize properly, did you include SDL_main.h in the file containing
  your main() function?
[xemu] error: Configured renderer not available
```

The first is SDL3 wanting its own `SDL_main` integration, which this app
does not use because UIKit owns `main`. It is a warning and the APU
continues without audio. The second fires before Vulkan registers and is
then contradicted by Vulkan loading successfully a few lines later, so the
renderer selection order looks wrong on this path.

Neither is obviously fatal, and the death has no message, so the next step
is narrowing it rather than guessing.

### What exists now that did not this morning

A complete iteration loop with **no dependency on Apple's servers**: build,
bundle, sign with a profile already on disk, install with `devicectl`,
launch through Apparition, read `host.log`. That loop is what makes the
remaining debugging ordinary.

### Renderer default, fixed but not the cause

`[xemu] error: Configured renderer not available` was real: `config_spec.yml`
defaults `display.renderer` to **OPENGL**, and there is no GL backend in this
build, so a fresh install on device configures a renderer that does not
exist. On the Mac this never showed because `xemu.toml` named VULKAN
explicitly. Now forced to Vulkan on the iOS family alongside `show_welcome`.

The error is gone and the process still ends in the same place, two lines
after `Created VkDevice`, with no message and no frame. So that was a real
bug and not this one.

Narrowed: it dies inside NV2A's Vulkan init, after device creation and
before `gpuprops` reports the geometry shader verdict. Notably the earlier
run **without** JIT prepared got further, printing "no geometry shader
support, using fast depth" and "Switched to default renderer: Vulkan". That
difference is the next thing to explain.

Open: the efficient next step is a crash handler, not another guess.
The app has no console and leaves no crash report, so a `SIGSEGV`/`SIGBUS`/
`SIGILL` handler writing a backtrace into `host.log` would turn "dies
silently" into "dies at this frame". That is the same move the log file
itself was, and it paid for itself immediately.

### It is killed, not crashing

The crash handler is installed for SIGSEGV, SIGBUS, SIGILL, SIGABRT,
SIGTRAP, SIGFPE and SIGSYS, writes a backtrace into `host.log`, and there is
an `atexit` logging a normal exit. **Neither fires.** The process simply
stops.

That rules out a great deal. It is not a fault in our code, not an abort,
not an assert, and not a clean exit. An uncatchable kill is left: SIGKILL,
from jetsam or a watchdog.

Memory is implicated but is not the whole story:

| tb-size | reached |
|---|---|
| 128 MiB | 199 lines, stops after `Created VkDevice` |
| 32 MiB | 200 lines, reaches `VK: no geometry shader support, using fast depth` |

One line further for a quarter of the buffer, which is a real signal. But
adding `com.apple.developer.kernel.increased-memory-limit` to the signature
(accepted, verified present with `codesign -d --entitlements`) did **not**
get further than 32 MiB alone did.

So: memory pressure matters, and something else is also wrong. The next
candidate is the watchdog rather than jetsam. This app creates a scene and
a black window and then never presents anything, and visionOS may not
tolerate a scene that renders nothing while a worker thread does heavy
work.

That is testable: have the scene delegate present something every frame,
even a solid colour through CADisplayLink, and see whether the process
survives longer.

Current furthest point: NV2A's Vulkan init, after the geometry shader
verdict, before "Switched to default renderer".

### The main run loop stops

A `CADisplayLink` was added to the scene delegate, changing the window's
background colour every frame and logging its first three ticks.

**It never fires. Not once.**

That is the clearest finding of the session, because the process plainly
lives for some time afterwards: `scene connected` is logged, and then
MoltenVK creates a `VkDevice` and NV2A reaches its geometry shader verdict,
which is hundreds of milliseconds of work. A display link at 90 Hz should
have ticked dozens of times in that window.

So the sequence is: UIKit starts, delivers `didFinishLaunching` and
`scene willConnectToSession` from the main run loop, and then **the main
run loop stops being serviced**, while worker threads carry on.

That fits the kill exactly. An app whose main thread stops responding is
what the watchdog exists to terminate, and it terminates with SIGKILL,
which is why no handler fires and no backtrace is written.

It also explains why the memory experiments moved the needle only slightly:
they changed how long the worker threads took to get somewhere, not the
underlying fault.

So the question is no longer "why is it killed" but **"what blocks the main
thread"**. Candidates, none yet tested:

- `xemu_host_run` runs on a worker and creates a second thread for
  `qemu_main`, so three threads exist. QEMU's BQL and its AIO context both
  have main-thread expectations on Darwin that this arrangement may be
  violating.
- `qemu_init()` on a non-main thread may install or expect a run loop of
  its own. Upstream's `system/main.c` uses `os_darwin_cfrunloop_main` on
  Darwin, and xemu disables that file entirely under `-DXBOX=1`.
- Something in the Vulkan or Metal path may be doing main-thread work
  synchronously from a worker.

Recorded as the next thing to investigate, and it is a design question
about thread ownership rather than a patch.

## 2026-10-26 -- bisected: it dies inside qemu_init()

A staged guard in the app delegate, so the fault could be halved rather
than guessed at. `xemu_host_stage`: 0 starts no emulator, 1 runs
`qemu_init()` and stops, 3 is the real thing.

| stage | display link ticks | process |
|---|---|---|
| 0, no emulator | 18 | **alive indefinitely** |
| 1a, settings and config only | 16 | **alive indefinitely** |
| 1b, `qemu_init()` | **0** | **dead** |

`qemu_init returned` is never printed. So the process dies **inside
`qemu_init()`**, and the main run loop stops the moment it is entered.

That settles several things at once. UIKit, the scene manifest, the window
and the display link are all correct. The settings and config work,
including the bundle media paths. The emulator is the cause, and the cause
is in QEMU's initialisation rather than in the NV2A or Vulkan code that the
logs happened to end near, because those lines come from a different thread
and only looked like the end.

### A process mistake worth recording

Three runs before this were read as results and were not. Adding
`com.apple.developer.kernel.increased-memory-limit` to the signature made
installd reject it:

```
Unable to Install "XemuHost"
Failed to verify code signature: 0xe8008015
(A valid provisioning profile for this executable was not found.)
```

A profile authorises a fixed set of entitlements and the reused one does
not carry that. Every install afterwards failed, the device kept running
the previous build, and because install output was being sent to
`/dev/null` to keep things terse, it looked exactly like code changes
having no effect. The container and bundle UUIDs being identical across
"runs" is what gave it away.

Two rules from it: never silence an install, and check the container UUID
changed before believing a device result. The conclusion drawn from those
runs, that the memory entitlement did not help, is withdrawn: it was never
tested.

### Next

Bisect inside `qemu_init()`. The likely suspects are the things QEMU does
to process-wide state on a thread that is not the main one: signal handling
setup, the RCU thread, and main loop initialisation. On macOS `ui/xemu.c`
also ran QEMU on a worker and survived, so the difference is what visionOS
does about it rather than the arrangement being novel.

## 2026-10-26 -- corrected, and narrowed to first execution

**Several earlier conclusions were drawn from stale installs and are
withdrawn.** Once the install stopped being silenced, with the correct
build verifiably on the device:

- the display link **does** tick with the emulator running. "Zero ticks"
  was a build that never reached the headset. The main run loop is fine.
- `atexit` and the crash handler **do** work, proven by a run that exited
  cleanly through our own "JIT needs a debugger attached" path when
  launched with `devicectl` instead of Apparition.

So the main thread was never the problem, and neither was UIKit.

### Memory is a real constraint, measured properly

| `tb-size` | result |
|---|---|
| 128 MiB | dies **inside** `qemu_init()` |
| 16 MiB | **`qemu_init returned`**, then dies entering `qemu_main_loop()` |

That is decisive. The code buffer is prepared page by page by the debugger
and every prepared page is written, so it is resident dirty before a single
guest instruction. At 128 MiB that is enough to get the process killed
during init. The note written on 2026-10-22 said exactly this and still
understated it: 128 MiB is not a safe figure here, UTM's number
notwithstanding.

Getting the headroom properly needs
`com.apple.developer.kernel.increased-memory-limit`, and that needs a
provisioning profile carrying it, which needs Apple's servers. Adding it to
a signature without the profile makes installd reject the app outright.

### Where it dies now

`[host] qemu_init returned, stage 3` is the last line. The process ends
entering `qemu_main_loop()`, which is where the guest first executes
translated code.

The suspect is the split-wx ordering in `alloc_code_gen_buffer_splitwx_vmremap()`.
The debugger prepares `buf_rx` while nothing writable maps those pages, and
then we `mprotect(buf_rw, PROT_READ | PROT_WRITE)`. But `buf_rw` and
`buf_rx` are the **same physical pages** via `mach_vm_remap` with copy
false, so creating the writable alias may revoke exactly the executability
that was just granted. The constraint may not be only "no writable mapping
at preparation time" but "no writable mapping ever".

Testable: prepare, then do not create the writable alias, and see whether
execution begins (it will fault later when TCG writes, but it would prove
the ordering theory).

## 2026-10-26 -- IT RUNS. Guest code executing on the headset

```
[tcg] jit region prepared last
[host] qemu_init returned, stage 3
[xemu-host] no framebuffer published
[host] scene tick 12000
```

`qemu_main_loop()` ran. The app stayed alive through 12,000 display frames,
more than two minutes, having executed translated guest code on a Vision
Pro.

### The ordering was the whole thing

UTM's arrangement, which this followed for days, is: allocate the base
**R+X**, remap, prepare the executable view while no writable mapping of
those pages exists, and only then `mprotect` the writable alias. It does
not work here. Measured, in this order:

| arrangement | result |
|---|---|
| base R+X, prepare, then create RW alias (`brk #0x69`, auto detach) | dies at first translated block |
| same but JIT26 (`brk #0xf00d`), alias created inside the session, explicit detach | dies identically |
| same but **skip the RW alias entirely** | **survives 9,300 frames** |
| base **R+W** (upstream order), both mappings in place, **prepare last** | **runs** |

The third row is what identified it: with no writable alias the process
lived, so the alias was the killer. The grant does not survive a later
protection change on those pages, whether that change happens inside the
debug session or after it. Preparing once nothing further will change is
what works.

So the rule is not "no writable mapping at preparation time". It is
**prepare last**.

### Where it is now

`no framebuffer published` after the 10 second shot timer. The guest ran;
NV2A never scanned out. There is a BIOS and an MCPX ROM in the bundle and
**no hard disk image**, so the machine has nothing to boot into, and ten
seconds may also simply be too early.

Also still true: `tb-size` is 16 MiB, which is tiny, and the increased
memory limit entitlement is still unavailable without a profile from
Apple's servers.

## 2026-10-26 -- the hard disk, and a backtrace that names the culprit

**The bundle is read-only.** Pointing `hdd_path` at the bundled qcow2 fails
before the machine starts:

```
Could not open '.../XemuHost.app/media/xbox_hdd.qcow2': Operation not permitted
```

QEMU opens a disk read-write. The image is now copied into the container
once, which is also the shape the real app takes, with the user supplying
media into the container rather than it riding in the bundle.

**And the copy has to stream.** The first version used
`g_file_get_contents()`, which reads the whole file into memory: a 1.9 GB
peak on a device with a jetsam limit. It completed and the process died a
few hundred milliseconds later inside Vulkan init. Chunked at 4 MiB it is
fine.

### The crash handler paid for itself

```
[host] ==== FATAL: signal 6 (Abort trap: 6) ====
0  crash_handler
3  abort
5  pgraph_method.cold.1
6  nv2a_get_framebuffer_surface
7  xemu_host_run + 1284
8  emulator_thread
```

An assert inside pgraph, reached from **our own framebuffer poll**. The
emulator is not what aborts: it ran for 12,000 display frames before
polling was added.

`nv2a_get_framebuffer_surface()` takes the pfifo lock and waits on the QEMU
thread. On macOS the desktop shell called it from the thread that owned the
window, every frame, with the machine already running. Calling it from a
worker on a timer, possibly before the machine is drawing, is not the same
thing and pgraph asserts.

### Next

Stop polling. A `DisplayChangeListener` is already registered in
`xemu-host.c`, and `dpy_gfx_update` is called by QEMU on its own thread
when the guest actually draws. Taking the frame there is both the correct
QEMU idiom and free of the lock dance that is aborting.

## 2026-10-26 -- stable, and memory-bound

Taking the frame in `dpy_gfx_update` instead of polling fixed the abort.
QEMU calls that from the thread that owns the machine, at a point where
asking the NV2A to scan out is legal. **No more crashes: the app ran 110
seconds, stable, alive.**

But: **1 guest frame**, and only the first. The machine runs and does not
draw.

### The memory ceiling is the wall

| `tb-size` | result |
|---|---|
| 128 MiB | dies inside `qemu_init()` |
| 64 MiB | prepares, then dies before drawing |
| 16 MiB | **stable indefinitely**, 1 guest frame, no progress |

So the ceiling is between 16 and 64 MiB, and 16 is too starved for the Xbox
BIOS to get anywhere. Every prepared page is written by the debugger and
therefore resident dirty before a single guest instruction, on top of guest
RAM, MoltenVK and glib.

**This is what `com.apple.developer.kernel.increased-memory-limit` is for,
and it cannot be faked.** Adding it to a signature without a provisioning
profile that carries it makes installd reject the app outright, which was
measured. Getting a profile that carries it means signing through an Apple
ID, which means Apple's servers.

Apparition does exactly that, and its own source reports the capability as
granted on a free team. The blocker all of 2026-10-25 was
`gsa.apple.com/grandslam` returning 503 across two stages of the flow, five
times.

### So the next step is not code

```sh
./apparition install .../XemuHost.ipa --apple-id <id>
```

When Apple's sign-in is up. That yields a profile with the increased memory
limit, after which `tb-size` can go back to 128 MiB and the BIOS has room
to run.

Everything else is done: JIT prepared and executing, MoltenVK on the M5
GPU, BIOS and hard disk loading, the app stable, frames taken the correct
way.

### 32 MiB is stable, and memory was not the drawing problem

| `tb-size` | stable? | guest frames |
|---|---|---|
| 128 MiB | no, dies in `qemu_init()` | n/a |
| 64 MiB | no, dies before drawing | 0 |
| **32 MiB** | **yes, 130 s and counting** | **1** |
| 16 MiB | yes | 1 |

So 32 MiB fits, and the machine still produces exactly one frame. Starving
the translation cache was not why it does not draw. The earlier conclusion
that the memory entitlement was the blocker is therefore **too strong**: it
is a real constraint and it is not the thing standing between here and a
boot screen.

No errors in the log, no abort, the app alive and the display link ticking.
`dpy_refresh` fired once and QEMU then had nothing new to report, which is
what happens when the guest is not drawing rather than when the display
path is broken.

So the open question is narrow and concrete: **is the guest CPU advancing
at all?** Three threads exist and translated code demonstrably executes,
since `qemu_main_loop()` runs and nothing aborts, but the machine behaves
like a CPU that is stuck very early.

Next instrument: QEMU's own tracing rather than more guessing. `-d exec` or
a periodic log of the guest PC will say in one run whether the processor is
moving, and that distinguishes "slow" from "stuck" from "halted", which no
amount of reasoning from the outside will.

### Instrumentation added, not yet read

Two signals are now built in and have **not produced a reading**:

- the periodic host line reports `runstate_get()`, the cheapest honest
  answer to whether the machine is executing at all
- `-d guest_errors,unimp` is passed to QEMU, so anything the guest does
  wrong is printed instead of swallowed

Both are in the binary, verified by `strings`. The run that should have
read them never completed: `apparition jit` connected, printed
"Launching", and never attached. The route is on `en0`, so this is device
state rather than networking, most likely the debug service wedged after
many attach and detach cycles in one session. A headset restart should
clear it.

A caution for next time, which cost two cycles here: `host.log` is
truncated per launch, so a failed launch leaves the **previous** run's log
in place and it reads as a result. Check that the periodic lines match the
format the current binary prints before believing them.

Open: restart the headset, then one run answers the open question.
If runstate is "running" with one frame, the CPU advances and does not
draw. Anything else means it never started or stopped itself.

## 2026-10-26 -- the CPU is spinning, not halted

Read on a freshly restarted headset, with the attach confirmed:

```
[host] t=  0s, 1 guest frames, runstate running, cpu executing
[host] t= 70s, 1 guest frames, runstate running, cpu executing
```

**`executing`, never `HALTED`, for seventy seconds.** So the guest is not
waiting on an interrupt that never arrives. It is actively running
translated code in a loop and getting nowhere, with no guest errors and
nothing unimplemented.

That is the signature of a poll: the BIOS waiting on a hardware state that
never changes.

### And there is exactly one device that failed to initialise

```
mcpx_apu_monitor_init failed: SDL_Init failed: Application didn't
initialize properly, did you include SDL_main.h in the file containing
your main() function?
```

The MCPX APU never came up. SDL3 expects to own `main()` on the iOS
family, and UIKit owns it here. `SDL_SetMainReady()` is the API for
exactly that case, and it is now called before `UIApplicationMain`.

Built, signed and installed. **Not yet verified**, because the attach
wedged again before a clean run.

### The iteration cost, stated plainly

`apparition jit` attaches successfully **once per headset restart**. After
that it connects, prints "Launching", and never attaches. Killing the app
with `devicectl process signal SIGKILL` does not clear it; only a restart
does.

Combined with the stale-log trap, that is a nasty pair: a failed attach
leaves the previous run's `host.log` in place, and it reads as a result.
Two readings were taken from stale logs before this was understood.

**Rule: confirm `detached: OK` in Apparition's output before trusting
anything in `host.log`.**

Open: restart the headset, one run, and look for whether the APU
warning is gone and whether the frame count moves past one.

### SDL_main.h hijacks the entry point

The first attempt at the APU fix included `<SDL3/SDL_main.h>` to get
`SDL_SetMainReady()`. That header **renames `main()` to `SDL_main()` and
supplies its own**, which on the iOS family runs SDL's own
`UIApplicationMain` path. Verified in the binary:

```
0000000100043754 T _SDL_main
0000000100043744 T _main
```

Both present. Ours ran second, inside SDL's app, and `SDL_SetMainReady()`
had no effect because SDL was already past the point it matters. The APU
warning was unchanged.

Now the header is gone and the single function is declared directly, so the
entry point is ours again:

```
0000000100043be8 T _main
```

Installed, **not yet verified**: the attach had already wedged.

Note the check that nearly misled: `nm -u` showed `SDL_SetMainReady` absent
and that looked like the call had been optimised away. SDL3 is statically
linked here, so the symbol is **defined** rather than undefined, and
`nm -u` lists only undefined ones. Use `nm | grep ' T '` for a static
library.

### The APU fix works

With `SDL_main.h` removed and `SDL_SetMainReady()` declared directly, on a
freshly restarted headset with `detached: OK` confirmed:

```
APU init failures: 0
```

The MCPX APU initialises on device. That warning is gone.

The guest still does not progress: `cpu executing`, one frame. But the
behaviour changed, which is itself information. The emulator thread's
periodic line **stops after t=10s** while the app stays alive, where
before it reported every ten seconds for over two minutes.

So the worker either returned or blocked once the APU was real. Candidates:
the APU's own threads now exist and something about them blocks the loop,
or `qemu_exiting` was set and `xemu_host_run` returned normally without
reaching its exit log.

Next instrument: log on the way out of `xemu_host_run`, and log
`qemu_exiting` alongside the runstate, so "returned" and "blocked" are
distinguishable. One line each, one run.

## 2026-10-28 -- the guest never leaves the reset vector

One fully instrumented run, attach confirmed (`detached: OK`), Tailscale
off, fresh headset:

```
t=  0s  runstate running, cpu executing, pc 0xfffffff0, exiting 0
t= 65s  runstate running, cpu executing, pc 0xfffffff0, exiting 0
```

**The program counter is `0xFFFFFFF0` at every sample for 65 seconds.** That
is the x86 reset vector. The CPU is "executing" in QEMU's sense, not
halted, not stopped, and it has never retired an instruction that moved it.

That is far more specific than "spinning". A polling loop in the BIOS would
show a PC somewhere in the BIOS. This PC is the very first fetch address
of the machine, and on the Xbox that address is served by the MCPX boot
ROM. So one of:

1. the first translated block runs and does not advance, meaning what
   executes is not what TCG wrote, or
2. `cpu_exec` is entered and leaves before running anything, so the PC
   never updates, or
3. the fetch at the reset vector is not reaching the boot ROM mapping.

(3) is unlikely: the same files, same machine type and same mapping code
boot to the dashboard on the Mac. (2) would normally show up as a halted
or stopped state, and neither is set. (1) is the one that is specific to
how code reaches the executable view on this platform, which is the one
thing that differs from the Mac.

The exit-path lines never printed and `exiting` stayed 0, so the earlier
"log goes quiet at ten seconds" was a sampling artefact, not a thread
returning.

### What one more run would settle

A single `memcmp` of the first few hundred bytes of the writable and
executable views, logged once after TCG has generated its prologue. If they
match, (1) is ruled out and the fault is in `cpu_exec` entry. If they
differ, the two views have diverged and the code that executes is not the
code that was written, which would explain a PC that never moves and no
faults at all.

### The two views match

```
splitwx views: MATCH   (first 64 KiB, every sample)
pc 0xfffffff0          (every sample)
```

So divergence between the writable and executable views is ruled out.
What TCG writes is byte for byte what the CPU would fetch. The remaining
explanation is that the vCPU is **not running translated code at all**,
despite `halted` being clear.

Next instrument, built and installed: `cpu->running` (true only inside
`cpu_exec`), `created` and `thread_id` (does the vCPU thread exist),
`exit_request` and `interrupt_request` (is it kicked out on every entry),
and `bql_locked()` from the host thread (are we starving it). Plain reads,
one run.

## 2026-10-29 -- the dashboard, on the headset

The Xbox dashboard renders on the Vision Pro, standalone, under JIT. The
sampler publishes the NV2A's scanned out surface at 30 frames a second,
the scene shows it in an image view, and the boot chime plays through the
headset. `frame.png` at t=10s is the green dashboard with the Xbox Live
notice and its OK button, 640x480, rendered by the Vulkan path and not the
VGA fallback (published nv2a 1020, vga 0, at t=35s).

Six wrong turns and the facts that corrected them, in order:

1. **The BQL theory was wrong.** The vCPU reading `running=1 exit_req=1
   irq_req=HARD|POLL` at the reset vector looked like a thread queued on
   the BQL in `cpu_handle_interrupt`, and the host's frame grab inside
   `dpy_gfx_update` was a plausible holder. Moving it off the BQL changed
   nothing. A stack dump of every thread (mach `task_threads`, frame
   pointer walk, `dladdr`) showed the main loop in `poll`, every device
   thread idle, and `CPU 0/TCG` at `pc = 0x110104000`: byte zero of the
   prepared region, the prologue's first instruction, called from
   `cpu_tb_exec`. The first JIT instruction never retired. No fault.
2. **"Prepare last" was a wrong rule drawn from a confounded table.** The
   10-28 row "base R+W, prepare last, runs" was judged by the process
   surviving, before the PC was being read. Nothing translated had ever
   executed in this port. The rule that explains the parked thread is in
   the Apparition write-up: "An app's own writable memory can never become
   executable." The upstream split-wx order starts from writable memory.
3. **Executable first with a remapped writable alias was killed outright**
   at the first execution, no signal, no crash record. UTM runs with JIT on
   this same headset, so the order was right and something else was not.
4. **Self-tests settled the mechanism.** `mov x0, #42; ret` written through
   the writable view returned 42 from the far page, from a page start over
   the debugger's word, from a fresh pthread, from the vCPU thread, and
   the real prologue entered with the epilogue as its target returned from
   all of them. Then the first real block killed the process.
5. **The block announcer showed the guest running.** Sixty-four blocks, the
   PC walking from `0xfffffff0` into the MCPX ROM at `0xfffffe00`, then
   death within a second. With the footprint printed alongside: **5119 MiB
   at the first block.** The process was sitting on its memory ceiling,
   and the first growth ended it. The earlier tb-size findings were
   measuring the same wall.
6. **The memory is the Vulkan renderer's.** Entry 15 MiB, after TCG 49 MiB,
   after `qemu_init` 5119 MiB. Per step: two compute buffers at
   10240 x 10240 x 8 bytes, 800 MiB each, sized for 10x surface scaling on
   a desktop GPU; capped to 2048 x 2048 x 8 on the iOS family. After that
   the machine ran: 5.39 million blocks in thirty seconds, the PC through
   the kernel and into a title, footprint 3.6 to 4.0 GiB.

Still fat: 3.3 GiB appears inside `create_dummy_texture`, the first device
allocation. By VM tag it is 1681 MiB under tag 100 (one 1280 MiB region
at `0x7000000000`, Metal) and 1206 MiB anonymous. That is the next thing
to trim, because the ceiling is near 5 GiB without the increased memory
limit entitlement and the dashboard alone sits at 3.5.

### Two operational corrections

- **A reboot is needed only after a clean detach.** The "once per boot"
  rule was measured when the app detached and kept running. After a kill,
  `apparition jit` attaches again at once. Every failing run today after
  the first went without a reboot.
- **A kill with no message is not evidence about ordering** while a memory
  ceiling is in play. The footprint belongs in the first line of every log
  from now on, not the last.

### What the self-tests are still doing in the tree

`tcg_jit_selftest*`, the block announcer in `cpu_tb_exec`, the thread
dump and the execute probe are all still compiled in on the iOS family.
They cost nothing measurable and they are the instruments that found
this; they come out when the port has a second machine to compare against.

### Numbers

| | |
|---|---|
| JIT order | anon R+X, remap, `brk #0x69` on the remap, mprotect base R+W |
| tb-size | 32 MiB, 2048 pages prepared in 0.14 to 0.24 s |
| footprint | 3543 MiB after renderer init, 3610 after `qemu_init`, 4034 at 30 s |
| blocks | 5.39 million in 30 s, announcer every millionth now |
| frames | 30 per second published, 640x480, presented by the scene's display link |

### Controllers, same day

The PSVR2 Sense controllers drive the dashboard. They reach the app
through the GameController framework, which SDL already links, as two
separate devices with only the generic physical profile (the extended
gamepad profile is absent, which is why the first reader saw nothing).
The right one offers `Button A, Button B, Button Menu, Grip, Thumbstick,
Thumbstick Button, Trigger`; the vendor name carries the hand. The shell
merges both hands onto the Duke on every display tick and writes into a
host-fed `ControllerState` that xemu's XID device polls like any other;
the state is bound to port 1 right after `qemu_init`, on the thread that
still holds the BQL. First presses in the log: `0x0001` (Cross as A),
`0x0801` (plus the grip as Black).

Also measured: the Apparition attach wedge is intermittent, not "once
per boot". Four launches in a row worked over surviving, cleanly
detached instances; the fifth hung at "Launching" and only a reboot
cleared it. Killing the hung launcher and retrying does not help.

### Why the dashboard ignored everything but Options

Measured with a separate SwiftUI probe (`tools/xros/controller-probe`), a
window plus an empty mixed immersive space, logging every element change
the GameController framework delivers. Window only: nothing. Immersive
space open: the trigger streams analog values, Cross and Circle arrive as
press and release pairs. visionOS hands a spatial controller to an app
only while that app has an immersive space open; in a plain window the
controllers stay the system's pointer and only Menu reaches the app. The
one run where Cross had arrived in the headless host was right after a
reboot, before the system had claimed them.

So the shell needs a SwiftUI entry: the same window, plus an immersive
space opened at launch, which is the shape the real app needs anyway.

### And then it was playable

The last two rules, both found on the headset by the owner:

1. **Gaze.** With the immersive space open the controllers were the
   app's, except whenever the owner looked at the app's window: then
   visionOS made them that window's pointer again and the dashboard went
   dead. Every "nothing works" report was the owner looking at the
   dashboard, which is the one thing a dashboard invites.
2. **So, no window.** The app now launches straight into a mixed
   immersive space (`UIApplicationPreferredDefaultSceneSessionRole` set
   to the immersive role, one `ImmersiveSpace` scene) and the guest's
   frame is a two metre 4:3 plane at eye height, textured through a
   `TextureResource.DrawableQueue` from the same published BGRA copies at
   30 frames a second. There is nothing left to look at that could take
   the controllers back.

With that, the Sense pair drives the dashboard: left stick and face
buttons, triggers as analog values, Options as Start. The first launch of
that build died silently about a second after the first frame reached the
plane; the relaunch held. The process sits near the memory ceiling and
RealityKit and Metal now sit on top of it, so trimming the renderer's
remaining gigabytes is the next piece of work, not the controllers.

Also retired this session: the per-run thread dumps and the execute probe
(they found the JIT answer, and suspending every thread was coincident
with losing the space twice), the host-side press injection, and the
window itself.

### Leaving and coming back

Three more findings on the same evening, each with its fix in the tree:

- **A backgrounded app loses the GPU.** The first run of the immersive
  screen was playable for twenty seconds, then the app went to the
  background, the next Metal command buffer failed with insufficient
  permission, MoltenVK declared the device lost and the renderer asserted
  in `pgraph_vk_finish`. The shell now tells the host when the app resigns
  active; the host stops the frame grabs at once and schedules `vm_stop`
  on the main loop, and `vm_start` on return. Measured: pause, background,
  return, resume, frames continuing from the same sequence, twice in a
  row, no device loss.
- **No window means no way back.** With the space as the only scene,
  dismissing it (the controller's home button) left the app with nothing
  the icon could present. A small launcher window is the default scene
  again: it opens the space and dismisses itself, and reappears whenever
  the space has gone. Nothing of the app's is on screen while playing, so
  the gaze rule stays out of the way.
- **The seven day profile expired mid-session**, at 17:38 UTC, and the
  renewal through `make device` in the probe came back as a team wildcard
  valid for a year. installd then refused the upgrade because the signed
  `application-identifier` read `TEAMID.*` against an installed app with
  the concrete id; the signing script now writes the concrete id into the
  entitlements it derives from a wildcard profile.

Open, in order of what bites next: the process sits near its memory
ceiling (one first launch of the screen build died silently a second in),
the Apparition attach wedge still costs a reboot now and then, and the
guest's block rate on this device wants a look before any game.

### A game boots

Fuzion Frenzy, from the owner's own disc image bundled read-only as the
drive, boots in place of the dashboard: the publisher splash at ten
seconds, then the game. Measured over 75 seconds: 30 to 70 guest flips a
second, one code buffer flush, block rate swinging from 25 thousand to 3
million a second as the game alternates render loops and waits. The
machine is not the bottleneck at this point; the presentation path is.

### Why it looks the way it does, and the plan

Every presented frame is the renderer's download of the scanned-out
surface into guest memory: 640x480, the guest's resolution whatever the
internal scale, stretched over a two metre plane at two and a half
metres. The sampler takes 30 a second of the guest's 60, and each one
forces a GPU to CPU download that stalls the render thread. The sRGB
declaration on the screen texture (this evening) fixes the crushed
gradients; the resolution and the stalls are structural.

The rendering work, in order:

1. **Zero copy.** The Vulkan renderer's surface is already an MTLTexture
   underneath (MoltenVK, `VK_EXT_metal_objects` is enabled). Export it,
   blit on the GPU into a texture the screen owns (RealityKit's
   `LowLevelTexture`, or a drawable the space presents), and never
   download. This removes the stall and presents every flip.
2. **Internal scale.** With no download in the way, `surface_scale` 2 or
   3 renders the game at 1280x960 or 1920x1440 on the M5 for free, and
   the screen shows it. Today that setting would cost GPU time and change
   nothing, because the download is always guest-sized.
3. **Filtering and pacing.** Linear filtering is on; what remains is
   matching the plane's refresh to the guest's flips rather than a 33 ms
   poll, which the zero copy path makes natural.

Memory stays the standing risk through all of it: 3.6 GiB after init with
the 2 GB disc image mapped read-only from the bundle, near the ceiling.

### Zero copy, the design, with the pieces located

- **The seam.** `hw/xbox/nv2a/pgraph/vk/surface.c`, `download_surface()`:
  it already calls `pgraph_vk_finish`, begins a single-time command
  buffer, transitions `surface->image`, and when the scale factor is not
  1 blits into `surface->image_scratch` before the copy to a buffer and
  the memcpy into guest VRAM. The zero copy path branches right after the
  transition: `vkCmdBlitImage` from `surface->image` (full internal
  resolution) into an imported image, then present, and skips the buffer
  and the memcpy entirely.
- **The imported image.** `VK_EXT_metal_objects` is already enabled on
  the device. `VkImportMetalTextureInfoEXT { plane, mtlTexture }` in the
  `pNext` of `vkCreateImage` wraps an existing `MTLTexture` as a
  `VkImage`; the export direction (`VkExportMetalTextureInfoEXT` via
  `vkExportMetalObjectsEXT`) exists too if the other way round proves
  easier. Headers: `vulkan_metal.h`, lines 150 to 166 in the SDL copy.
- **The screen's texture.** Two candidates on this SDK. The
  `TextureResource.DrawableQueue` already in use: each `nextDrawable()`
  carries an `MTLTexture`; hand its pointer to the renderer, it imports,
  blits, signals; the app calls `present()`. Or `LowLevelTexture`
  (RealityFoundation, re-exported by RealityKit on this SDK), written
  through a Metal command buffer. The drawable queue is the smaller
  change and keeps the plane's material as it is.
- **Synchronisation.** All on the Vulkan side: the blit goes into the
  same single-time command buffer, `pgraph_vk_finish` waits as it does
  for the download today, and only then does the host present. Later,
  a semaphore instead of the wait.
- **Format.** The scan-out surface is `B8G8R8A8_UNORM`; the drawable is
  `bgra8Unorm_srgb` (declared, same bits). A blit between them is a
  straight copy; a mismatch would show as a gamma shift, not a failure.
- **Then** `surface_scale` 2 or 3 becomes a one-line setting with a
  real effect, and the plane shows 1280x960 or 1920x1440.

Order of work: import a drawable's texture and blit the surface into it
with the present on completion (one run shows whether the imported image
needs memory bound, which MoltenVK's documentation is unclear on); then
pace presents on flips instead of the 33 ms poll; then the scale.

### Zero copy, measured

It works. The Metal texture behind each of the screen's drawables imports
as a `VkImage` through `VkImportMetalTextureInfoEXT`; MoltenVK asks for
1,327,104 bytes of memory to be bound to it and takes a plain GPU-only
allocation (`vmaAllocateMemoryForImage` refuses the AUTO usages). The
scan-out surface's host format is 44, `B8G8R8A8_UNORM`, so every frame
is a bitwise `vkCmdCopyImage` into the sRGB drawable and the values
travel untouched. The plane is fed from the GPU; the download, the
memcpy and the texture upload are gone from the frame path. Two
corrections on the way: the presenter starts when the space appears,
before the machine exists, and must answer nothing until it does; and
the drawable queue rotates three textures, so the imported image is a
four slot cache keyed by texture and size rather than a single one that
re-imported every frame (747 imports for 3 textures in a minute).

Still in the path: a full `pgraph_vk_finish` and queue wait per
presented frame, inherited from the download. Removing it means riding
the renderer's own command stream with a fence and presenting on the
fence, which is the next rendering step, followed by the internal scale.

With the four slot cache: nine imports in a run whose launcher rebuilt the
queue three times, otherwise copies only. Presented frames track the
guest's flips, 1200 GPU frames in about 25 seconds against 43 to 66 guest
flips a second, no error, process steady. The zero copy path is in.

## 2026-10-29 -- published as Xbawks

`github.com/Ywach404/xbawks-avp`, public, one commit, 41 files, 0.5 MB, no
history. Verified on the remote after the push: no image, ROM, disc or
container file of any kind, and the top level is `.gitignore`, `DEVLOG.md`,
`LICENSE`, `README.md`, `UPSTREAM.md`.

What came out of the tree first, because a public remote reads everything:

- The signing identity and the headset were written down in two scripts.
  Both are discovered now, from the keychain and from `devicectl`, with an
  environment variable to override and an error if neither finds anything.
- The devlog named the owner, the headset's UDID, the Mac's serial and the
  team id. It names none of them now.
- One BIOS image was named by its filename in the scripts and twice in the
  devlog. The bundle takes whatever `.bin` is not the MCPX ROM and installs
  it as `bios.bin`.
- The disc default pointed at one title by name in the repository root,
  which is not where anyone else's disc image lives. It is `XEMU_GAME`, or
  any `.iso` in the media folder.
- Three planning notes under `docs/` retired: a plan from 2026-10-08 and two
  resume documents, superseded by this file and written for a reader who no
  longer exists.
- Every sibling project the workspace holds was named in those notes and in
  `UPSTREAM.md`. The one reference worth keeping, the Quake port's vendoring
  decision, is described rather than named.

### How to update it

The public branch is a squashed export, not the working history. The
working branch keeps every commit; `public` carries one. To publish again:

```sh
git checkout public
git checkout feat/xemu-avp-port -- .      # take the working tree as it stands
git status                                 # read it before committing
git commit -am "<what changed>"
git push github public:main
```

Check the same four things first, because a public remote reads everything:
no personal identifiers, no sibling project names, no media, no file naming
a particular BIOS or disc. `tools/check-prose.sh` catches the dash rule but
none of that.

## 2026-10-29 -- MoltenVK is deprecated, and it does not move this port

The rumour is true and the primary source is the MoltenVK README itself,
not Wikipedia, which states it without a citation. Khronos merged the
notice on 2026-10-13 (PR 2874):

> Khronos has deprecated MoltenVK, its Vulkan-on-Metal implementation.
> This repository is now maintained by the community on a best-effort
> basis. For Vulkan on Metal, Khronos now recommends KosmicKrisp on Apple
> Silicon Macs. MoltenVK remains the recommended option for Intel-based
> Macs and for iOS.

**A Vision Pro sits on the iOS side of that sentence.** The successor does
not reach this port, for three independent reasons, each read from the
Mesa tree rather than inferred:

1. **No visionOS target exists.** Mesa's own
   `docs/drivers/kosmickrisp.rst`: "KosmicKrisp is a Vulkan conformant
   implementation for macOS on Apple Silicon hardware... No iOS support is
   present as of now." A grep for `visionos` across `src/kosmickrisp`
   returns nothing.
2. **The iOS build is deliberately not enabled.** LunarG, 2026-10-15: the
   iOS build "is not enabled until appropriate resources are assigned to
   enable CI on iOS devices".
3. **It cannot import an `MTLTexture`.** KosmicKrisp implements
   `VK_EXT_external_memory_metal` with exactly one handle type,
   `MTLHEAP`. There is no `VK_EXT_metal_objects` and no
   `MTLTEXTURE_BIT_EXT` path. The zero-copy presentation here needs the
   import direction specifically, because RealityKit hands out a drawable
   whose texture must be rendered into, so inverting the flow is not an
   option either. This is an implementation gap, not a specification one:
   the extension does define the texture handle type.

Status of the thing we actually ship: not archived, no end-of-support
date, still in the LunarG SDK, 51 pull requests queued, and community
maintainers who also work on KosmicKrisp. Zero commits since the notice,
which is the longest gap in its log but is one data point.

**The bundle carries 1.4.2**, confirmed both ways: `CFBundleShortVersionString
1.4.2` in the framework, and the device logging `MoltenVK version 1.4.2,
supporting Vulkan version 1.4.334`. That is the last tagged release,
2026-07-24, taken from UTM's visionOS sysroot artifact. Commits made
between 2026-10-03 and the notice carry fixes that are in no tag, so a
future rebuild should take post-notice `main` rather than the v1.4.2 tag.

**Nothing changes in the code.** The framework is bundled and dlopened, so
there is no system component to be withdrawn and no update that can remove
it. The one mechanism that actually breaks this port is a future visionOS
changing Metal behaviour that 1.4.2 relies on with nobody upstream fixing
it, which is a reason to smoke test on each visionOS beta and to be
willing to carry a local patch, not a reason to migrate to a driver that
does not build for this platform.

Revisit KosmicKrisp only when both become true: an enabled visionOS or iOS
build in Mesa with CI behind it, and a path to import an existing
`MTLTexture`.

## 2026-10-30 -- two things the first public build got wrong

Caught by a scan of the published repository the day after it went up.
Both were defaults that were convenient while the repository was private
and dangerous the moment it was not.

**The build script would have shipped Microsoft firmware and a game.**
`make-app.sh` defaulted `XEMU_MEDIA` to a path that exists on this
machine, so every build silently copied the MCPX boot ROM, the BIOS, the
2 GB hard disk image and the first disc image it found into the app, then
zipped all of it into an IPA. An IPA is the shape that gets uploaded.

Media is now copied only when `XEMU_MEDIA` names a folder, a disc only
when `XEMU_GAME` names one, and a bundle carrying either **refuses to
become an IPA**. Both paths tested: with nothing set, zero media and a
9.9 MB IPA; with media set, media present and no IPA. Testing also caught
a trap the refusal created, since the IPA from the previous medialess
build was left on disk where it could be uploaded in place of the refused
one, so the refusal deletes it.

**The commit carried a personal email.** The repository's commit identity
is now the GitHub noreply address, and the single public commit was
rewritten and force pushed. That removes the address from the live
history; it does not undo the day it spent served by the API, so treat
reduction rather than erasure as the outcome.

The general shape of both: a default chosen for local iteration speed,
never revisited when the repository gained a remote. The question that
catches it is not "did I remember" but "if a stranger ran this, what
lands in the output".

### The guard now checks for it, rather than the rule only being written down

Two rules added to `~/.config/git/template/hooks/pre-push`, and the hook
split into two tiers while doing it, because the two things it guards
have different risk.

**Rule 3, content that is not ours to give away.** Refuses a push whose
paths look like firmware, a ROM, a disc image or save data: `.iso`,
`.xiso`, `.xbe`, `.rom`, `.bin`, `.qcow2`, `.img`, a dozen cartridge
formats, and anything named `bios*`, `mcpx*`, `eeprom*` or `firmware*`.
`.gitignore` already denies these, so it should never fire. It exists
because `.gitignore` filters what gets added and this checks what
actually leaves.

**Rule 4, a build default that would include what it should not.**
Refuses an added line matching a shell parameter expansion whose
variable name carries MEDIA, ROM, BIOS, FIRMWARE, GAME, ISO, ASSET,
SAMPLE, FONT, MODEL, SAVE or DISC and whose default is not empty.
`${XEMU_MEDIA:-}` passes. `${XEMU_MEDIA:-$ROOT/../_scratch/media}`, which
is exactly the line that caused this, does not.

Tested against five cases in a throwaway repository rather than reasoned
about: a clean push passes, the same push to a private GitLab exits
silently, a disc image is refused by name, the dangerous default is
refused and quoted back, and the empty default passes. Then against the
real thing: the public commit passes clean, and the working branch is
correctly refused, because its full history carries the pre-scrub
commits. Only the squashed export can reach GitHub, which is the
intended shape.

**Rule 3 runs on every remote; Rules 1, 2 and 4 stay public only.** A
private note or another project's name is only dangerous at publication,
and the hook still exits before those on a GitLab push. A boot ROM is
dangerous in any history, because a repository that is private today can
gain a public remote tomorrow, as this one did on 2026-10-29, and by
then the history already carries it. `.gitignore` is also only a filter
on what gets added, and `git add -f` walks past it.

Measured before widening rather than after: across 28 repositories
exactly one tracks a file matching Rule 3, and it is
`port/assets/models/S4g.mlpackage/.../weight.bin`, CoreML weights rather
than firmware. So the rule carves out `.mlpackage`, `.mlmodelc` and
`.mlmodel` paths and widening costs nothing.

Retested on both tiers: a ROM is refused to GitHub and to GitLab, the
CoreML file passes on both, a dangerous build default is refused to
GitHub and ignored on GitLab, and a clean push passes everywhere. Then
against the three repositories that have GitHub remotes, simulated
against what those remotes actually hold: all clean.

Deployed to all 29 repositories, one of which had no guard at all. Every
previous hook is kept under `~/.config/git/hook-backups/<timestamp>/`,
so the change is reversible with a copy back.
