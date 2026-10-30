// jitprobe.c -- S0: can this process create new machine code and run it?
//
// Four paths, because "JIT does not work" has several different mechanisms
// behind it and they need telling apart:
//
//   A   MAP_JIT page, flipped writable and back with pthread_jit_write_protect_np.
//       This is how every shipping JIT on Apple silicon does it. If A works,
//       QEMU's TCG works, and the port is alive.
//   A'  MAP_JIT page, no toggle at all. Some platforms hand back a plain RWX
//       mapping and the toggle is a no-op. Worth knowing, because it is one
//       fewer thing the port has to get right.
//   B   Ordinary anonymous page, mprotect to R+X afterwards. The naive way.
//       It is not how JITs do it and it is expected to fail under a hardened
//       runtime, but a failure here next to a success in A is the clearest
//       possible statement of what the platform actually enforces.
//   C   MAP_JIT page allocated R+W, then mprotect to R+X. The halfway house.
//   D   Plain anonymous RWX, no MAP_JIT and no mprotect. Write and call.
//       THIS IS THE ONE THE REAL ONES USE. PPSSPP, DolphiniOS and UTM's
//       debugged-JIT path all do exactly this. On iOS-family kernels MAP_JIT
//       can demand the dynamic-codesigning entitlement and return EPERM
//       whatever CS_DEBUGGED says, while plain RWX is what the debugged
//       exemption actually unlocks. A probe without D could report nothing
//       working on a platform where JIT works fine, so D runs first.
//
// Each path is run behind a signal guard, so one failing does not take the
// other three with it.

#include "jitprobe.h"

#include <dlfcn.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <os/log.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// mov w0, #42 ; ret
//
// Returning a value rather than just not crashing is deliberate: a page that
// faults straight back to the caller would look like success otherwise. 42
// came out of the page or the page never ran.
#define JP_MAGIC 42
static const uint32_t kStub[2] = { 0x52800540u, 0xD65F03C0u };

typedef int (*jp_stub_fn)(void);
typedef void (*jp_toggle_fn)(int);
typedef int (*jp_supported_fn)(void);
typedef int (*jp_csops_fn)(pid_t, unsigned int, void *, size_t);

#define JP_CS_OPS_STATUS      0
#define JP_CS_VALID           0x00000001
#define JP_CS_GET_TASK_ALLOW  0x00000004
#define JP_CS_INSTALLER       0x00000008
#define JP_CS_HARD            0x00000100
#define JP_CS_KILL            0x00000200
#define JP_CS_RESTRICT        0x00000800
#define JP_CS_ENFORCEMENT     0x00001000
#define JP_CS_DEBUGGED        0x10000000

// ---------------------------------------------------------------- reporting

struct jp_out {
	char  *buf;
	size_t cap;
	size_t len;
	const char *journal;
};

static void jp_say(struct jp_out *o, const char *fmt, ...)
{
	char line[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);

	// Three destinations, because each one survives something the others
	// do not: the buffer reaches the window, stderr reaches `devicectl
	// --console`, and the journal survives the process dying outright.
	os_log(OS_LOG_DEFAULT, "[jitprobe] %{public}s", line);
	fprintf(stderr, "[jitprobe] %s\n", line);
	fflush(stderr);

	if (o->len + 1 < o->cap) {
		int n = snprintf(o->buf + o->len, o->cap - o->len, "%s\n", line);
		if (n > 0) o->len += (size_t)n;
	}
	if (o->journal) {
		// Append, never truncate. A path that gets SIGKILLed takes the
		// process with it, and the next launch has to be able to read
		// what the last one managed before it died.
		FILE *f = fopen(o->journal, "a");
		if (f) { fprintf(f, "%s\n", line); fclose(f); }
	}
}

// ------------------------------------------------------------ signal guard

static sigjmp_buf          g_jump;
static volatile sig_atomic_t g_caught;

static void jp_on_signal(int sig)
{
	g_caught = sig;
	siglongjmp(g_jump, 1);
}

