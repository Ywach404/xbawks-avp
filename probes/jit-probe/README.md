# jit-probe -- S0

The gate for the whole port, in one app.

QEMU's TCG works by assembling fresh arm64 instructions into a page at
runtime and jumping to them. If visionOS refuses to let a process do that,
the only engines left are interpreters, and an interpreter cannot reach
playable: upstream xemu manages 18.3 fps on an M4 *with* a real JIT.

So this app asks the platform directly, in the three launch modes that could
plausibly differ, and reports what it finds in a window you can read with the
headset on.

## What it tries

Four paths, because "JIT does not work" has several different mechanisms
behind it and they need telling apart.

| path | allocation | made executable by | why it is here |
|---|---|---|---|
| D  | `mmap` RWX, no `MAP_JIT` | nothing | **the one the real ones use.** PPSSPP, DolphiniOS and UTM's debugged-JIT path all do exactly this |
| A  | `mmap` RWX + `MAP_JIT` | `pthread_jit_write_protect_np(0/1)` | how every shipping JIT on *macOS* does it |
| A' | `mmap` RWX + `MAP_JIT` | nothing | checks whether the mapping is simply RWX and the toggle is a no-op |
| B  | plain anonymous RW | `mprotect` to R+X | the naive way. Expected to fail under a hardened runtime, and a failure next to a success in A is the clearest statement of what is actually enforced |
| C  | `MAP_JIT` RW | `mprotect` to R+X | the halfway house |

D runs first and is the one to read first. On iOS-family kernels `MAP_JIT`
can demand the `dynamic-codesigning` entitlement and return `EPERM` whatever
CS_DEBUGGED says, while plain RWX is what the debugged exemption actually
unlocks. A probe without D could report nothing working on a platform where
JIT works perfectly well.

The simulator already shows the two mechanisms diverging in the opposite
direction, which is the point: D fails there with `EPERM` while A succeeds.
Do not assume the device agrees with either.

Each path writes `mov w0, #42 ; ret` and calls it. Getting **42** back is the
only accepted proof: a page that faulted straight back to the caller would
look like success otherwise.

Every path runs behind a `sigsetjmp` guard for SIGBUS, SIGSEGV, SIGILL and
SIGTRAP, so one failing does not take the other three with it.

It also reports the process's **code signing status word**, via `csops`.
CS_DEBUGGED is the bit the attach trick actually sets, and it is the
difference between "JIT works here" and "JIT works because a debugger touched
us". Without it a pass in mode 2 would be unreadable.

GET_TASK_ALLOW is worth watching too: a run where DEBUGGED is clear but
GET_TASK_ALLOW is set means the build *can* be attached to and simply has not
been, which is a different problem from a build that never could be. The
simulator baseline below shows neither bit, so a device run showing
GET_TASK_ALLOW is the first sign the provisioning is right.

## The three modes, in order

```sh
DEV_TEAM=XXXXXXXXXX make run        # mode 1
DEV_TEAM=XXXXXXXXXX make run-debug  # modes 2 and 3
```

**Mode 1, plain launch, no debugger.** The ordinary sideload. If JIT works
here, nothing else about launching matters and the port is in excellent
shape. Run it twice: once through `make run`, and once by tapping the icon on
the home screen with no cable involved, which is the launch that actually
represents living with the app. The window keeps the report either way.

**Mode 2, attached.** `make run-debug` installs the build and opens Xcode
with instructions. Pick the **JITProbe-Attached** scheme, Run, and read the
report. Expect this one to pass. It is the control, not the answer, and it
should show `CS_DEBUGGED: YES`.

**Xcode will break on EXC_BAD_ACCESS during mode 2, and that is not a
crash.** With lldb attached, a fault is a Mach exception that the debugger
catches *before* the `sigsetjmp` guard ever runs. A' faults by design, so
Xcode stops at the `memcpy`; press Continue and it stops again on the SIGBUS,
and only then does the guard run and the probe carry on. Two stops per
faulting path is normal. Typing

```
process handle SIGBUS SIGSEGV SIGILL -s false -n false -p true
```

in the lldb console removes the second stop but not the first. Mode 3, after
the detach, has no debugger and behaves like the simulator did.

**Mode 3, attached then detached.** The one the project rests on. In Xcode
choose **Debug > Detach**, not Stop, then press **Run again** in the headset.
On iOS a process that has been ptraced keeps CS_DEBUGGED, and the JIT
permission that comes with it is not taken back at detach. That is the
mechanism behind every sideloaded emulator with working JIT. Whether
visionOS 27 behaves the same way is the thing nobody here has measured.

Press **Copy report** and paste the result into `DEVLOG.md`.

`run-debug.sh` deliberately stops short of driving the debugger itself.
`--start-stopped` suspends a process but does not ptrace it, so it would not
set CS_DEBUGGED and mode 3 would pass for the wrong reason; and attaching
lldb to a headset by hand needs `platform select remote-xros` plus a platform
connect, which was not verified on hardware and is not worth guessing at
inside a script. Xcode's Run button ptraces reliably, so the script installs
the build and hands over.

## Reading the result

- **Mode 1 passes.** Best case by a distance. Build the port, ship it as an
  ordinary sideload.
- **Mode 1 fails, mode 3 passes.** The port is alive, and an attach step
  becomes part of putting the headset on, every time. Worth knowing before
  committing months, because that is a fact about living with the thing.
- **Mode 3 fails too.** Playable is not reachable on this platform. Stop.

## If the app vanishes instead of reporting

Executing a page the kernel objects to can end the process harder than a
signal handler can catch. The report is therefore rewritten to a journal file
after **every line**, before the next step is attempted, so its last line
names the step that did it.

```sh
make journal
```

The app also shows the previous launch's journal in a disclosure group, so a
crash followed by a relaunch tells you what happened without a cable.

## Simulator baseline, 2026-10-22

`make check` builds, and the app was run once on the visionOS 27.0 simulator
to prove the probe itself is correct before it reaches hardware. Result:

```
CS_DEBUGGED: no
code signing status: 0x22020201 VALID KILL
pthread_jit_write_protect_np: resolved
pthread_jit_write_protect_supported_np: resolved, returns 1
D  FAILED at mmap, errno 13 (Permission denied)
A  EXECUTED, returned 42
A' FAILED at write, signal 10 (Bus error)
B  EXECUTED, returned 42
C  EXECUTED, returned 42
3 of 5 paths executed
```

**This says nothing about the question.** A visionOS simulator process is a
macOS process and inherits macOS policy, which is exactly the policy under
dispute. What it does establish is that the probe works: the stub really
executes and returns 42, and A' failing at the write proves both that
`MAP_JIT` pages start execute-protected and that the signal guard catches the
fault and carries on to the next path instead of taking the process down.

A' and D failing are expected results, not defects. A' proves MAP_JIT pages
start execute-protected and that the guard recovers; D fails because a
macOS-policy process will not hand out plain RWX.

## Status

Throwaway. It answers one question and then it is done. No tests, nothing
hardened, and nothing here is a foundation for the port.
