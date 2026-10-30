// jitprobe.h -- S0: can this process create new machine code and run it?
//
// The whole xemu port rests on the answer. QEMU's TCG writes freshly
// assembled arm64 into a page and jumps to it; if visionOS refuses, the
// only engines left are interpreters and those are a slideshow.
//
// Everything here is plain C on purpose. The question is about the platform,
// not about Swift, and a C file is what the real emulator will ask with.

#ifndef JITPROBE_H
#define JITPROBE_H

#include <stddef.h>

// Runs every path and appends a human readable report to `out`.
//
// `journal_path`, if non-NULL, is rewritten after every line. Executing a
// page the kernel does not want executed can take the process down harder
// than a signal handler can catch, so the journal is the only record that
// survives that. Read it back on the next launch to see which step died.
//
// Returns the number of paths that executed the stub and got 42 back.
int jp_run_all(const char *journal_path, char *out, size_t cap);

// 1 if this process carries CS_DEBUGGED, 0 if not, -1 if unknowable.
// This is the bit the attach trick actually sets, so it is the difference
// between "JIT works here" and "JIT works because a debugger touched us".
int jp_cs_debugged(void);

#endif