static const int kGuarded[] = { SIGBUS, SIGSEGV, SIGILL, SIGTRAP };
#define JP_NGUARDED (sizeof kGuarded / sizeof kGuarded[0])

static void jp_guard_install(struct sigaction *saved)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = jp_on_signal;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	for (size_t i = 0; i < JP_NGUARDED; i++)
		sigaction(kGuarded[i], &sa, &saved[i]);
}

static void jp_guard_restore(struct sigaction *saved)
{
	for (size_t i = 0; i < JP_NGUARDED; i++)
		sigaction(kGuarded[i], &saved[i], NULL);
}

// Calls the page. Returns the value it produced, or -1 having set *sig if it
// trapped instead.
static int jp_call_guarded(void *page, int *sig)
{
	struct sigaction saved[JP_NGUARDED];
	volatile int result = -1;

	*sig = 0;
	g_caught = 0;
	jp_guard_install(saved);

	if (sigsetjmp(g_jump, 1) == 0) {
		jp_stub_fn fn = (jp_stub_fn)page;
		result = fn();
	} else {
		*sig = (int)g_caught;
	}

	jp_guard_restore(saved);
	return result;
}

// ------------------------------------------------------------------- paths

static long jp_pagesize(void) { return sysconf(_SC_PAGESIZE); }

// Writes the stub and reports whether the write itself survived. Under a
// write-protected MAP_JIT mapping this is where it dies, not at the call.
static int jp_write_guarded(void *page, int *sig)
{
	struct sigaction saved[JP_NGUARDED];
	volatile int ok = 0;

	*sig = 0;
	g_caught = 0;
	jp_guard_install(saved);

	if (sigsetjmp(g_jump, 1) == 0) {
		memcpy(page, kStub, sizeof kStub);
		ok = 1;
	} else {
		*sig = (int)g_caught;
	}

	jp_guard_restore(saved);
	return ok;
}

static void jp_finish(struct jp_out *o, const char *name, void *page,
                      int *executed)
{
	int sig = 0;
	sys_icache_invalidate(page, sizeof kStub);
	jp_say(o, "%s: calling the page", name);

	int v = jp_call_guarded(page, &sig);
	if (sig)
		jp_say(o, "%s: FAILED at call, signal %d (%s)", name, sig, strsignal(sig));
	else if (v == JP_MAGIC) {
		jp_say(o, "%s: EXECUTED, returned %d", name, v);
		(*executed)++;
	} else
		jp_say(o, "%s: returned %d, expected %d", name, v, JP_MAGIC);
}

// No MAP_JIT, no mprotect, no toggle. Ask for RWX up front and use it.
static void jp_path_plain_rwx(struct jp_out *o, int *executed)
{
	const char *name = "D  (plain RWX, as the iOS emulators do it)";
	long ps = jp_pagesize();

	jp_say(o, "%s: mmap RWX, no MAP_JIT, %ld bytes", name, ps);
	void *page = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE | PROT_EXEC,
	                  MAP_PRIVATE | MAP_ANON, -1, 0);
	if (page == MAP_FAILED) {
		jp_say(o, "%s: FAILED at mmap, errno %d (%s)", name, errno, strerror(errno));
		return;
	}
	jp_say(o, "%s: mapped at %p", name, page);

	int sig = 0;
	if (!jp_write_guarded(page, &sig)) {
		jp_say(o, "%s: FAILED at write, signal %d (%s)", name, sig, strsignal(sig));
		munmap(page, (size_t)ps);
		return;
	}
	jp_say(o, "%s: wrote %zu bytes", name, sizeof kStub);

	jp_finish(o, name, page, executed);
	munmap(page, (size_t)ps);
}

static void jp_path_map_jit(struct jp_out *o, jp_toggle_fn toggle,
                            int use_toggle, int *executed)
{
	const char *name = use_toggle ? "A  (MAP_JIT + toggle)"
	                              : "A' (MAP_JIT, no toggle)";
	long ps = jp_pagesize();

	jp_say(o, "%s: mmap RWX + MAP_JIT, %ld bytes", name, ps);
	void *page = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE | PROT_EXEC,
	                  MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
	if (page == MAP_FAILED) {
		jp_say(o, "%s: FAILED at mmap, errno %d (%s)", name, errno, strerror(errno));
		return;
	}
	jp_say(o, "%s: mapped at %p", name, page);

	if (use_toggle) {
		if (!toggle) {
			jp_say(o, "%s: SKIPPED, pthread_jit_write_protect_np not resolvable", name);
			munmap(page, (size_t)ps);
			return;
		}
		jp_say(o, "%s: toggle(0), unprotecting for write", name);
		toggle(0);
	}

	int sig = 0;
	if (!jp_write_guarded(page, &sig)) {
		jp_say(o, "%s: FAILED at write, signal %d (%s)", name, sig, strsignal(sig));
		if (use_toggle && toggle) toggle(1);
		munmap(page, (size_t)ps);
		return;
	}
	jp_say(o, "%s: wrote %zu bytes", name, sizeof kStub);

	if (use_toggle) {
		jp_say(o, "%s: toggle(1), reprotecting for execute", name);
		toggle(1);
	}

	jp_finish(o, name, page, executed);
	munmap(page, (size_t)ps);
}

static void jp_path_mprotect(struct jp_out *o, int with_map_jit, int *executed)
{
	const char *name = with_map_jit ? "C  (MAP_JIT RW then mprotect RX)"
	                                : "B  (plain RW then mprotect RX)";
	long ps = jp_pagesize();
	int flags = MAP_PRIVATE | MAP_ANON | (with_map_jit ? MAP_JIT : 0);

	jp_say(o, "%s: mmap RW, %ld bytes", name, ps);
	void *page = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE, flags, -1, 0);
	if (page == MAP_FAILED) {
		jp_say(o, "%s: FAILED at mmap, errno %d (%s)", name, errno, strerror(errno));
		return;
	}
	jp_say(o, "%s: mapped at %p", name, page);

	int sig = 0;
	if (!jp_write_guarded(page, &sig)) {
		jp_say(o, "%s: FAILED at write, signal %d (%s)", name, sig, strsignal(sig));
		munmap(page, (size_t)ps);
		return;
	}
	jp_say(o, "%s: wrote %zu bytes", name, sizeof kStub);

	jp_say(o, "%s: mprotect to R+X", name);
	if (mprotect(page, (size_t)ps, PROT_READ | PROT_EXEC) != 0) {
		jp_say(o, "%s: FAILED at mprotect, errno %d (%s)", name, errno, strerror(errno));
		munmap(page, (size_t)ps);
		return;
	}

	jp_finish(o, name, page, executed);
	munmap(page, (size_t)ps);
}

// --------------------------------------------------------------------- api

static int jp_cs_status(unsigned int *out)
{
	jp_csops_fn csops = (jp_csops_fn)dlsym(RTLD_DEFAULT, "csops");
	if (!csops) return -1;

	unsigned int status = 0;
	if (csops(getpid(), JP_CS_OPS_STATUS, &status, sizeof status) != 0)
		return -1;
	*out = status;
	return 0;
}

int jp_cs_debugged(void)
{
	unsigned int status = 0;
	if (jp_cs_status(&status) != 0) return -1;
	return (status & JP_CS_DEBUGGED) ? 1 : 0;
}

// The whole word, not just the one bit. GET_TASK_ALLOW is the flag that says
// this build is debuggable at all, so a run where DEBUGGED is clear but
// GET_TASK_ALLOW is set means the attach is available and simply has not
// happened yet, which is a different problem from a build that can never be
// attached to.
static void jp_report_codesign(struct jp_out *o)
{
	unsigned int st = 0;
	if (jp_cs_status(&st) != 0) {
		jp_say(o, "code signing status: unknown, csops unavailable");
		return;
	}
	jp_say(o, "code signing status: 0x%08x%s%s%s%s%s%s%s", st,
	       (st & JP_CS_VALID)          ? " VALID"          : "",
	       (st & JP_CS_GET_TASK_ALLOW) ? " GET_TASK_ALLOW" : "",
	       (st & JP_CS_INSTALLER)      ? " INSTALLER"      : "",
	       (st & JP_CS_HARD)           ? " HARD"           : "",
	       (st & JP_CS_KILL)           ? " KILL"           : "",
	       (st & JP_CS_RESTRICT)       ? " RESTRICT"       : "",
	       (st & JP_CS_ENFORCEMENT)    ? " ENFORCEMENT"    : "");
}

// Which path to attempt next, persisted beside the journal.
//
// A path the kernel refuses can end the process with SIGKILL, which no
// handler can catch, so "run all five" is not something one launch can
// promise. The cursor is bumped BEFORE each attempt: if that attempt kills
// us, the next launch resumes past it instead of dying in the same place
// forever.
static int jp_cursor_read(const char *journal_path)
{
	if (!journal_path) return 0;
	char path[1024];
	snprintf(path, sizeof path, "%s.next", journal_path);
	FILE *f = fopen(path, "r");
	if (!f) return 0;
	int v = 0;
	if (fscanf(f, "%d", &v) != 1) v = 0;
	fclose(f);
	return (v < 0 || v > 5) ? 0 : v;
}

static void jp_cursor_write(const char *journal_path, int v)
{
	if (!journal_path) return;
	char path[1024];
	snprintf(path, sizeof path, "%s.next", journal_path);
	FILE *f = fopen(path, "w");
	if (f) { fprintf(f, "%d", v); fclose(f); }
}

int jp_run_all(const char *journal_path, char *out, size_t cap)
{
	struct jp_out o = { .buf = out, .cap = cap, .len = 0, .journal = journal_path };
	int executed = 0;

	if (cap) out[0] = '\0';

	// Resolved rather than called directly. The SDK marks the toggle
	// __API_UNAVAILABLE(ios, tvos, watchos, driverkit), and visionOS
	// inherits iOS availability unless it is named, so a direct call may
	// not compile for an xros target even where the symbol is present at
	// runtime. A null here is itself a result.
	jp_toggle_fn    toggle    = (jp_toggle_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
	jp_supported_fn supported = (jp_supported_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_supported_np");

	int dbg = jp_cs_debugged();
	jp_say(&o, "== jitprobe, pid %d ==", getpid());
	jp_say(&o, "CS_DEBUGGED: %s",
	       dbg == 1 ? "YES, a debugger has touched this process"
	                : dbg == 0 ? "no" : "unknown, csops unavailable");
	jp_report_codesign(&o);
	jp_say(&o, "pthread_jit_write_protect_np: %s",
	       toggle ? "resolved" : "NOT RESOLVABLE");
	if (supported)
		jp_say(&o, "pthread_jit_write_protect_supported_np: resolved, returns %d",
		       supported());
	else
		jp_say(&o, "pthread_jit_write_protect_supported_np: not resolvable "
		           "(expected, the SDK marks it unavailable on visionOS)");
	jp_say(&o, "");

	int start = jp_cursor_read(journal_path);
	if (start > 0)
		jp_say(&o, "resuming at path %d: a previous launch did not survive "
		           "the one before it", start);

	for (int i = start; i < 5; i++) {
		jp_cursor_write(journal_path, i + 1);
		switch (i) {
		case 0: jp_path_plain_rwx(&o, &executed); break;
		case 1: jp_path_map_jit(&o, toggle, 1, &executed); break;
		case 2: jp_path_map_jit(&o, toggle, 0, &executed); break;
		case 3: jp_path_mprotect(&o, 0, &executed); break;
		case 4: jp_path_mprotect(&o, 1, &executed); break;
		default: break;
		}
		jp_say(&o, "");
	}
	jp_cursor_write(journal_path, 0);

	jp_say(&o, "== %d of %d attempted paths executed this launch, "
	           "CS_DEBUGGED %s ==",
	       executed, 5 - start, dbg == 1 ? "yes" : dbg == 0 ? "no" : "unknown");
	return executed;
}
